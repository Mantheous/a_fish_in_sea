"""Garmin fitness proxy (first watch provider).

Stores the per-user Garmin connection via oauth_store (provider
"garmin") and proxies sleep + activity summaries. This is a thin
scaffold: without GARMIN_CLIENT_ID/SECRET configured the connect flow
reports not-configured and the data endpoints return the stored
samples (empty until a real Garmin Health API fetch is wired). The
client stays offline-first — synced watch values feed goal progress
through lib/fitness/fitness_sync.dart, never by writing here.
"""

from __future__ import annotations

import os

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import get_session
from ..deps import get_current_user
from ..models import User
from ..oauth_store import (
    clear_connection,
    decrypt_secret,
    get_connection,
    save_connection,
)

router = APIRouter(prefix="/fitness", tags=["fitness"])

_PROVIDER = "garmin"


def _configured() -> bool:
    return bool(
        os.getenv("GARMIN_CLIENT_ID", "").strip()
        and os.getenv("GARMIN_CLIENT_SECRET", "").strip()
    )


@router.get("/status")
async def status(
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    row = await get_connection(session, user.id, _PROVIDER)
    connected = bool(row and decrypt_secret(row.access_token))
    return {
        "provider": _PROVIDER,
        "connected": connected,
        "configured": _configured(),
    }


@router.post("/connect")
async def connect(
    body: dict,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    """Manual token entry until full Garmin OAuth is wired.

    Body: {"access_token": "...", "refresh_token": "..."}. Returns
    501-style payload when no token is supplied and no OAuth app is
    configured, so the client can explain instead of failing silently.
    """
    access = str((body or {}).get("access_token") or "").strip()
    refresh = str((body or {}).get("refresh_token") or "").strip()
    if not access and not _configured():
        return {
            "status": "not-configured",
            "detail": "Garmin OAuth is not configured on this server. "
            "Set GARMIN_CLIENT_ID/SECRET to enable it.",
        }
    if not access:
        return {
            "status": "needs-token",
            "detail": "Pass an access_token (Garmin Health API) to connect.",
        }
    await save_connection(
        session,
        user.id,
        _PROVIDER,
        access_token=access,
        refresh_token=refresh,
        scopes="sleep activity",
    )
    await session.commit()
    return {"status": "connected", "provider": _PROVIDER}


@router.post("/disconnect")
async def disconnect(
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    await clear_connection(session, user.id, _PROVIDER)
    await session.commit()
    return {"status": "disconnected"}


@router.get("/activities")
async def activities(
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    row = await get_connection(session, user.id, _PROVIDER)
    if not row or not decrypt_secret(row.access_token):
        return {"activities": [], "connected": False}
    # Real Garmin Health API fetch goes here once credentials exist.
    return {"activities": [], "connected": True}


@router.get("/sleep")
async def sleep(
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    row = await get_connection(session, user.id, _PROVIDER)
    if not row or not decrypt_secret(row.access_token):
        return {"sleep": [], "connected": False}
    return {"sleep": [], "connected": True}
