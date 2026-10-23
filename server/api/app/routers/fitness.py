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
from fastapi.responses import HTMLResponse, RedirectResponse
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


# Cookie binding the browser that STARTED the flow to the browser that
# approves it. Without it, an attacker could mint a consent link on their
# own account, have a victim approve it, and end up holding the victim's
# Strava tokens (including private activities).
_COOKIE = "fitness_oauth_nonce"
_COOKIE_TTL = 10 * 60


def _state_token(user_id: int, nonce: str, *, kind: str, ttl: dt.timedelta) -> str:
    cfg = get_settings()
    now = dt.datetime.now(dt.timezone.utc)
    return jwt.encode(
        {
            "type": kind,
            "provider": _PROVIDER,
            "sub": str(user_id),
            "nonce": nonce,
            "exp": now + ttl,
            "iat": now,
        },
        cfg.jwt_secret,
        algorithm=cfg.jwt_algorithm,
    )


def _decode_state(raw: str, *, kind: str) -> tuple[int, str]:
    cfg = get_settings()
    try:
        payload = jwt.decode(
            raw, cfg.jwt_secret, algorithms=[cfg.jwt_algorithm]
        )
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid OAuth state")
    if payload.get("type") != kind or payload.get("provider") != _PROVIDER:
        raise HTTPException(status_code=400, detail="Invalid OAuth state")
    nonce = payload.get("nonce")
    if not isinstance(nonce, str) or not nonce:
        raise HTTPException(status_code=400, detail="Invalid OAuth state")
    return int(payload["sub"]), nonce


def _secure_request(request: Request) -> bool:
    proto = request.headers.get("x-forwarded-proto", "").split(",")[0].strip()
    if proto:
        return proto == "https"
    return request.url.scheme == "https"


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
    # The browser must open /start itself: that response sets the nonce
    # cookie which /callback then requires, proving the same browser both
    # started and approved the flow.
    nonce = secrets.token_hex(16)
    start = _state_token(
        user.id, nonce, kind="fitness_start", ttl=dt.timedelta(minutes=5)
    )
    return {
        "startPath": "/api/fitness/start?token=" + start,
        "redirect_uri": _redirect_uri(request),
    }


@router.get("/start")
async def start(request: Request, token: str | None = None):
    """Browser entry point: bind the nonce cookie, then go to Strava.

    A top-level browser navigation can't carry the app's Bearer JWT, so
    the short-lived signed [token] stands in for it. Reaching this route
    directly without it does nothing but bounce back to the app.
    """
    csp = {"Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'"}
    if not token:
        return HTMLResponse(
            _page(
                "Strava connection failed",
                "Start the connection from the app's Settings page.",
                ok=False,
            ),
            status_code=400,
            headers=csp,
        )
    try:
        user_id, nonce = _decode_state(token, kind="fitness_start")
    except HTTPException:
        return HTMLResponse(
            _page(
                "Strava connection failed",
                "This connection link expired — start again from Settings.",
                ok=False,
            ),
            status_code=400,
            headers=csp,
        )
    redirect_uri = _redirect_uri(request)
    try:
        url = s.strava_auth_url(
            redirect_uri,
            _state_token(
                user_id,
                nonce,
                kind="oauth_state",
                ttl=dt.timedelta(minutes=10),
            ),
        )
    except s.StravaAuthError as e:
        return HTMLResponse(
            _page("Strava connection failed", html.escape(str(e)), ok=False),
            status_code=503,
            headers=csp,
        )
    response = RedirectResponse(url, status_code=302)
    response.set_cookie(
        _COOKIE,
        nonce,
        max_age=_COOKIE_TTL,
        httponly=True,
        samesite="lax",
        secure=_secure_request(request),
        path="/",
    )
    return response


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
        user_id, state_nonce = _decode_state(state, kind="oauth_state")
    except HTTPException:
        return HTMLResponse(
            _page(
                "Strava connection failed",
                "This link expired — try again from Settings.",
                ok=False,
            ),
            status_code=400,
            headers=csp,
        )
    cookie_nonce = request.cookies.get(_COOKIE, "")
    if not cookie_nonce or not secrets.compare_digest(cookie_nonce, state_nonce):
        # No (or wrong) browser binding: someone else started this consent
        # URL. Never bind their Strava account to this app user.
        return HTMLResponse(
            _page(
                "Strava connection failed",
                "This consent link was opened in a different browser than "
                "the one that started it. Go back to Settings and press "
                "Connect Strava again.",
                ok=False,
            ),
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
    response = HTMLResponse(
        _page(
            "Strava connected",
            "You can close this tab and return to the app.",
            ok=True,
        ),
        headers=csp,
    )
    response.delete_cookie(_COOKIE, path="/")
    return response


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
