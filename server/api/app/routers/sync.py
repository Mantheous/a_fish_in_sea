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

import datetime as dt
import logging
import os

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import and_, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import get_session
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


@router.get("/pull", response_model=PullOut)
async def pull(
    since: str | None = Query(default=None),
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
    since_dt = _parse_since(since)
    stmt = select(SyncItem).where(SyncItem.user_id == user.id)
    if wanted:
        stmt = stmt.where(SyncItem.collection.in_(sorted(wanted)))
    if since_dt is not None:
        stmt = stmt.where(SyncItem.updated_at > since_dt)
    stmt = stmt.order_by(SyncItem.updated_at.asc()).limit(limit + 1)
    rows = (await session.execute(stmt)).scalars().all()
    has_more = len(rows) > limit
    return PullOut(
        changes=[_to_record(r) for r in rows[:limit]],
        server_time=_now(),
        has_more=has_more,
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
    now = _now()
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
                            SyncItem.updated_at >= now - _GUARD_WINDOW,
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
        ).scalar_one_or_none()
        if existing is None:
            row = SyncItem(
                user_id=user.id,
                collection=change.collection,
                item_id=change.item_id,
                data=change.data,
                deleted=change.deleted,
                rev=1,
                updated_at=now,
            )
            session.add(row)
            await session.flush()
            applied.append(_to_record(row))
        else:
            existing.data = change.data
            existing.deleted = change.deleted
            existing.rev += 1
            existing.updated_at = now
            applied.append(_to_record(existing))
    await session.commit()
    return PushOut(applied=applied, server_time=now, guarded=guarded)
