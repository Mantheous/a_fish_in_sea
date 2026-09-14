"""Server-side iCal fetching: snapshot cache + on-demand refresh.

Clients POST /fetch/refresh (single feed) or /fetch/refresh-due (all
enabled feeds) and then read the cached ICS via /fetch/snapshot. Feed
configs themselves arrive via normal sync (collection='feeds'); the
server never invents feeds, it only fetches their URLs. Parsing stays
client-side — the server is a dumb-but-fresh cache, which also fixes
web CORS for every feed at once.

Google feeds are NOT fetched here (they sync client-side through the
per-user /api/google/* OAuth proxy); those keep client-fetching.
"""

from __future__ import annotations

import datetime as dt
import urllib.parse

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import and_, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import get_session
from ..deps import get_current_user
from ..models import FeedSnapshot, SyncItem, User
from ..ratelimit import limit
from ..ssrf import fetch_public_bytes

router = APIRouter(prefix="/fetch", tags=["fetch"])


async def _fetch_url(url: str) -> tuple[bytes, str]:
    """Return (body, etag). Split out for tests to monkeypatch."""
    # fetch_public_bytes validates the scheme, rejects internal hosts
    # on every redirect hop, and caps the body at 5MB.
    return await fetch_public_bytes(url)


# Rebindable in tests: `fetch_router._fetch_url = stub`.
fetch_url = _fetch_url


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


class RefreshIn(BaseModel):
    feed_id: str = ""
    url: str = ""  # fallback when the feed config hasn't synced yet


class RefreshResult(BaseModel):
    feed_id: str
    status: str  # 'ok' | 'error'
    error: str = ""
    fetched_at: dt.datetime
    bytes: int = 0


class RefreshDueOut(BaseModel):
    results: list[RefreshResult]


class SnapshotOut(BaseModel):
    feed_id: str
    ics: str
    etag: str = ""
    status: str
    error: str = ""
    fetched_at: dt.datetime


def _feed_urls_from_sync(rows: list[SyncItem]) -> dict[str, dict]:
    """{feed_id: data} for enabled non-Google feeds with an http(s) url."""
    out: dict[str, dict] = {}
    for row in rows:
        if row.deleted or not isinstance(row.data, dict):
            continue
        data = row.data
        kind = str(data.get("kind", "other"))
        if kind == "google":
            continue
        if data.get("enabled") is False:
            continue
        url = str(data.get("url", ""))
        if urllib.parse.urlparse(url).scheme not in ("http", "https"):
            continue
        out[row.item_id] = data
    return out


async def _user_feeds(session: AsyncSession, user_id: int) -> list[SyncItem]:
    return (
        (
            await session.execute(
                select(SyncItem).where(
                    and_(
                        SyncItem.user_id == user_id,
                        SyncItem.collection == "feeds",
                    )
                )
            )
        )
        .scalars()
        .all()
    )


async def _store_snapshot(
    session: AsyncSession,
    user_id: int,
    feed_id: str,
    url: str,
    ics: str,
    etag: str,
    status: str,
    error: str,
) -> FeedSnapshot:
    row = (
        await session.execute(
            select(FeedSnapshot).where(
                and_(
                    FeedSnapshot.user_id == user_id,
                    FeedSnapshot.feed_id == feed_id,
                )
            )
        )
    ).scalar_one_or_none()
    now = _now()
    if row is None:
        row = FeedSnapshot(
            user_id=user_id, feed_id=feed_id, url=url, ics=ics, etag=etag,
            status=status, error=error, fetched_at=now,
        )
        session.add(row)
    else:
        row.url = url
        row.ics = ics
        row.etag = etag
        row.status = status
        row.error = error
        row.fetched_at = now
    await session.commit()
    await session.refresh(row)
    return row


async def _refresh_one(
    session: AsyncSession, user_id: int, feed_id: str, url: str
) -> RefreshResult:
    try:
        body, etag = await fetch_url(url)
    except Exception as e:
        row = await _store_snapshot(
            session, user_id, feed_id, url, "", "", "error", str(e)[:500]
        )
        return RefreshResult(
            feed_id=feed_id, status="error", error=row.error,
            fetched_at=row.fetched_at,
        )
    try:
        ics = body.decode("utf-8", errors="replace")
    except Exception as e:  # pragma: no cover - decode(replace) rarely fails
        ics = ""
        row = await _store_snapshot(
            session, user_id, feed_id, url, ics, "", "error", str(e)[:500]
        )
        return RefreshResult(
            feed_id=feed_id, status="error", error=row.error,
            fetched_at=row.fetched_at,
        )
    row = await _store_snapshot(session, user_id, feed_id, url, ics, etag, "ok", "")
    return RefreshResult(
        feed_id=feed_id, status="ok", fetched_at=row.fetched_at, bytes=len(body)
    )


@router.post("/refresh", response_model=RefreshResult)
async def refresh(
    body: RefreshIn,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
    _rl: None = Depends(limit("fetch:refresh", 60, 60, by_user=True)),
):
    feed_id = body.feed_id.strip()
    url = body.url.strip()
    if not feed_id and not url:
        raise HTTPException(status_code=400, detail="feed_id or url required")
    if not url and feed_id:
        for row in await _user_feeds(session, user.id):
            if row.item_id == feed_id and isinstance(row.data, dict):
                url = str(row.data.get("url", ""))
                break
    if urllib.parse.urlparse(url).scheme not in ("http", "https"):
        raise HTTPException(status_code=400, detail="Only http(s) feed urls supported")
    key = feed_id or url
    return await _refresh_one(session, user.id, key, url)


@router.post("/refresh-due", response_model=RefreshDueOut)
async def refresh_due(
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
    _rl: None = Depends(limit("fetch:refresh-due", 60, 60, by_user=True)),
):
    feeds = _feed_urls_from_sync(await _user_feeds(session, user.id))
    results = [
        await _refresh_one(session, user.id, fid, str(data.get("url", "")))
        for fid, data in feeds.items()
    ]
    return RefreshDueOut(results=results)


@router.get("/snapshot", response_model=SnapshotOut)
async def snapshot(
    feed_id: str,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    row = (
        await session.execute(
            select(FeedSnapshot).where(
                and_(
                    FeedSnapshot.user_id == user.id,
                    FeedSnapshot.feed_id == feed_id,
                )
            )
        )
    ).scalar_one_or_none()
    if row is None:
        raise HTTPException(status_code=404, detail="No snapshot for feed")
    return SnapshotOut(
        feed_id=row.feed_id, ics=row.ics, etag=row.etag, status=row.status,
        error=row.error, fetched_at=row.fetched_at,
    )
