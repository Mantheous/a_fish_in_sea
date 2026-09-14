"""Google Calendar/People API logic (async port of the retired Flask logic).

All functions take an explicit access token — per-user token storage
lives in oauth_store.py (DB, Fernet-encrypted). No globals, no files.
"""

from __future__ import annotations

import datetime as dt
import os
import time
import urllib.parse
from typing import Any

import httpx

GOOGLE_AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"
GOOGLE_CALENDAR_API = "https://www.googleapis.com/calendar/v3"
GOOGLE_PEOPLE_API = "https://people.googleapis.com/v1"
GOOGLE_CALENDAR_SCOPE = "https://www.googleapis.com/auth/calendar.events"
GOOGLE_CONTACTS_SCOPE = "https://www.googleapis.com/auth/contacts.readonly"
GOOGLE_SCOPE = f"{GOOGLE_CALENDAR_SCOPE} {GOOGLE_CONTACTS_SCOPE}"


class GoogleAuthError(Exception):
    def __init__(self, message: str, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


def google_credentials() -> tuple[str, str]:
    client_id = os.getenv("GOOGLE_CLIENT_ID")
    client_secret = os.getenv("GOOGLE_CLIENT_SECRET")
    if not client_id or not client_secret:
        raise GoogleAuthError(
            "Server is missing GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET"
        )
    return client_id, client_secret


def google_redirect_uri() -> str | None:
    value = os.getenv("GOOGLE_REDIRECT_URI")
    return value or None


def google_auth_url(redirect_uri: str, state: str) -> str:
    client_id, _ = google_credentials()
    params = {
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": GOOGLE_SCOPE,
        "access_type": "offline",
        "prompt": "consent",
        "include_granted_scopes": "true",
        "state": state,
    }
    return f"{GOOGLE_AUTH_ENDPOINT}?{urllib.parse.urlencode(params)}"


async def redeem_code(code: str, redirect_uri: str) -> dict[str, Any]:
    """Exchange an authorization code for tokens (caller stores them)."""
    client_id, client_secret = google_credentials()
    async with httpx.AsyncClient(timeout=30) as c:
        resp = await c.post(
            GOOGLE_TOKEN_ENDPOINT,
            data={
                "code": code,
                "client_id": client_id,
                "client_secret": client_secret,
                "redirect_uri": redirect_uri,
                "grant_type": "authorization_code",
            },
        )
    if resp.status_code != 200:
        raise GoogleAuthError(
            f"Token exchange failed ({resp.status_code}): {resp.text[:200]}"
        )
    tokens = resp.json()
    if not tokens.get("refresh_token"):
        # Caller merges with the stored refresh token when reconnecting;
        # first-ever connect without one is a real error.
        tokens["_needs_merge"] = True
    return tokens


async def refresh_access_token(refresh_token: str) -> tuple[str, float]:
    """Return (access_token, expires_at_epoch)."""
    client_id, client_secret = google_credentials()
    async with httpx.AsyncClient(timeout=30) as c:
        resp = await c.post(
            GOOGLE_TOKEN_ENDPOINT,
            data={
                "client_id": client_id,
                "client_secret": client_secret,
                "refresh_token": refresh_token,
                "grant_type": "refresh_token",
            },
        )
    if resp.status_code != 200:
        raise GoogleAuthError(
            f"Token refresh failed ({resp.status_code}): {resp.text[:200]}"
        )
    tokens = resp.json()
    return tokens["access_token"], time.time() + float(tokens.get("expires_in", 3600))


async def _calendar_request(
    access_token: str, path: str, params: dict[str, Any]
) -> Any:
    async with httpx.AsyncClient(timeout=30) as c:
        resp = await c.get(
            f"{GOOGLE_CALENDAR_API}{path}",
            headers={"Authorization": f"Bearer {access_token}"},
            params=params,
        )
    if resp.status_code != 200:
        raise GoogleAuthError(
            f"Calendar API call failed ({resp.status_code}): {resp.text[:200]}",
            status=resp.status_code,
        )
    return resp.json()


async def _calendar_write_request(
    access_token: str,
    method: str,
    path: str,
    body: dict[str, Any] | None = None,
) -> dict[str, Any]:
    async with httpx.AsyncClient(timeout=30) as c:
        resp = await c.request(
            method,
            f"{GOOGLE_CALENDAR_API}{path}",
            headers={
                "Authorization": f"Bearer {access_token}",
                "Content-Type": "application/json",
            },
            json=body,
        )
    if resp.status_code in (200, 201):
        return resp.json() if resp.text else {}
    if resp.status_code == 204:
        return {}
    if resp.status_code == 403:
        raise GoogleAuthError(
            "Google denied this change (insufficient permissions). "
            "Disconnect and reconnect your Google account to allow editing.",
            status=403,
        )
    if resp.status_code == 404:
        raise GoogleAuthError(
            "That event no longer exists on Google Calendar.",
            status=404,
        )
    raise GoogleAuthError(
        f"Calendar write failed ({resp.status_code}): {resp.text[:200]}",
        status=resp.status_code,
    )


async def list_calendars(access_token: str) -> list[dict[str, Any]]:
    calendars: list[dict[str, Any]] = []
    page_token: str | None = None
    while True:
        params: dict[str, Any] = {"minAccessRole": "reader", "maxResults": 100}
        if page_token:
            params["pageToken"] = page_token
        data = await _calendar_request(
            access_token, "/users/me/calendarList", params
        )
        for entry in data.get("items", []):
            calendars.append(
                {
                    "id": entry.get("id"),
                    "summary": entry.get("summary") or "(untitled)",
                    "primary": bool(entry.get("primary")),
                    "accessRole": entry.get("accessRole"),
                    "backgroundColor": entry.get("backgroundColor"),
                    "foregroundColor": entry.get("foregroundColor"),
                }
            )
        page_token = data.get("nextPageToken")
        if not page_token:
            break
    return calendars


_colors_cache: dict[str, Any] = {}
_colors_cached_at = 0.0
_colors_ttl = 3600.0


async def get_color_palettes(access_token: str) -> dict[str, Any]:
    global _colors_cache, _colors_cached_at
    if _colors_cache and time.time() - _colors_cached_at < _colors_ttl:
        return _colors_cache
    data = await _calendar_request(access_token, "/colors", {})
    _colors_cache = data if isinstance(data, dict) else {}
    _colors_cached_at = time.time()
    return _colors_cache


def _palette_color(
    palettes: dict[str, Any], section: str, color_id: str | None
) -> tuple[str | None, str | None]:
    if not color_id:
        return None, None
    section_map = palettes.get(section)
    if not isinstance(section_map, dict):
        return None, None
    entry = section_map.get(color_id)
    if not isinstance(entry, dict):
        return None, None
    return entry.get("background"), entry.get("foreground")


async def enrich_events_with_colors(
    access_token: str,
    calendar_id: str,
    events: list[dict[str, Any]],
) -> dict[str, str | None]:
    palettes = await get_color_palettes(access_token)
    event_palette = palettes.get("event") if isinstance(palettes, dict) else None
    if not isinstance(event_palette, dict):
        event_palette = {}

    calendar_colors: dict[str, str | None] = {
        "backgroundColor": None,
        "foregroundColor": None,
    }
    try:
        entry = await _calendar_request(
            access_token,
            f"/users/me/calendarList/{urllib.parse.quote(calendar_id, safe='')}",
            {},
        )
        if isinstance(entry, dict):
            calendar_colors = {
                "backgroundColor": entry.get("backgroundColor"),
                "foregroundColor": entry.get("foregroundColor"),
            }
    except GoogleAuthError:
        pass

    for event in events:
        bg, fg = _palette_color(palettes, "event", event.get("colorId"))
        event["backgroundColor"] = bg or calendar_colors["backgroundColor"]
        event["foregroundColor"] = fg or calendar_colors["foregroundColor"]
    return calendar_colors


def _iso_or_none(value: dict[str, Any] | None) -> str | None:
    if not value:
        return None
    return value.get("dateTime") or value.get("date")


def normalize_event(item: dict[str, Any]) -> dict[str, Any] | None:
    if item.get("status") == "cancelled":
        return None
    recurrence = item.get("recurrence")
    return {
        "id": item.get("id"),
        "summary": item.get("summary"),
        "description": item.get("description"),
        "location": item.get("location"),
        "allDay": "date" in (item.get("start") or {}),
        "colorId": item.get("colorId"),
        "start": _iso_or_none(item.get("start")),
        "end": _iso_or_none(item.get("end")),
        "recurrence": recurrence if isinstance(recurrence, list) else None,
        "seriesId": item.get("recurringEventId"),
    }


async def list_events(
    access_token: str,
    calendar_id: str,
    time_min: str | None = None,
    time_max: str | None = None,
) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    page_token: str | None = None
    while True:
        params: dict[str, Any] = {
            "singleEvents": "true",
            "orderBy": "startTime",
            "maxResults": 250,
        }
        if page_token:
            params["pageToken"] = page_token
        if time_min:
            params["timeMin"] = time_min
        if time_max:
            params["timeMax"] = time_max
        data = await _calendar_request(
            access_token,
            f"/calendars/{urllib.parse.quote(calendar_id, safe='')}/events",
            params,
        )
        for item in data.get("items", []):
            normalized = normalize_event(item)
            if normalized is not None:
                events.append(normalized)
        page_token = data.get("nextPageToken")
        if not page_token:
            break
    return events


def default_sync_window() -> tuple[str, str]:
    now = dt.datetime.now(dt.timezone.utc)
    time_min = (now - dt.timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%SZ")
    time_max = (now + dt.timedelta(days=180)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return time_min, time_max


def _event_path(calendar_id: str, event_id: str | None = None) -> str:
    base = f"/calendars/{urllib.parse.quote(calendar_id, safe='')}/events"
    if event_id:
        return f"{base}/{urllib.parse.quote(event_id, safe='')}"
    return base


def event_body(
    summary: str | None,
    description: str | None,
    location: str | None,
    start: str | None,
    end: str | None,
    all_day: bool,
    recurrence: list[str] | None = None,
) -> dict[str, Any]:
    body: dict[str, Any] = {}
    if summary is not None:
        body["summary"] = summary
    if description is not None:
        body["description"] = description
    if location is not None:
        body["location"] = location
    if recurrence is not None:
        body["recurrence"] = recurrence
    if start is not None or end is not None:
        if all_day:
            if start is not None:
                body["start"] = {"date": start[:10]}
            if end is not None:
                body["end"] = {"date": end[:10]}
        else:
            if start is not None:
                body["start"] = {"dateTime": start}
            if end is not None:
                body["end"] = {"dateTime": end}
    return body


async def create_event(
    access_token: str, calendar_id: str, body: dict[str, Any]
) -> dict[str, Any] | None:
    item = await _calendar_write_request(
        access_token, "POST", _event_path(calendar_id), body
    )
    return normalize_event(item)


async def update_event(
    access_token: str, calendar_id: str, event_id: str, body: dict[str, Any]
) -> dict[str, Any] | None:
    item = await _calendar_write_request(
        access_token, "PATCH", _event_path(calendar_id, event_id), body
    )
    return normalize_event(item)


async def delete_event(access_token: str, calendar_id: str, event_id: str) -> None:
    await _calendar_write_request(
        access_token, "DELETE", _event_path(calendar_id, event_id)
    )


async def get_event(
    access_token: str, calendar_id: str, event_id: str
) -> dict[str, Any] | None:
    data = await _calendar_request(
        access_token, _event_path(calendar_id, event_id), {}
    )
    if not isinstance(data, dict):
        return None
    return normalize_event(data)


async def _people_request(
    access_token: str, path: str, params: dict[str, Any]
) -> Any:
    async with httpx.AsyncClient(timeout=30) as c:
        resp = await c.get(
            f"{GOOGLE_PEOPLE_API}{path}",
            headers={"Authorization": f"Bearer {access_token}"},
            params=params,
        )
    if resp.status_code != 200:
        raise GoogleAuthError(
            f"People API call failed ({resp.status_code}): {resp.text[:200]}",
            status=resp.status_code,
        )
    return resp.json()


def normalize_contact(person: dict[str, Any]) -> dict[str, Any] | None:
    if not isinstance(person, dict):
        return None
    resource = person.get("resourceName")
    display_name: str | None = None
    for name in person.get("names") or []:
        if not isinstance(name, dict):
            continue
        candidate = (name.get("displayName") or "").strip()
        if candidate:
            display_name = candidate
            break
    emails = [
        e.get("value", "").strip()
        for e in (person.get("emailAddresses") or [])
        if isinstance(e, dict) and (e.get("value") or "").strip()
    ]
    if not display_name and emails:
        display_name = emails[0]
    if not display_name:
        return None
    photo_url: str | None = None
    for photo in person.get("photos") or []:
        if isinstance(photo, dict) and (photo.get("url") or "").strip():
            photo_url = photo["url"].strip()
            break
    contact_id = resource or (emails[0] if emails else display_name)
    if not contact_id:
        return None
    return {
        "id": contact_id,
        "displayName": display_name,
        "email": emails[0] if emails else None,
        "photoUrl": photo_url,
    }


async def list_contacts(
    access_token: str, page_size: int = 200
) -> list[dict[str, Any]]:
    contacts: list[dict[str, Any]] = []
    page_token: str | None = None
    while True:
        params: dict[str, Any] = {
            "resourceName": "people/me",
            "pageSize": max(1, min(page_size, 1000)),
            "personFields": "names,emailAddresses,photos",
            "sortOrder": "FIRST_NAME_ASCENDING",
        }
        if page_token:
            params["pageToken"] = page_token
        data = await _people_request(
            access_token, "/people/me/connections", params
        )
        for person in data.get("connections", []):
            normalized = normalize_contact(person)
            if normalized is not None:
                contacts.append(normalized)
        page_token = data.get("nextPageToken")
        if not page_token:
            break
    return contacts
