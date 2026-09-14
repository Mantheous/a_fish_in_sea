"""Per-user Google Calendar/People proxy.

Same URL contracts as the old Flask server (`/api/google/*`), so the
Flutter client needs no changes — but tokens are now per sync-user
(DB + Fernet) instead of one global connection. The OAuth `state`
param carries a short-lived signed JWT binding the browser callback
to the user who started the flow, so connecting works from any
device (redirect URI still comes from GOOGLE_REDIRECT_URI or the
request host).
"""

from __future__ import annotations

import datetime as dt
import secrets

import jwt
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import HTMLResponse
from sqlalchemy.ext.asyncio import AsyncSession

from .. import google as g
from ..config import get_settings
from ..db import get_session
from ..deps import get_current_user
from ..models import User
from ..oauth_store import (
    clear_connection,
    decrypt_secret,
    get_connection,
    save_connection,
)

router = APIRouter(prefix="/google", tags=["google"])

_PROVIDER = "google"


def _oauth_state_token(user_id: int) -> str:
    s = get_settings()
    now = dt.datetime.now(dt.timezone.utc)
    return jwt.encode(
        {
            "type": "oauth_state",
            "sub": str(user_id),
            "nonce": secrets.token_hex(8),
            "exp": now + dt.timedelta(minutes=10),
            "iat": now,
        },
        s.jwt_secret,
        algorithm=s.jwt_algorithm,
    )


def _oauth_state_user(raw: str) -> int:
    s = get_settings()
    try:
        payload = jwt.decode(raw, s.jwt_secret, algorithms=[s.jwt_algorithm])
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid OAuth state")
    if payload.get("type") != "oauth_state":
        raise HTTPException(status_code=400, detail="Invalid OAuth state")
    return int(payload["sub"])


def _redirect_uri(request: Request) -> str:
    return g.google_redirect_uri() or (
        str(request.base_url).rstrip("/") + "/api/google/callback"
    )


async def _access_token(session: AsyncSession, user_id: int) -> str:
    row = await get_connection(session, user_id, _PROVIDER)
    refresh = decrypt_secret(row.refresh_token) if row else ""
    if not row or not refresh:
        raise g.GoogleAuthError("Google account not connected")
    access = decrypt_secret(row.access_token)
    skew_ok = (
        access
        and row.expires_at is not None
        and row.expires_at.tzinfo is not None
        and dt.datetime.now(dt.timezone.utc)
        < row.expires_at - dt.timedelta(seconds=60)
    )
    # Naive datetimes (sqlite round-trip) compare in UTC.
    if not skew_ok and row.expires_at is not None and row.expires_at.tzinfo is None:
        skew_ok = bool(
            access
            and dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)
            < row.expires_at - dt.timedelta(seconds=60)
        )
    if skew_ok:
        return access
    new_access, expires_at = await g.refresh_access_token(refresh)
    await save_connection(
        session,
        user_id,
        _PROVIDER,
        access_token=new_access,
        expires_at=dt.datetime.fromtimestamp(expires_at, dt.timezone.utc),
    )
    return new_access


def _google_error(e: g.GoogleAuthError, reconnect_statuses=(401, 403)):
    status = 502
    payload: dict = {"error": str(e)}
    if e.status in reconnect_statuses:
        status = e.status
        payload["needsReconnect"] = True
    return payload, status


@router.get("/auth_url")
async def auth_url(
    request: Request,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    try:
        g.google_credentials()
    except g.GoogleAuthError as e:
        raise HTTPException(status_code=500, detail=str(e))
    redirect_uri = _redirect_uri(request)
    return {
        "url": g.google_auth_url(redirect_uri, _oauth_state_token(user.id)),
        "redirect_uri": redirect_uri,
    }


@router.get("/callback", response_class=HTMLResponse)
async def callback(
    request: Request,
    code: str | None = None,
    state: str | None = None,
    error: str | None = None,
    session: AsyncSession = Depends(get_session),
):
    if error:
        return HTMLResponse(f"Google authorization failed: {error}", status_code=400)
    if not code or not state:
        return HTMLResponse("Missing code in Google callback", status_code=400)
    user_id = _oauth_state_user(state)
    redirect_uri = _redirect_uri(request)
    try:
        tokens = await g.redeem_code(code, redirect_uri)
    except g.GoogleAuthError as e:
        return HTMLResponse(f"Google connect failed: {e}", status_code=500)
    refresh = tokens.get("refresh_token") or ""
    granted = tokens.get("scope") or g.GOOGLE_SCOPE
    if not refresh and tokens.get("_needs_merge"):
        row = await get_connection(session, user_id, _PROVIDER)
        refresh = decrypt_secret(row.refresh_token) if row else ""
    if not refresh:
        return HTMLResponse(
            "Google did not return a refresh token; try again.", status_code=500
        )
    await save_connection(
        session,
        user_id,
        _PROVIDER,
        access_token=tokens.get("access_token") or "",
        refresh_token=refresh,
        scopes=granted if isinstance(granted, str) else " ".join(granted),
        expires_at=dt.datetime.now(dt.timezone.utc)
        + dt.timedelta(seconds=float(tokens.get("expires_in", 3600))),
    )
    return HTMLResponse(
        "<!doctype html><html><head><meta charset='utf-8'>"
        "<title>Google connected</title></head>"
        "<body style='font-family:sans-serif;text-align:center;"
        "padding-top:4rem'><h2>Google Calendar connected</h2>"
        "<p>You can close this window and return to the app.</p>"
        "</body></html>"
    )


@router.get("/status")
async def status(
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    row = await get_connection(session, user.id, _PROVIDER)
    scopes = (row.scopes.split() if row and row.scopes else [])
    return {
        "connected": bool(row and decrypt_secret(row.refresh_token)),
        "email": row.item_id if row and row.item_id else None,
        "contactsGranted": g.GOOGLE_CONTACTS_SCOPE in scopes,
        "scopes": scopes,
    }


@router.post("/disconnect")
async def disconnect(
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    await clear_connection(session, user.id, _PROVIDER)
    return {"status": "disconnected"}


@router.get("/calendars")
async def calendars(
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    try:
        token = await _access_token(session, user.id)
        return {"calendars": await g.list_calendars(token)}
    except g.GoogleAuthError as e:
        payload, status = _google_error(e)
        raise HTTPException(status_code=status, detail=payload)


@router.get("/contacts")
async def contacts(
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    try:
        token = await _access_token(session, user.id)
        return {"contacts": await g.list_contacts(token)}
    except g.GoogleAuthError as e:
        payload, status = _google_error(e)
        raise HTTPException(status_code=status, detail=payload)


@router.get("/events")
async def events(
    calendarId: str | None = None,
    timeMin: str | None = None,
    timeMax: str | None = None,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    if not calendarId:
        raise HTTPException(status_code=400, detail="Missing calendarId parameter")
    if not timeMin or not timeMax:
        default_min, default_max = g.default_sync_window()
        timeMin = timeMin or default_min
        timeMax = timeMax or default_max
    try:
        token = await _access_token(session, user.id)
        found = await g.list_events(token, calendarId, timeMin, timeMax)
        colors = await g.enrich_events_with_colors(token, calendarId, found)
    except g.GoogleAuthError as e:
        payload, status = _google_error(e)
        raise HTTPException(status_code=status, detail=payload)
    return {"events": found, "calendar": colors}


def _write_payload(required: tuple[str, ...], data: dict):
    missing = [k for k in required if not data.get(k)]
    if missing:
        raise HTTPException(
            status_code=400, detail=f"Missing fields: {', '.join(missing)}"
        )
    return data


def _recurrence(data: dict):
    recurrence = data.get("recurrence")
    if recurrence is None:
        return None
    if isinstance(recurrence, list):
        return [str(r) for r in recurrence]
    return None


@router.get("/events/one")
async def get_one(
    calendarId: str | None = None,
    eventId: str | None = None,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    if not calendarId or not eventId:
        raise HTTPException(status_code=400, detail="Missing calendarId or eventId")
    try:
        token = await _access_token(session, user.id)
        event = await g.get_event(token, calendarId, eventId)
    except g.GoogleAuthError as e:
        payload, status = _google_error(e, reconnect_statuses=(403, 404))
        if status == 404:
            raise HTTPException(status_code=404, detail=payload)
        raise HTTPException(status_code=status, detail=payload)
    if event is None:
        raise HTTPException(status_code=404, detail={"error": "Event not found"})
    return {"event": event}


@router.post("/events")
async def create(
    data: dict,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    _write_payload(("calendarId",), data)
    try:
        token = await _access_token(session, user.id)
        event = await g.create_event(
            token,
            data["calendarId"],
            g.event_body(
                data.get("summary"),
                data.get("description"),
                data.get("location"),
                data.get("start"),
                data.get("end"),
                bool(data.get("allDay")),
                _recurrence(data),
            ),
        )
    except g.GoogleAuthError as e:
        payload, status = _google_error(e, reconnect_statuses=(403, 404))
        raise HTTPException(status_code=status, detail=payload)
    return {"event": event}


@router.patch("/events")
async def update(
    data: dict,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    _write_payload(("calendarId", "eventId"), data)
    try:
        token = await _access_token(session, user.id)
        event = await g.update_event(
            token,
            data["calendarId"],
            data["eventId"],
            g.event_body(
                data.get("summary"),
                data.get("description"),
                data.get("location"),
                data.get("start"),
                data.get("end"),
                bool(data.get("allDay")),
                _recurrence(data),
            ),
        )
    except g.GoogleAuthError as e:
        payload, status = _google_error(e, reconnect_statuses=(403, 404))
        raise HTTPException(status_code=status, detail=payload)
    return {"event": event}


@router.delete("/events")
async def delete(
    data: dict,
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    _write_payload(("calendarId", "eventId"), data)
    try:
        token = await _access_token(session, user.id)
        await g.delete_event(token, data["calendarId"], data["eventId"])
    except g.GoogleAuthError as e:
        payload, status = _google_error(e, reconnect_statuses=(403, 404))
        raise HTTPException(status_code=status, detail=payload)
    return {"deleted": True}
