"""Per-user Canvas LMS proxy (personal access tokens).

Same shape as the Google proxy (`/api/google/*`): the Flutter client
never holds the Canvas token — it pastes it once, the server verifies
it against the Canvas host and stores it per sync-user (DB + Fernet).
Sync itself then goes through GET /api/canvas/submissions from every
platform. Tokens are password-equivalent, so the host is allowlisted
to *.instructure.com (see app.canvas.validate_host).
"""

from __future__ import annotations

import datetime as dt

import httpx
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from .. import canvas as c
from ..db import get_session
from ..deps import require_jwt_user
from ..models import User
from ..oauth_store import (
    clear_connection,
    decrypt_secret,
    get_connection,
    save_connection,
)
from ..ratelimit import limit

router = APIRouter(prefix="/canvas", tags=["canvas"])

_PROVIDER = "canvas"
_DEFAULT_HOST = "byu.instructure.com"


class ConnectIn(BaseModel):
    token: str = ""
    host: str = _DEFAULT_HOST


async def _stored_token(session: AsyncSession, user_id: int) -> tuple[str, str]:
    """Return (token, host) or raise a reconnect-prompting error."""
    row = await get_connection(session, user_id, _PROVIDER)
    token = decrypt_secret(row.access_token) if row else ""
    host = row.item_id if row and row.item_id else ""
    if not row or not token or not host:
        raise c.CanvasAuthError("Canvas account not connected")
    return token, host


def _canvas_error(e: Exception, reconnect_statuses=(401, 403)):
    """Map proxy failures to (payload, status).

    Auth problems become 401/403 with needsReconnect so the app can
    prompt for a fresh token; everything else is a 502 with the
    upstream message preserved. Transport failures stay a plain 502.
    """
    status = 502
    payload: dict = {"error": str(e) or type(e).__name__}
    err_status = getattr(e, "status", None)
    if err_status in reconnect_statuses:
        status = err_status
        payload["needsReconnect"] = True
    elif err_status is None and isinstance(e, c.CanvasAuthError):
        status = 401
        payload["needsReconnect"] = True
    return payload, status


@router.get("/status")
async def status(
    user: User = Depends(require_jwt_user),
    session: AsyncSession = Depends(get_session),
):
    row = await get_connection(session, user.id, _PROVIDER)
    token = decrypt_secret(row.access_token) if row else ""
    host = row.item_id if row and row.item_id else ""
    return {
        "connected": bool(token and host),
        "host": host or None,
    }


@router.post("/connect")
async def connect(
    body: ConnectIn,
    user: User = Depends(require_jwt_user),
    session: AsyncSession = Depends(get_session),
    _rl: None = Depends(limit("canvas:connect", 30, 60, by_user=True)),
):
    token = body.token.strip()
    if not token:
        raise HTTPException(status_code=400, detail="Missing Canvas token")
    try:
        host = c.validate_host(body.host)
    except c.CanvasAuthError as e:
        raise HTTPException(status_code=400, detail=str(e))
    try:
        await c.verify_token(host, token)
    except c.CanvasAuthError as e:
        payload, status = _canvas_error(e)
        raise HTTPException(status_code=status, detail=payload)
    except httpx.HTTPError as e:
        raise HTTPException(
            status_code=502, detail={"error": f"Cannot reach {host}: {e}"}
        )
    await save_connection(
        session,
        user.id,
        _PROVIDER,
        access_token=token,
        refresh_token="",
        item_id=host,
        scopes="canvas-planner",
        expires_at=None,
        merge_refresh=False,
    )
    return {"status": "connected", "host": host}


@router.post("/disconnect")
async def disconnect(
    user: User = Depends(require_jwt_user),
    session: AsyncSession = Depends(get_session),
):
    await clear_connection(session, user.id, _PROVIDER)
    return {"status": "disconnected"}


@router.get("/submissions")
async def submissions(
    start_date: str | None = None,
    end_date: str | None = None,
    user: User = Depends(require_jwt_user),
    session: AsyncSession = Depends(get_session),
    _rl: None = Depends(limit("canvas:submissions", 60, 60, by_user=True)),
):
    try:
        token, host = await _stored_token(session, user.id)
        items = await c.list_planner_items(host, token, start_date, end_date)
    except (c.CanvasAuthError, httpx.HTTPError) as e:
        payload, status = _canvas_error(e)
        raise HTTPException(status_code=status, detail=payload)
    return {
        "host": host,
        "submissions": items,
        "fetched_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    }
