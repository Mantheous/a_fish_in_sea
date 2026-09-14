"""First ported proxy: iCal fetch (same contract as Flask /api/ical).

Validates http(s) scheme, blocks internal hosts (SSRF guard in
app.ssrf), fetches server-side (fixes web CORS), returns
text/calendar capped at 5MB.
"""

from __future__ import annotations

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query, Response

from ..ratelimit import limit
from ..ssrf import fetch_public_bytes

router = APIRouter(tags=["proxy"])


@router.get("/ical")
async def ical(
    url: str = Query(min_length=8, max_length=2048),
    _rl: None = Depends(limit("proxy:ical", 120, 60)),
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
