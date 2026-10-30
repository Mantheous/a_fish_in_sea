"""Content-free usage event ingest.

The app's local log (lib/common/usage) batches screen dwell, closed-set
actions, error *types*, and slow/failed syncs. This endpoint is the only
writer. Reads happen on the loop host through the digest script, so there
is deliberately no GET/admin surface here.

Safety properties:
- JWT users only (never long-lived API tokens).
- Closed-set names + bounded meta validated in schemas.UsageEventIn.
- Dedupe by (user_id, event_id), so a retried batch after a lost response
  is harmless.
- Per-user daily cap + 120-day retention keep the table bounded even if a
  client goes haywire.
"""

from __future__ import annotations

import datetime as dt
import time

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import dialect_insert, get_session
from ..deps import require_jwt_user
from ..models import UsageEvent, User
from ..ratelimit import limit
from ..schemas import UsageBatchIn

router = APIRouter(prefix="/usage", tags=["usage"])

_RETENTION = dt.timedelta(days=120)
_DAILY_CAP = 5000
_PRUNE_EVERY_S = 3600.0
_last_prune = 0.0


def _utcnow() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


async def _maybe_prune(
    session: AsyncSession, user_id: int, now: dt.datetime
) -> None:
    global _last_prune
    if time.monotonic() - _last_prune < _PRUNE_EVERY_S:
        return
    _last_prune = time.monotonic()
    await session.execute(
        delete(UsageEvent).where(
            UsageEvent.user_id == user_id,
            UsageEvent.received_at < now - _RETENTION,
        )
    )
    await session.commit()


@router.post("/events")
async def ingest_usage(
    batch: UsageBatchIn,
    user: User = Depends(require_jwt_user),
    session: AsyncSession = Depends(get_session),
    _rl: None = Depends(limit("usage:events", 30, 60)),
) -> dict:
    now = _utcnow()
    since = now - dt.timedelta(days=1)
    recent = (
        await session.execute(
            select(func.count())
            .select_from(UsageEvent)
            .where(
                UsageEvent.user_id == user.id,
                UsageEvent.received_at >= since,
            )
        )
    ).scalar_one()
    if recent >= _DAILY_CAP:
        raise HTTPException(
            status_code=429,
            detail="Usage event daily cap reached; events will be retried tomorrow",
        )

    if not batch.events:
        return {"accepted": 0}

    rows = [
        {
            "user_id": user.id,
            "event_id": event.id,
            "session_id": batch.session_id,
            "kind": event.kind,
            "name": event.name,
            "screen": event.screen,
            "duration_ms": event.duration_ms,
            "meta": event.meta,
            "platform": batch.platform,
            "client_at_ms": event.at,
            "received_at": now,
        }
        for event in batch.events
    ]
    stmt = (
        dialect_insert(UsageEvent)
        .values(rows)
        .on_conflict_do_nothing(index_elements=["user_id", "event_id"])
    )
    result = await session.execute(stmt)
    await session.commit()
    await _maybe_prune(session, user.id, now)
    return {"accepted": max(0, int(result.rowcount or 0))}
