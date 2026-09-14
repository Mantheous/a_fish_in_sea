"""Offline-first sync: pull changes since a timestamp, push a batch.

Last-write-wins by server clock. Push always applies (the writer owns its
change); conflicts are resolved by ordering on updated_at during pull.
Tombstones (deleted=true) are retained so deletes propagate to devices.
"""

from __future__ import annotations

import datetime as dt

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import and_, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import get_session
from ..deps import get_current_user
from ..models import COLLECTIONS, SyncItem, User
from ..schemas import PullOut, PushIn, PushOut, SyncRecord

router = APIRouter(prefix="/sync", tags=["sync"])

_MAX_LIMIT = 2000


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
    now = _now()
    applied: list[SyncRecord] = []
    for change in body.changes:
        if change.collection not in COLLECTIONS:
            raise HTTPException(
                status_code=400, detail=f"Unknown collection: {change.collection}"
            )
        # Light envelope guard: item payload should carry its own id when
        # the Dart model has one; 'settings' singleton is exempt. Unknown
        # fields pass through untouched (forward-compat).
        if change.collection != "settings" and isinstance(change.data, dict):
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
    return PushOut(applied=applied, server_time=now)
