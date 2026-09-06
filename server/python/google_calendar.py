"""Google Calendar OAuth + event sync for the Python server.

Handles the OAuth code flow (Web application client), token storage, and
Calendar API reads and writes (create/update/delete).

Google requires HTTPS for OAuth redirect URIs (except localhost), so the
one-time connect flow must happen from a URL registered in the Google
Cloud console — by default http://localhost:<port> on the host machine.
The connection is stored globally (single-user personal server), so after
connecting once, every app instance syncs via /api/google/events.

NOTE: the OAuth scope is calendar.events (read + write). Tokens granted
under an older read-only scope must be reconnected before writes work —
write calls then fail with a 403 prompting the user to reconnect.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import threading
import time
import urllib.parse
from pathlib import Path
from typing import Any

import requests

GOOGLE_AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"
GOOGLE_CALENDAR_API = "https://www.googleapis.com/calendar/v3"
GOOGLE_SCOPE = "https://www.googleapis.com/auth/calendar.events"

_STORE_KEY = "default"  # single-user personal server: one shared connection
_STORE_PATH = Path(__file__).parent / ".google_users.json"
_LOCK = threading.Lock()


class GoogleAuthError(Exception):
    """Raised when OAuth credentials are missing or the API call fails."""

    def __init__(self, message: str, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


def _load_users() -> dict[str, dict[str, Any]]:
    if not _STORE_PATH.exists():
        return {}
    try:
        data = json.loads(_STORE_PATH.read_text())
        return data if isinstance(data, dict) else {}
    except (json.JSONDecodeError, OSError):
        return {}


def _save_users(users: dict[str, dict[str, Any]]) -> None:
    _STORE_PATH.write_text(json.dumps(users, indent=2))


def google_credentials() -> tuple[str, str]:
    client_id = os.getenv("GOOGLE_CLIENT_ID")
    client_secret = os.getenv("GOOGLE_CLIENT_SECRET")
    if not client_id or not client_secret:
        raise GoogleAuthError(
            "Server is missing GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET"
        )
    return client_id, client_secret


def google_redirect_uri() -> str | None:
    """Optional override; otherwise derived from the incoming request."""
    value = os.getenv("GOOGLE_REDIRECT_URI")
    return value or None


def google_auth_url(redirect_uri: str) -> str:
    client_id, _ = google_credentials()
    params = {
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": GOOGLE_SCOPE,
        "access_type": "offline",
        "prompt": "consent",
        "include_granted_scopes": "true",
        "state": _STORE_KEY,
    }
    return f"{GOOGLE_AUTH_ENDPOINT}?{urllib.parse.urlencode(params)}"


def exchange_code(code: str, redirect_uri: str) -> None:
    """Exchange an authorization code and persist the tokens."""
    client_id, client_secret = google_credentials()
    response = requests.post(
        GOOGLE_TOKEN_ENDPOINT,
        data={
            "code": code,
            "client_id": client_id,
            "client_secret": client_secret,
            "redirect_uri": redirect_uri,
            "grant_type": "authorization_code",
        },
        timeout=30,
    )
    if response.status_code != 200:
        raise GoogleAuthError(
            f"Token exchange failed ({response.status_code}): {response.text[:200]}"
        )
    tokens = response.json()
    refresh_token = tokens.get("refresh_token")
    with _LOCK:
        users = _load_users()
        record = users.get(_STORE_KEY) or {}
        if not refresh_token:
            refresh_token = record.get("refresh_token")
        if not refresh_token:
            raise GoogleAuthError(
                "Google did not return a refresh token; reconnect with "
                "prompt=consent"
            )
        users[_STORE_KEY] = {
            "refresh_token": refresh_token,
            "access_token": tokens.get("access_token"),
            "expires_at": time.time() + float(tokens.get("expires_in", 3600)),
        }
        _save_users(users)


def get_valid_access_token() -> str:
    client_id, client_secret = google_credentials()
    with _LOCK:
        record = _load_users().get(_STORE_KEY)
    if not record or not record.get("refresh_token"):
        raise GoogleAuthError("Google account not connected")
    if record.get("access_token") and time.time() < record.get(
        "expires_at", 0
    ) - 60:
        return record["access_token"]
    response = requests.post(
        GOOGLE_TOKEN_ENDPOINT,
        data={
            "client_id": client_id,
            "client_secret": client_secret,
            "refresh_token": record["refresh_token"],
            "grant_type": "refresh_token",
        },
        timeout=30,
    )
    if response.status_code != 200:
        raise GoogleAuthError(
            f"Token refresh failed ({response.status_code}): {response.text[:200]}"
        )
    tokens = response.json()
    with _LOCK:
        users = _load_users()
        if _STORE_KEY in users:
            users[_STORE_KEY]["access_token"] = tokens["access_token"]
            users[_STORE_KEY]["expires_at"] = time.time() + float(
                tokens.get("expires_in", 3600)
            )
            _save_users(users)
    return tokens["access_token"]


def google_status() -> dict[str, Any]:
    with _LOCK:
        record = _load_users().get(_STORE_KEY)
    return {
        "connected": bool(record and record.get("refresh_token")),
        "email": (record or {}).get("email"),
    }


def google_disconnect() -> None:
    with _LOCK:
        users = _load_users()
        users.pop(_STORE_KEY, None)
        _save_users(users)


def _calendar_request(access_token: str, path: str, params: dict[str, Any]):
    response = requests.get(
        f"{GOOGLE_CALENDAR_API}{path}",
        headers={"Authorization": f"Bearer {access_token}"},
        params=params,
        timeout=30,
    )
    if response.status_code != 200:
        raise GoogleAuthError(
            f"Calendar API call failed ({response.status_code}): "
            f"{response.text[:200]}",
            status=response.status_code,
        )
    return response.json()


def _calendar_write_request(
    access_token: str,
    method: str,
    path: str,
    body: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """POST/PATCH/DELETE against the Calendar API.

    Raises GoogleAuthError with status set; a 403 almost always means the
    stored token was granted a narrower (read-only) scope and the user
    must disconnect and reconnect their Google account.
    """
    response = requests.request(
        method,
        f"{GOOGLE_CALENDAR_API}{path}",
        headers={
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json",
        },
        json=body,
        timeout=30,
    )
    if response.status_code in (200, 201):
        return response.json() if response.text else {}
    if response.status_code == 204:
        return {}
    if response.status_code == 403:
        raise GoogleAuthError(
            "Google denied this change (insufficient permissions). "
            "Disconnect and reconnect your Google account to allow editing.",
            status=403,
        )
    if response.status_code == 404:
        raise GoogleAuthError(
            "That event no longer exists on Google Calendar.",
            status=404,
        )
    raise GoogleAuthError(
        f"Calendar write failed ({response.status_code}): "
        f"{response.text[:200]}",
        status=response.status_code,
    )


def list_calendars(access_token: str) -> list[dict[str, Any]]:
    """Calendar list entries the user can read: id, summary, colors."""
    calendars: list[dict[str, Any]] = []
    page_token: str | None = None
    while True:
        params: dict[str, Any] = {"minAccessRole": "reader", "maxResults": 100}
        if page_token:
            params["pageToken"] = page_token
        data = _calendar_request(access_token, "/users/me/calendarList", params)
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


_COLORS_CACHE: dict[str, Any] = {}
_COLORS_CACHED_AT = 0.0
_COLORS_TTL_SECONDS = 3600.0


def get_color_palettes(access_token: str) -> dict[str, Any]:
    """ColorId → {background, foreground} maps, cached for an hour.

    Google events only carry a `colorId`; the hex values live behind the
    `colors.get` endpoint, split into `calendar` and `event` palettes.
    """
    global _COLORS_CACHE, _COLORS_CACHED_AT
    with _LOCK:
        if _COLORS_CACHE and time.time() - _COLORS_CACHED_AT < _COLORS_TTL_SECONDS:
            return _COLORS_CACHE
    data = _calendar_request(access_token, "/colors", {})
    with _LOCK:
        _COLORS_CACHE = data if isinstance(data, dict) else {}
        _COLORS_CACHED_AT = time.time()
        return _COLORS_CACHE


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


def enrich_events_with_colors(
    access_token: str,
    calendar_id: str,
    events: list[dict[str, Any]],
) -> dict[str, str | None]:
    """Attach resolved hex colors to each event.

    An event shows its own color when it has one (`colorId`), otherwise the
    owning calendar's color — mirroring Google Calendar. Returns the
    calendar's own colors for clients to use as a fallback.
    """
    palettes = get_color_palettes(access_token)
    event_palette = palettes.get("event") if isinstance(palettes, dict) else None
    if not isinstance(event_palette, dict):
        event_palette = {}

    calendar_colors: dict[str, str | None] = {
        "backgroundColor": None,
        "foregroundColor": None,
    }
    try:
        entry = _calendar_request(
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
    """Flatten one Google event resource into the app's normalized format."""
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


def list_events(
    access_token: str,
    calendar_id: str,
    time_min: str | None = None,
    time_max: str | None = None,
) -> list[dict[str, Any]]:
    """Expanded (singleEvents) events in a normalized flat format."""
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
        data = _calendar_request(
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
    """Build a Google event resource from the app's normalized fields.

    Timed events pass the ISO strings through (offsets preserved);
    all-day events use plain dates (Google treats the end date as
    exclusive, matching the app's start + N days convention).
    """
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


def create_event(
    access_token: str,
    calendar_id: str,
    body: dict[str, Any],
) -> dict[str, Any] | None:
    item = _calendar_write_request(
        access_token, "POST", _event_path(calendar_id), body
    )
    return normalize_event(item)


def update_event(
    access_token: str,
    calendar_id: str,
    event_id: str,
    body: dict[str, Any],
) -> dict[str, Any] | None:
    item = _calendar_write_request(
        access_token, "PATCH", _event_path(calendar_id, event_id), body
    )
    return normalize_event(item)


def delete_event(
    access_token: str,
    calendar_id: str,
    event_id: str,
) -> None:
    _calendar_write_request(
        access_token, "DELETE", _event_path(calendar_id, event_id)
    )


def get_event(
    access_token: str,
    calendar_id: str,
    event_id: str,
) -> dict[str, Any] | None:
    """Fetch one event resource (e.g. a series master) in normalized form."""
    data = _calendar_request(
        access_token, _event_path(calendar_id, event_id), {}
    )
    if not isinstance(data, dict):
        return None
    return normalize_event(data)
