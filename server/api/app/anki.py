"""AnkiConnect proxy backend (personal Anki on the Tailnet).

The Flutter app's memorization goals read review counts from AnkiConnect
(`deckNames` + `findCards`). Browsers cannot reach AnkiConnect directly
(mixed content + no CORS headers), so the web build goes through this
proxy; native builds may use it too instead of a per-device LAN address.

Unlike /api/ical, the upstream here is server-configured
(``ANKI_CONNECT_URL``), never user-supplied, so there is no SSRF surface:
the client only picks an allowlisted action plus tightly validated params.
The route requires auth because deck names and review counts are personal
data. Anki-side failures surface as 502s with the upstream message
preserved so the app can display it.
"""

from __future__ import annotations

import os

import httpx


class AnkiUpstreamError(Exception):
    """AnkiConnect did not answer usefully (down, wrong service, or error)."""


def anki_base() -> str:
    """Fixed AnkiConnect endpoint (may include a subpath such as /api)."""
    return os.getenv("ANKI_CONNECT_URL", "http://127.0.0.1:8765").rstrip("/")


def anki_api_key() -> str:
    """Optional AnkiConnect apiKey (empty = none configured server-side)."""
    return os.getenv("ANKI_CONNECT_API_KEY", "").strip()


def _display_base() -> str:
    """Scheme + host + port only: ANKI_CONNECT_URL is operator config and
    must never be echoed back to clients (it could carry credentials)."""
    from urllib.parse import urlsplit

    try:
        parts = urlsplit(anki_base())
        host = parts.hostname or "anki"
        port = f":{parts.port}" if parts.port else ""
        return f"{parts.scheme or 'http'}://{host}{port}"
    except ValueError:
        return "the Anki server"


async def invoke(action: str, params: dict) -> object:
    """Forward one AnkiConnect call; return the `result` field.

    Raises [AnkiUpstreamError] with a displayable message on transport
    failure, non-200 status, non-JSON body, or AnkiConnect `error`.
    """
    envelope: dict = {"action": action, "version": 6, "params": params}
    key = anki_api_key()
    if key:
        envelope["apiKey"] = key
    try:
        async with httpx.AsyncClient(timeout=15) as c:
            resp = await c.post(anki_base(), json=envelope)
    except httpx.HTTPError as e:
        raise AnkiUpstreamError(f"Anki is unreachable: {e}") from e
    if resp.status_code != 200:
        raise AnkiUpstreamError(
            f"Anki answered HTTP {resp.status_code} — is {_display_base()} "
            "really AnkiConnect?"
        )
    try:
        body = resp.json()
    except ValueError:
        raise AnkiUpstreamError(
            f"Anki answered with something that is not JSON — is {_display_base()} "
            "really AnkiConnect?"
        ) from None
    if not isinstance(body, dict):
        raise AnkiUpstreamError("Anki answered in an unknown shape.")
    if body.get("error"):
        raise AnkiUpstreamError(f"Anki says: {body['error']}")
    return body.get("result")
