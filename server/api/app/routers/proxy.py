"""First ported proxy: iCal fetch (same contract as Flask /api/ical).

Validates http(s) scheme, blocks internal hosts (SSRF guard in
app.ssrf), fetches server-side (fixes web CORS), returns
text/calendar capped at 5MB.

CGNAT/Tailnet targets (100.64.0.0/10) are allowed by the SSRF guard so
self-hosted Tailnet feeds keep working, but /api/ical requires a signed-in
user before fetching one — unauthenticated callers cannot use the public
funnel to probe private Tailnet services (AnkiConnect :8765, Ollama :11434,
etc.). Public feeds on public IPs stay unauthenticated.
"""

from __future__ import annotations

import asyncio
import ipaddress
import socket
import urllib.parse

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from sqlalchemy.ext.asyncio import AsyncSession

from ..deps import get_current_user, get_session
from ..ratelimit import limit
from ..ssrf import fetch_public_bytes, is_cgnat_ip

router = APIRouter(tags=["proxy"])


async def _require_auth_for_tailnet(
    request: Request,
    session: AsyncSession = Depends(get_session),
) -> None:
    """Require a bearer token when the iCal target resolves to CGNAT (100.64/10).

    Public feeds on public IPs stay unauthenticated. Tailnet targets are
    reachable private-ish space, so fetching them anonymously would let
    anyone probe private Tailnet services through this funnel. Unresolvable
    hosts fall through: the SSRF guard raises its own 400 later.
    """
    url = request.query_params.get("url")
    if not url:
        return
    try:
        parsed = urllib.parse.urlparse(url)
        host = parsed.hostname
        if not host:
            return
        infos = await asyncio.to_thread(
            socket.getaddrinfo, host, parsed.port or 0
        )
    except (OSError, ValueError):
        return
    for _, _, _, _, sockaddr in infos:
        try:
            ip = ipaddress.ip_address(sockaddr[0])
        except ValueError:
            continue
        if is_cgnat_ip(ip):
            await get_current_user(
                authorization=request.headers.get("authorization"),
                session=session,
            )
            return


@router.get("/ical")
async def ical(
    request: Request,
    url: str = Query(min_length=8, max_length=2048),
    _rl: None = Depends(limit("proxy:ical", 120, 60)),
    _auth: None = Depends(_require_auth_for_tailnet),
):
    try:
        body, _etag = await fetch_public_bytes(url)
    except ValueError as e:
        msg = str(e)
        # Policy rejections and upstream failures share the fetch-failed
        # shape the Flutter client already handles; unresolvable or
        # internal hosts are a bad request.
        if "Feed returned" in msg or "failed" in msg.lower():
            raise HTTPException(status_code=502, detail=f"Feed fetch failed: {e}")
        raise HTTPException(status_code=400, detail=msg)
    except httpx.HTTPError as e:
        raise HTTPException(status_code=502, detail=f"Feed fetch failed: {e}")
    return Response(content=body, media_type="text/calendar")
