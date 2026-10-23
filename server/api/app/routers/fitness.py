"""Strava fitness integration (watch-recorded workouts).

Garmin, Coros, Wahoo and Polar all push activities to Strava, and any
Strava user can register a free API app — so Strava is the self-serve
connector, with no partner agreement required. Tokens are stored
per-user via oauth_store (provider "strava") and never leave the server.

Sleep is NOT part of the Strava API: sleep goals stay unsupported and
the client says so instead of pretending to track them.
"""

from __future__ import annotations

import datetime as dt
import html
import secrets

import httpx
import jwt
from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import HTMLResponse
from sqlalchemy.ext.asyncio import AsyncSession

from .. import strava as s
from ..config import get_settings
from ..db import get_session
from ..deps import require_jwt_user
from ..models import User
from ..oauth_store import (
    clear_connection,
    decrypt_secret,
    get_connection,
    save_connection,
)

router = APIRouter(prefix="/fitness", tags=["fitness"])

_PROVIDER = "strava"

# Activity sync window when the client doesn't ask for one: recent
# workouts are what auto-report and goal progress need.
_DEFAULT_DAYS = 30
_MAX_DAYS = 365


def _oauth_state_token(user_id: int) -> str:
    cfg = get_settings()
    now = dt.datetime.now(dt.timezone.utc)
    return jwt.encode(
        {
            "type": "oauth_state",
            "provider": _PROVIDER,
            "sub": str(user_id),
            "nonce": secrets.token_hex(8),
            "exp": now + dt.timedelta(minutes=10),
            "iat": now,
        },
        cfg.jwt_secret,
        algorithm=cfg.jwt_algorithm,
    )


def _oauth_state_user(raw: str) -> int:
    cfg = get_settings()
    try:
        payload = jwt.decode(
            raw, cfg.jwt_secret, algorithms=[cfg.jwt_algorithm]
        )
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid OAuth state")
    if payload.get("type") != "oauth_state" or payload.get("provider") != _PROVIDER:
        raise HTTPException(status_code=400, detail="Invalid OAuth state")
    return int(payload["sub"])


def _redirect_uri(request: Request) -> str:
    base = str(request.base_url).rstrip("/")
    return s.default_redirect_uri(base)


def _expires_at(epoch: object) -> dt.datetime | None:
    try:
        return dt.datetime.fromtimestamp(float(epoch), dt.timezone.utc)
    except (TypeError, ValueError, OSError):
        return None


def _needs_refresh(row, now: dt.datetime) -> bool:
    expires = row.expires_at
    if expires is None:
        return False
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=dt.timezone.utc)
    return now >= expires - dt.timedelta(seconds=120)


async def _access_token(session: AsyncSession, user_id: int) -> str:
    row = await get_connection(session, user_id, _PROVIDER)
    if row is None:
        raise s.StravaAuthError("Strava account not connected")
    access = decrypt_secret(row.access_token)
    refresh = decrypt_secret(row.refresh_token)
    if access and not _needs_refresh(row, dt.datetime.now(dt.timezone.utc)):
        return access
    if not refresh:
        if access:
            return access
        raise s.StravaAuthError("Strava connection needs renewal", status=401)
    tokens = await s.refresh_access_token(refresh)
    new_access = str(tokens.get("access_token") or "")
    await save_connection(
        session,
        user_id,
        _PROVIDER,
        access_token=new_access,
        refresh_token=str(tokens.get("refresh_token") or "") or refresh,
        expires_at=_expires_at(tokens.get("expires_at")),
    )
    await session.commit()
    return new_access


def _error_payload(e: Exception) -> tuple[dict, int]:
    payload: dict = {"error": str(e) or type(e).__name__}
    status = getattr(e, "status", None)
    if isinstance(e, s.StravaAuthError) and status in (401, 403):
        return {**payload, "needsReconnect": True}, status
    if isinstance(e, s.StravaAuthError) and status is None:
        # Not connected / missing refresh token: the only fix is to connect.
        return {**payload, "needsReconnect": True}, 401
    return payload, 502


@router.get("/status")
async def status(
    request: Request,
    user: User = Depends(require_jwt_user),
    session: AsyncSession = Depends(get_session),
):
    row = await get_connection(session, user.id, _PROVIDER)
    connected = bool(row and decrypt_secret(row.refresh_token))
    return {
        "provider": _PROVIDER,
        "connected": connected,
        "configured": s.strava_configured(),
        "athlete": row.item_id if row and row.item_id else None,
        # Shown in Settings so the callback URL to register on the Strava
        # app is never a guess (reverse proxies rewrite the public host).
        "redirectUri": _redirect_uri(request),
        "supportsSleep": False,
    }


@router.get("/auth_url")
async def auth_url(
    request: Request,
    user: User = Depends(require_jwt_user),
):
    try:
        s.strava_credentials()
    except s.StravaAuthError as e:
        raise HTTPException(
            status_code=503,
            detail={
                "error": str(e),
                "needsSetup": True,
                "redirectUri": _redirect_uri(request),
            },
        )
    redirect_uri = _redirect_uri(request)
    return {
        "url": s.strava_auth_url(redirect_uri, _oauth_state_token(user.id)),
        "redirect_uri": redirect_uri,
    }


@router.get("/callback", response_class=HTMLResponse)
async def callback(
    request: Request,
    code: str | None = None,
    state: str | None = None,
    error: str | None = None,
    error_description: str | None = None,
    scope: str | None = None,
    session: AsyncSession = Depends(get_session),
):
    csp = {"Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'"}
    if error:
        detail = error_description or error
        return HTMLResponse(
            _page(
                "Strava connection failed",
                html.escape(detail),
                ok=False,
            ),
            status_code=400,
            headers=csp,
        )
    if not code or not state:
        return HTMLResponse(
            _page("Strava connection failed", "Missing code in callback", ok=False),
            status_code=400,
            headers=csp,
        )
    try:
        user_id = _oauth_state_user(state)
    except HTTPException:
        return HTMLResponse(
            _page("Strava connection failed", "This link expired — try again from Settings.", ok=False),
            status_code=400,
            headers=csp,
        )
    user = await session.get(User, user_id)
    if user is None:
        return HTMLResponse(
            _page("Strava connection failed", "Unknown account", ok=False),
            status_code=400,
            headers=csp,
        )
    try:
        tokens = await s.redeem_code(code, _redirect_uri(request))
    except (s.StravaAuthError, httpx.HTTPError) as e:
        return HTMLResponse(
            _page("Strava connection failed", html.escape(str(e)), ok=False),
            status_code=500,
            headers=csp,
        )
    access = str(tokens.get("access_token") or "")
    refresh = str(tokens.get("refresh_token") or "")
    if not access or not refresh:
        return HTMLResponse(
            _page(
                "Strava connection failed",
                "Strava did not return a refresh token — try again.",
                ok=False,
            ),
            status_code=500,
            headers=csp,
        )
    athlete = tokens.get("athlete") or {}
    name = " ".join(
        part for part in (athlete.get("firstname"), athlete.get("lastname"))
        if isinstance(part, str) and part.strip()
    ).strip()
    await save_connection(
        session,
        user_id,
        _PROVIDER,
        access_token=access,
        refresh_token=refresh,
        item_id=name or str(athlete.get("id") or ""),
        scopes=scope or s.STRAVA_SCOPE,
        expires_at=_expires_at(tokens.get("expires_at")),
    )
    await session.commit()
    return HTMLResponse(
        _page(
            "Strava connected",
            "You can close this tab and return to the app.",
            ok=True,
        ),
        headers=csp,
    )


def _page(title: str, message: str, *, ok: bool) -> str:
    color = "#16a34a" if ok else "#dc2626"
    return (
        "<!doctype html><html><head><meta charset='utf-8'>"
        f"<title>{html.escape(title)}</title></head>"
        "<body style='font-family:sans-serif;text-align:center;padding-top:4rem'>"
        f"<h2 style='color:{color}'>{html.escape(title)}</h2>"
        f"<p>{message}</p></body></html>"
    )


@router.post("/disconnect")
async def disconnect(
    user: User = Depends(require_jwt_user),
    session: AsyncSession = Depends(get_session),
):
    row = await get_connection(session, user.id, _PROVIDER)
    if row is not None:
        await s.deauthorize(decrypt_secret(row.access_token))
    await clear_connection(session, user.id, _PROVIDER)
    return {"status": "disconnected"}


@router.get("/activities")
async def activities(
    days: int = Query(_DEFAULT_DAYS, ge=1, le=_MAX_DAYS),
    user: User = Depends(require_jwt_user),
    session: AsyncSession = Depends(get_session),
):
    before = dt.datetime.now(dt.timezone.utc)
    after = before - dt.timedelta(days=days)
    try:
        token = await _access_token(session, user.id)
        found = await s.list_activities(token, after, before)
    except (s.StravaAuthError, httpx.HTTPError) as e:
        payload, code = _error_payload(e)
        raise HTTPException(status_code=code, detail=payload)
    return {"activities": found, "connected": True, "provider": _PROVIDER}


@router.get("/sleep")
async def sleep(
    user: User = Depends(require_jwt_user),
    session: AsyncSession = Depends(get_session),
):
    row = await get_connection(session, user.id, _PROVIDER)
    return {
        "sleep": [],
        "connected": bool(row and decrypt_secret(row.refresh_token)),
        "supported": False,
        "detail": "Strava does not expose sleep data.",
    }
