"""Offline-first sync: pull changes since a timestamp, push a batch.

Last-write-wins by server clock. Push always applies (the writer owns its
change); conflicts are resolved by ordering on updated_at during pull.
Tombstones (deleted=true) are retained so deletes propagate to devices.

Mass-deletion guard: a client that lost its local store (failed hydrate,
evicted browser storage, cleared app data) but kept its sync bookkeeping
would push tombstones for most of a collection — and that loss would then
propagate to every device. The push handler withholds tombstones that
would delete a large share of a collection at once and reports them as
`guarded`. Escape hatch for deliberate mass cleanups:
SYNC_ALLOW_MASS_DELETE=1 on the server.
"""

from __future__ import annotations

import base64
import binascii
import datetime as dt
import logging
import os

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import and_, func, or_, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import dialect_insert, get_session
from ..deps import check_token_scope, get_current_user
from ..models import COLLECTIONS, SyncItem, User
from ..schemas import GuardedChange, PullOut, PushIn, PushOut, SyncRecord

router = APIRouter(prefix="/sync", tags=["sync"])

logger = logging.getLogger(__name__)

_MAX_LIMIT = 2000
_SINGLETON_COLLECTIONS = ("settings", "waterfall", "plaid")

# Mirrors the Dart client's SyncEngine._looksLikeDataLoss thresholds, with
# a time window so clients that chunk their pushes (400 items per request)
# cannot slip a wipe through one chunk at a time.
# - Large collection: >= 100 deletions AND >= 20% of the collection.
# - Small collection: >= 5 deletions AND >= 90% of the collection.
_GUARD_LARGE_MIN_ITEMS = 100
_GUARD_SMALL_MIN_ITEMS = 5
_GUARD_WINDOW = dt.timedelta(minutes=30)


def _mass_delete_guard_disabled() -> bool:
    return os.getenv("SYNC_ALLOW_MASS_DELETE", "").strip().lower() in (
        "1",
        "true",
        "yes",
    )


def _looks_like_mass_delete(deletes: int, total_before: int) -> bool:
    """True when [deletes] (this batch plus recent ones) would wipe a large
    share of a collection holding [total_before] items. Ordinary cleanup
    through the app deletes a handful of items, far below these
    thresholds."""
    if total_before <= 0 or deletes <= 0:
        return False
    if deletes >= _GUARD_LARGE_MIN_ITEMS and deletes * 5 >= total_before:
        return True
    if deletes >= _GUARD_SMALL_MIN_ITEMS and deletes * 10 >= total_before * 9:
        return True
    return False


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def _to_record(row: SyncItem) -> SyncRecord:
    return SyncRecord(
        collection=row.collection,
        item_id=row.item_id,
        data=row.data if isinstance(row.data, dict) else {},
        deleted=row.deleted,
        rev=row.rev,
        updated_at=row.updated_at,
    )


def _parse_since(raw: str | None) -> dt.datetime | None:
    if not raw:
        return None
    try:
        parsed = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid 'since' timestamp")
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed


def _encode_pull_cursor(row: SyncItem) -> str:
    raw = f"{row.updated_at.isoformat()}|{row.id}".encode("utf-8")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _parse_pull_cursor(raw: str) -> tuple[dt.datetime, int]:
    try:
        padded = raw + "=" * (-len(raw) % 4)
        decoded = base64.urlsafe_b64decode(padded).decode("utf-8")
        timestamp, row_id = decoded.rsplit("|", 1)
        parsed = dt.datetime.fromisoformat(timestamp)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed, int(row_id)
    except (ValueError, UnicodeDecodeError, binascii.Error):
        raise HTTPException(status_code=400, detail="Invalid 'cursor'")


async def _lock_sync_user(session: AsyncSession, user: User) -> None:
    """Serialize each user's pull watermark/read with their push commit.

    Postgres uses a row lock. SQLite ignores FOR UPDATE, so a no-op UPDATE
    acquires its database write lock and holds it until the request ends.
    This prevents an in-flight push with an older timestamp from committing
    just after a pull has advanced its watermark past that timestamp.
    """
    if session.bind is not None and session.bind.dialect.name == "sqlite":
        # Authentication has already read the user in a deferred transaction.
        # End that read snapshot before taking SQLite's writer lock; otherwise
        # WAL mode cannot promote a stale read transaction to a write lock.
        await session.commit()
        await session.execute(
            update(User).where(User.id == user.id).values(email=User.email)
        )
        return
    await session.execute(
        select(User.id).where(User.id == user.id).with_for_update()
    )


@router.get("/pull", response_model=PullOut)
async def pull(
    since: str | None = Query(default=None),
    cursor: str | None = Query(default=None),
    collections: str | None = Query(default=None),
    limit: int = Query(default=1000, ge=1, le=_MAX_LIMIT),
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    wanted: set[str] | None = None
    if collections:
        wanted = {c.strip() for c in collections.split(",") if c.strip()}
        unknown = wanted - set(COLLECTIONS)
        if unknown:
            raise HTTPException(
                status_code=400, detail=f"Unknown collections: {sorted(unknown)}"
            )
    if wanted:
        for c in sorted(wanted):
            check_token_scope(user, f"{c}:read", f"{c}:write")
    else:
        check_token_scope(user, "sync")
    await _lock_sync_user(session, user)
    # Capture the page watermark before reading rows. Push stamps are assigned
    # after the per-user lock, so each pull sees all earlier commits and no
    # later push can commit with a timestamp older than this watermark.
    server_time = _now()
    cursor_key = _parse_pull_cursor(cursor) if cursor else None
    since_dt = None if cursor_key else _parse_since(since)
    filters = [SyncItem.user_id == user.id]
    if wanted:
        filters.append(SyncItem.collection.in_(sorted(wanted)))
    if cursor_key is not None:
        cursor_time, cursor_id = cursor_key
        filters.append(
            or_(
                SyncItem.updated_at > cursor_time,
                and_(SyncItem.updated_at == cursor_time, SyncItem.id > cursor_id),
            )
        )
    elif since_dt is not None:
        filters.append(SyncItem.updated_at > since_dt)
    stmt = select(SyncItem).where(*filters)
    stmt = stmt.order_by(SyncItem.updated_at.asc(), SyncItem.id.asc()).limit(limit + 1)
    rows = (await session.execute(stmt)).scalars().all()
    has_more = len(rows) > limit
    page = rows[:limit]
    if cursor_key is None and has_more and page:
        # Legacy clients only continue with `since=last.updated_at`, which
        # cannot identify their position within a timestamp tie. Include the
        # entire tie group at this page boundary so strict `>` resumes after it.
        boundary_time = page[-1].updated_at
        boundary_id = page[-1].id
        tied_rows = (
            await session.execute(
                select(SyncItem)
                .where(
                    *filters,
                    SyncItem.updated_at == boundary_time,
                    SyncItem.id > boundary_id,
                )
                .order_by(SyncItem.id.asc())
            )
        ).scalars().all()
        page.extend(tied_rows)
        has_more = (
            await session.execute(
                select(SyncItem.id)
                .where(*filters, SyncItem.updated_at > boundary_time)
                .limit(1)
            )
        ).first() is not None
    return PullOut(
        changes=[_to_record(r) for r in page],
        server_time=server_time,
        has_more=has_more,
        next_cursor=_encode_pull_cursor(page[-1]) if has_more and page else None,
    )


@router.post("/push", response_model=PushOut)
async def push(
    body: PushIn,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    for change in body.changes:
        if change.collection not in COLLECTIONS:
            raise HTTPException(
                status_code=400, detail=f"Unknown collection: {change.collection}"
            )
    if body.changes:
        for c in sorted({change.collection for change in body.changes}):
            check_token_scope(user, f"{c}:write")
    else:
        check_token_scope(user, "sync")
    await _lock_sync_user(session, user)
    guard_now = _now()
    applied: list[SyncRecord] = []
    guarded: list[GuardedChange] = []

    # Mass-deletion guard: weigh this batch's tombstones (plus deletions
    # applied moments ago, so chunked pushes cannot slip a wipe through)
    # against the live rows they would delete, and withhold offenders.
    blocked: set[tuple[str, str]] = set()
    if not _mass_delete_guard_disabled():
        tombstones_by_collection: dict[str, int] = {}
        for change in body.changes:
            if change.deleted:
                tombstones_by_collection[change.collection] = (
                    tombstones_by_collection.get(change.collection, 0) + 1
                )
        if tombstones_by_collection:
            collections = list(tombstones_by_collection)
            live_rows = (
                await session.execute(
                    select(SyncItem.collection, func.count())
                    .where(
                        and_(
                            SyncItem.user_id == user.id,
                            SyncItem.collection.in_(collections),
                            SyncItem.deleted.is_(False),
                        )
                    )
                    .group_by(SyncItem.collection)
                )
            ).all()
            live_by_collection = {row[0]: row[1] for row in live_rows}
            recent_rows = (
                await session.execute(
                    select(SyncItem.collection, func.count())
                    .where(
                        and_(
                            SyncItem.user_id == user.id,
                            SyncItem.collection.in_(collections),
                            SyncItem.deleted.is_(True),
                            SyncItem.updated_at >= guard_now - _GUARD_WINDOW,
                        )
                    )
                    .group_by(SyncItem.collection)
                )
            ).all()
            recent_by_collection = {row[0]: row[1] for row in recent_rows}
            for collection, pending in tombstones_by_collection.items():
                live = live_by_collection.get(collection, 0)
                recent = recent_by_collection.get(collection, 0)
                if _looks_like_mass_delete(pending + recent, live + recent):
                    for change in body.changes:
                        if change.deleted and change.collection == collection:
                            blocked.add((collection, change.item_id))
            if blocked:
                logger.warning(
                    "sync mass-deletion guard withheld %d tombstones for "
                    "user=%s collections=%s (set SYNC_ALLOW_MASS_DELETE=1 "
                    "to disable)",
                    len(blocked),
                    user.id,
                    sorted({c for c, _ in blocked}),
                )

    # Timestamp after validation and guard queries, close to the actual row
    # writes. This avoids assigning a push a timestamp from before a slow
    # pre-write query when a pull watermark is captured concurrently.
    now = _now()
    for change in body.changes:
        if change.collection not in COLLECTIONS:
            raise HTTPException(
                status_code=400, detail=f"Unknown collection: {change.collection}"
            )
        if (change.collection, change.item_id) in blocked:
            guarded.append(
                GuardedChange(
                    collection=change.collection, item_id=change.item_id
                )
            )
            continue
        # Light envelope guard: item payload should carry its own id when
        # the Dart model has one; singletons ('settings'/'waterfall'/'plaid')
        # are exempt. Unknown fields pass through untouched (forward-compat).
        if (
            change.collection not in _SINGLETON_COLLECTIONS
            and isinstance(change.data, dict)
        ):
            payload_id = change.data.get("id")
            if payload_id is not None and str(payload_id) != change.item_id:
                raise HTTPException(
                    status_code=400,
                    detail=f"data.id {payload_id!r} != item_id {change.item_id!r}",
                )
        # Upsert (insert-or-update) so two requests racing for the same
        # (user, collection, item_id) end with one success and one clean
        # update instead of a unique-constraint 500. ON CONFLICT is atomic
        # and dialect-agnostic (sqlite + postgres); IntegrityError is a
        # last-resort fallback.
        stmt = (
            dialect_insert(SyncItem.__table__)
            .values(
                user_id=user.id,
                collection=change.collection,
                item_id=change.item_id,
                data=change.data,
                deleted=change.deleted,
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
                    data=change.data,
                    deleted=change.deleted,
                    rev=SyncItem.rev + 1,
                    updated_at=now,
                ),
            )
        )
        try:
            await session.execute(stmt)
        except IntegrityError:
            await session.rollback()
            existing = (
                await session.execute(
                    select(SyncItem).where(
                        and_(
                            SyncItem.user_id == user.id,
                            SyncItem.collection == change.collection,
                            SyncItem.item_id == change.item_id,
                        )
                    )
                )
            ).scalar_one()
            existing.data = change.data
            existing.deleted = change.deleted
            existing.rev += 1
            existing.updated_at = now
        row = (
            await session.execute(
                select(SyncItem).where(
                    and_(
                        SyncItem.user_id == user.id,
                        SyncItem.collection == change.collection,
                        SyncItem.item_id == change.item_id,
                    )
                )
            )
        ).scalar_one()
        applied.append(_to_record(row))
    await session.commit()
    return PushOut(applied=applied, server_time=now, guarded=guarded)
