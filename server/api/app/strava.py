"""Strava API logic for the fitness integration.

Strava is the self-serve way to read watch-recorded workouts: Garmin
auto-pushes activities to Strava, and any Strava user can register an
API application at https://www.strava.com/settings/api for free. All
functions here take explicit credentials/tokens — per-user token
storage lives in oauth_store.py (DB, Fernet-encrypted).
"""

from __future__ import annotations

import datetime as dt
import os
import urllib.parse
from typing import Any

import httpx

STRAVA_AUTH_ENDPOINT = "https://www.strava.com/oauth/authorize"
STRAVA_TOKEN_ENDPOINT = "https://www.strava.com/oauth/token"
STRAVA_DEAUTHORIZE_ENDPOINT = "https://www.strava.com/oauth/deauthorize"
STRAVA_API = "https://www.strava.com/api/v3"

# read = athlete profile; activity:read_all = private activities too.
# Strava has no sleep API — sleep goals stay unsupported.
STRAVA_SCOPE = "read,activity:read_all"

# One page is 200 activities (Strava's max). Cap the fan-out so a huge
# history can't pin a request open: 10 pages = 2000 activities, plenty
# for the app's rolling window.
MAX_PAGES = 10


class StravaAuthError(Exception):
    def __init__(self, message: str, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


def strava_credentials() -> tuple[str, str]:
    client_id = os.getenv("STRAVA_CLIENT_ID", "").strip()
    client_secret = os.getenv("STRAVA_CLIENT_SECRET", "").strip()
    if not client_id or not client_secret:
        raise StravaAuthError(
            "Server is missing STRAVA_CLIENT_ID / STRAVA_CLIENT_SECRET"
        )
    return client_id, client_secret


def strava_configured() -> bool:
    try:
        strava_credentials()
    except StravaAuthError:
        return False
    return True


def default_redirect_uri(base_url: str) -> str:
    """Callback URL to register on the Strava app.

    STRAVA_REDIRECT_URI wins so a reverse-proxied deployment (Tailscale
    serve strips a path prefix and terminates TLS) can advertise its
    public HTTPS callback instead of the server's loopback address.
    """
    pinned = os.getenv("STRAVA_REDIRECT_URI", "").strip()
    if pinned:
        return pinned
    return base_url.rstrip("/") + "/api/fitness/callback"


def _validate_redirect_uri(uri: str) -> str:
    parsed = urllib.parse.urlparse(uri)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        raise StravaAuthError("Invalid STRAVA_REDIRECT_URI")
    return uri


def strava_auth_url(redirect_uri: str, state: str) -> str:
    client_id, _ = strava_credentials()
    params = {
        "client_id": client_id,
        "redirect_uri": _validate_redirect_uri(redirect_uri),
        "response_type": "code",
        "approval_prompt": "auto",
        "scope": STRAVA_SCOPE,
        "state": state,
    }
    return f"{STRAVA_AUTH_ENDPOINT}?{urllib.parse.urlencode(params)}"


async def redeem_code(code: str, redirect_uri: str) -> dict[str, Any]:
    """Exchange an authorization code for tokens (caller stores them)."""
    client_id, client_secret = strava_credentials()
    async with httpx.AsyncClient(timeout=30) as c:
        resp = await c.post(
            STRAVA_TOKEN_ENDPOINT,
            data={
                "client_id": client_id,
                "client_secret": client_secret,
                "code": code,
                "grant_type": "authorization_code",
                "redirect_uri": _validate_redirect_uri(redirect_uri),
            },
        )
    if resp.status_code >= 400:
        raise StravaAuthError(
            f"Strava token exchange failed ({resp.status_code})",
            status=resp.status_code,
        )
    data = resp.json()
    if not data.get("access_token"):
        raise StravaAuthError("Strava did not return an access token")
    return data


async def refresh_access_token(refresh_token: str) -> dict[str, Any]:
    client_id, client_secret = strava_credentials()
    async with httpx.AsyncClient(timeout=30) as c:
        resp = await c.post(
            STRAVA_TOKEN_ENDPOINT,
            data={
                "client_id": client_id,
                "client_secret": client_secret,
                "grant_type": "refresh_token",
                "refresh_token": refresh_token,
            },
        )
    if resp.status_code >= 400:
        raise StravaAuthError(
            f"Strava token refresh failed ({resp.status_code})",
            status=resp.status_code,
        )
    data = resp.json()
    if not data.get("access_token"):
        raise StravaAuthError("Strava did not return a refreshed token")
    return data


async def deauthorize(access_token: str) -> None:
    """Best-effort revoke on disconnect; local storage is cleared anyway."""
    if not access_token:
        return
    try:
        async with httpx.AsyncClient(timeout=15) as c:
            await c.post(
                STRAVA_DEAUTHORIZE_ENDPOINT,
                data={"access_token": access_token},
            )
    except httpx.HTTPError:
        pass


def _normalize_type(sport: str) -> str:
    key = sport.strip().lower().replace(" ", "")
    aliases = {
        "virtualrun": "run",
        "trailrun": "run",
        "virtualride": "ride",
        "ebikeride": "ride",
        "gravelride": "ride",
        "mountainbikeride": "ride",
        "weighttraining": "strength",
    }
    return aliases.get(key, key or "workout")


def _parse_start(value: object) -> dt.datetime | None:
    """Strava v3 sends arrival-date ISO strings; accept epoch too."""
    if isinstance(value, str) and value.strip():
        try:
            parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed.astimezone(dt.timezone.utc)
    try:
        return dt.datetime.fromtimestamp(float(value), dt.timezone.utc)
    except (TypeError, ValueError, OSError):
        return None


def _activity(raw: dict[str, Any]) -> dict[str, Any] | None:
    """Map one Strava summary activity to the app's FitnessActivity shape."""
    start = _parse_start(raw.get("start_date"))
    if start is None:
        return None
    seconds = raw.get("moving_time") or raw.get("elapsed_time") or 0
    try:
        seconds = int(seconds)
    except (TypeError, ValueError):
        seconds = 0
    if seconds <= 0:
        return None
    end = start + dt.timedelta(seconds=seconds)
    sport = str(raw.get("sport_type") or raw.get("type") or "workout")
    return {
        "id": f"strava:{raw.get('id')}",
        "type": _normalize_type(sport),
        "name": str(raw.get("name") or ""),
        "start": start.isoformat(),
        "end": end.isoformat(),
        "minutes": seconds / 60.0,
        "distanceMeters": float(raw.get("distance") or 0),
        "provider": "strava",
    }


async def list_activities(
    access_token: str,
    after: dt.datetime,
    before: dt.datetime,
) -> list[dict[str, Any]]:
    """Every activity in the window, oldest to newest, paged.

    Raises [StravaAuthError] on 401/403 so callers can prompt a reconnect
    and httpx.HTTPError for transport problems.
    """
    out: list[dict[str, Any]] = []
    async with httpx.AsyncClient(timeout=30) as c:
        for page in range(1, MAX_PAGES + 1):
            resp = await c.get(
                f"{STRAVA_API}/athlete/activities",
                params={
                    "after": int(after.timestamp()),
                    "before": int(before.timestamp()),
                    "per_page": 200,
                    "page": page,
                },
                headers={"Authorization": f"Bearer {access_token}"},
            )
            if resp.status_code in (401, 403):
                raise StravaAuthError(
                    "Strava connection needs renewal", status=resp.status_code
                )
            if resp.status_code >= 400:
                raise StravaAuthError(
                    f"Strava activities failed ({resp.status_code})",
                    status=resp.status_code,
                )
            batch = resp.json()
            if not isinstance(batch, list) or not batch:
                break
            for raw in batch:
                if not isinstance(raw, dict):
                    continue
                mapped = _activity(raw)
                if mapped is not None:
                    out.append(mapped)
            if len(batch) < 200:
                break
    out.sort(key=lambda item: item["start"])
    return out
