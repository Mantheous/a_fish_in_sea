"""Staged third-party imports with in-app approval.

Two lanes share one door (POST /imports):

- Trusted writers (JWT user, or an API token minted WITHOUT review=true)
  apply straight into the sync envelope — same upsert semantics as
  PUT /items, same last-write-wins + rev bump. Behavior is exactly what
  /items always did.
- Review writers (token minted WITH review=true) draft into staging
  tables instead (202 + batch_id). Nothing syncs until the user approves
  item(s) in the app's Home review tile.

Approval only ever WRITES (upserts); it never tombstones, so the sync
mass-deletion guard is structurally unreachable from here. Only the
live client collections are importable: nodes + events. The retired
'tasks' collection no longer syncs to any device, so staging into it
would be invisible — it is rejected.

Review endpoints are JWT-only (the app user approving their own inbox);
API tokens can submit but never self-approve.
"""

from __future__ import annotations

import datetime as dt

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import and_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import dialect_insert, get_session
from ..deps import check_token_scope, get_current_user
from ..models import ImportBatch, ImportItem, SyncItem, User
from ..schemas import (
    ImportApproveIn,
    ImportBatchOut,
    ImportCreateIn,
    ImportCreateOut,
    ImportDiscardIn,
    ImportItemOut,
    SyncRecord,
)

router = APIRouter(prefix="/imports", tags=["imports"])

# The retired 'tasks' collection is deliberately excluded: the client no
# longer syncs it, so imports there would silently vanish.
IMPORTABLE = ("nodes", "events")

# Pending batches older than this stop appearing (treated as expired).
# A filter, not a sweeper: no background job, nothing to operate.
_BATCH_TTL = dt.timedelta(days=30)


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def _is_jwt(user: User) -> bool:
    """JWT users carry no stashed scopes; API tokens always do."""
    return getattr(user, "_scopes", None) is None


def _require_jwt(user: User) -> None:
    if not _is_jwt(user):
        raise HTTPException(
            status_code=403, detail="Approval is app-only (sign in, not a token)"
        )


async def _get_batch(
    session: AsyncSession, user_id: int, batch_id: int
) -> ImportBatch:
    row = await session.get(ImportBatch, batch_id)
    if row is None or row.user_id != user_id:
        raise HTTPException(status_code=404, detail="Batch not found")
    return row


async def _batch_items(
    session: AsyncSession, batch_id: int
) -> list[ImportItem]:
    return list(
        (
            await session.execute(
                select(ImportItem)
                .where(ImportItem.batch_id == batch_id)
                .order_by(ImportItem.id.asc())
            )
        )
        .scalars()
        .all()
    )


async def _existing_map(
    session: AsyncSession,
    user_id: int,
    rows: list[ImportItem],
) -> dict[tuple[str, str], tuple[dict, bool]]:
    """Live sync rows keyed by (collection, item_id) for conflict display.

    Returns (data, deleted): tombstoned rows are included so the reviewer
    can tell "updates existing" apart from "restores something I deleted"
    — approving the latter is an explicit restore, never a surprise.
    """
    if not rows:
        return {}
    by_collection: dict[str, set[str]] = {}
    for r in rows:
        by_collection.setdefault(r.collection, set()).add(r.item_id)
    out: dict[tuple[str, str], tuple[dict, bool]] = {}
    for collection, item_ids in by_collection.items():
        found = (
            await session.execute(
                select(SyncItem).where(
                    and_(
                        SyncItem.user_id == user_id,
                        SyncItem.collection == collection,
                        SyncItem.item_id.in_(sorted(item_ids)),
                    )
                )
            )
        ).scalars().all()
        for row in found:
            if isinstance(row.data, dict):
                out[(row.collection, row.item_id)] = (
                    dict(row.data),
                    bool(row.deleted),
                )
    return out


def _to_out(
    batch: ImportBatch,
    rows: list[ImportItem],
    existing: dict[tuple[str, str], tuple[dict, bool]] | None = None,
) -> ImportBatchOut:
    existing = existing or {}
    items: list[ImportItemOut] = []
    for r in rows:
        hit = existing.get((r.collection, r.item_id))
        items.append(
            ImportItemOut(
                collection=r.collection,
                item_id=r.item_id,
                data=r.data if isinstance(r.data, dict) else {},
                status=r.status,
                existing=hit[0] if hit is not None else None,
                existing_deleted=hit[1] if hit is not None else False,
            )
        )
    return ImportBatchOut(
        id=batch.id,
        source=batch.source,
        status=batch.status,
        created_at=batch.created_at,
        items=items,
    )


async def _upsert_sync_item(
    session: AsyncSession,
    user_id: int,
    collection: str,
    item_id: str,
    data: dict,
) -> SyncRecord:
    """Same envelope write as PUT /items: create-or-replace, rev bump,
    un-delete. Approval paths must use this (never tombstones).

    Upserts via ON CONFLICT so two requests racing for the same
    (user, collection, item_id) end with one success and one clean update
    instead of a unique-constraint 500; IntegrityError is the fallback.
    """
    now = _now()
    payload = dict(data)
    payload["id"] = item_id
    stmt = (
        dialect_insert(SyncItem.__table__)
        .values(
            user_id=user_id,
            collection=collection,
            item_id=item_id,
            data=payload,
            deleted=False,
            rev=1,
            updated_at=now,
        )
        .on_conflict_do_update(
            index_elements=[
                SyncItem.user_id,
                SyncItem.collection,
                SyncItem.item_id,
            ],
            set_=dict(
                data=payload,
                deleted=False,
                rev=SyncItem.rev + 1,
                updated_at=now,
            ),
        )
    )
    try:
        await session.execute(stmt)
    except IntegrityError:
        await session.rollback()
        row = (
            await session.execute(
                select(SyncItem).where(
                    and_(
                        SyncItem.user_id == user_id,
                        SyncItem.collection == collection,
                        SyncItem.item_id == item_id,
                    )
                )
            )
        ).scalar_one()
        row.data = payload
        row.deleted = False
        row.rev += 1
        row.updated_at = now
    row = (
        await session.execute(
            select(SyncItem).where(
                and_(
                    SyncItem.user_id == user_id,
                    SyncItem.collection == collection,
                    SyncItem.item_id == item_id,
                )
            )
        )
    ).scalar_one()
    return SyncRecord(
        collection=row.collection,
        item_id=row.item_id,
        data=row.data if isinstance(row.data, dict) else {},
        deleted=row.deleted,
        rev=row.rev,
        updated_at=row.updated_at,
    )


async def _resolve_batch(
    session: AsyncSession, batch: ImportBatch, rows: list[ImportItem]
) -> None:
    """Close the batch once nothing is pending: approved when at least
    one item was approved, else rejected."""
    if any(r.status == "pending" for r in rows):
        batch.status = "pending"
    elif any(r.status == "approved" for r in rows):
        batch.status = "approved"
    else:
        batch.status = "rejected"


@router.post("", response_model=ImportCreateOut, status_code=201)
async def submit_import(
    body: ImportCreateIn,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    for item in body.items:
        if item.collection not in IMPORTABLE:
            raise HTTPException(
                status_code=400,
                detail=f"Collection not importable: {item.collection}"
                f" (importable: {sorted(IMPORTABLE)})",
            )
        if isinstance(item.data, dict):
            payload_id = item.data.get("id")
            if payload_id is not None and str(payload_id) != item.item_id:
                raise HTTPException(
                    status_code=400,
                    detail=f"data.id {payload_id!r} != item_id {item.item_id!r}",
                )
    for c in sorted({item.collection for item in body.items}):
        check_token_scope(user, f"{c}:write", allow_review=True)
    review = bool(getattr(user, "_token_review", False))
    if _is_jwt(user) or not review:
        # Trusted lane: direct envelope writes, same as PUT /items.
        applied = [
            await _upsert_sync_item(
                session, user.id, item.collection, item.item_id, item.data
            )
            for item in body.items
        ]
        await session.commit()
        return ImportCreateOut(status="applied", applied=applied)
    # Review lane: stage everything; nothing syncs until approved.
    source = body.source.strip()[:120] or getattr(user, "_token_name", "") or "import"
    batch = ImportBatch(user_id=user.id, source=source, status="pending")
    session.add(batch)
    await session.flush()  # need batch.id for the item rows
    for item in body.items:
        payload = dict(item.data)
        payload["id"] = item.item_id
        session.add(
            ImportItem(
                batch_id=batch.id,
                collection=item.collection,
                item_id=item.item_id,
                data=payload,
                status="pending",
            )
        )
    await session.commit()
    await session.refresh(batch)
    return ImportCreateOut(status="pending", batch_id=batch.id)


def _match_wanted_pairs(
    pending: list[ImportItem], raw_ids: list[str]
) -> set[tuple[str, str]]:
    """Resolve caller-supplied item identifiers to (collection, item_id) pairs.

    Approve/discard are keyed by (collection, item_id): a qualified
    'collection:item_id' matches exactly that row. A bare 'item_id' is
    accepted only when it is unambiguous within the batch (exactly one
    pending row carries it). A bare id shared across collections is
    ambiguous and is rejected instead of silently acting on every
    collection at once — that was the cross-collection approve/discard
    collision.
    """
    known_pairs = {(r.collection, r.item_id) for r in pending}
    by_bare: dict[str, set[tuple[str, str]]] = {}
    for pair in known_pairs:
        by_bare.setdefault(pair[1], set()).add(pair)
    matched: set[tuple[str, str]] = set()
    unknown: list[str] = []
    ambiguous: list[str] = []
    for raw in raw_ids:
        if ":" in raw:
            prefix, rest = raw.split(":", 1)
            if prefix in IMPORTABLE and (prefix, rest) in known_pairs:
                matched.add((prefix, rest))
            else:
                unknown.append(raw)
            continue
        candidates = by_bare.get(raw, set())
        if not candidates:
            unknown.append(raw)
        elif len(candidates) == 1:
            matched.update(candidates)
        else:
            ambiguous.append(raw)
    if unknown:
        raise HTTPException(
            status_code=400, detail=f"Unknown items: {sorted(set(unknown))}"
        )
    if ambiguous:
        raise HTTPException(
            status_code=400,
            detail=(
                "Ambiguous item id(s) exist in multiple collections; "
                f"qualify with collection:item_id: {sorted(set(ambiguous))}"
            ),
        )
    return matched


@router.get("/pending", response_model=list[ImportBatchOut])
async def pending_batches(
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    _require_jwt(user)
    cutoff = _now() - _BATCH_TTL
    batches = list(
        (
            await session.execute(
                select(ImportBatch)
                .where(
                    and_(
                        ImportBatch.user_id == user.id,
                        ImportBatch.status == "pending",
                        ImportBatch.created_at > cutoff,
                    )
                )
                .order_by(ImportBatch.created_at.asc())
            )
        )
        .scalars()
        .all()
    )
    if not batches:
        return []
    batch_ids = [b.id for b in batches]
    all_rows = list(
        (
            await session.execute(
                select(ImportItem)
                .where(ImportItem.batch_id.in_(batch_ids))
                .order_by(ImportItem.id.asc())
            )
        )
        .scalars()
        .all()
    )
    existing = await _existing_map(session, user.id, all_rows)
    rows_by_batch: dict[int, list[ImportItem]] = {b.id: [] for b in batches}
    for r in all_rows:
        rows_by_batch.setdefault(r.batch_id, []).append(r)
    return [
        _to_out(batch, rows_by_batch.get(batch.id, []), existing)
        for batch in batches
    ]


@router.post("/{batch_id}/approve", response_model=ImportBatchOut)
async def approve_batch(
    batch_id: int,
    body: ImportApproveIn,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    _require_jwt(user)
    batch = await _get_batch(session, user.id, batch_id)
    if batch.status != "pending":
        raise HTTPException(status_code=409, detail="Batch already decided")
    rows = await _batch_items(session, batch.id)
    pending = [r for r in rows if r.status == "pending"]
    if not pending:
        raise HTTPException(status_code=409, detail="Batch already decided")
    if body.item_ids is not None:
        if not body.item_ids:
            raise HTTPException(status_code=400, detail="item_ids is empty")
        wanted_pairs = _match_wanted_pairs(pending, body.item_ids)
    else:
        wanted_pairs = {(r.collection, r.item_id) for r in pending}
    now = _now()
    for row in pending:
        if (row.collection, row.item_id) in wanted_pairs:
            await _upsert_sync_item(
                session, user.id, row.collection, row.item_id, row.data
            )
            row.status = "approved"
            row.decided_at = now
    await _resolve_batch(session, batch, rows)
    await session.commit()
    await session.refresh(batch)
    rows = await _batch_items(session, batch.id)
    existing = await _existing_map(session, user.id, rows)
    return _to_out(batch, rows, existing)


@router.post("/{batch_id}/discard", response_model=ImportBatchOut)
async def discard_items(
    batch_id: int,
    body: ImportDiscardIn,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    """Drop selected staged items without applying them. Only staging
    rows are touched — app data is never deleted here."""
    _require_jwt(user)
    batch = await _get_batch(session, user.id, batch_id)
    if batch.status != "pending":
        raise HTTPException(status_code=409, detail="Batch already decided")
    rows = await _batch_items(session, batch.id)
    pending = [r for r in rows if r.status == "pending"]
    wanted_pairs = _match_wanted_pairs(pending, body.item_ids)
    now = _now()
    for row in rows:
        if row.status == "pending" and (row.collection, row.item_id) in wanted_pairs:
            row.status = "rejected"
            row.decided_at = now
    await _resolve_batch(session, batch, rows)
    await session.commit()
    await session.refresh(batch)
    rows = await _batch_items(session, batch.id)
    existing = await _existing_map(session, user.id, rows)
    return _to_out(batch, rows, existing)


@router.post("/{batch_id}/reject", response_model=ImportBatchOut)
async def reject_batch(
    batch_id: int,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    """Discard the whole batch. Staging rows only — app data untouched."""
    _require_jwt(user)
    batch = await _get_batch(session, user.id, batch_id)
    if batch.status != "pending":
        raise HTTPException(status_code=409, detail="Batch already decided")
    rows = await _batch_items(session, batch.id)
    now = _now()
    for row in rows:
        if row.status == "pending":
            row.status = "rejected"
            row.decided_at = now
    batch.status = "rejected"
    await session.commit()
    await session.refresh(batch)
    rows = await _batch_items(session, batch.id)
    existing = await _existing_map(session, user.id, rows)
    return _to_out(batch, rows, existing)
