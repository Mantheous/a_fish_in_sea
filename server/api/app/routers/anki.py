"""Authenticated AnkiConnect proxy for memorization goals.

Same-origin access for the web build (which cannot reach AnkiConnect
directly) plus a stable address for native builds. Only the actions the
app needs are allowlisted; params are re-built server-side so callers
cannot smuggle arbitrary AnkiConnect calls through.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from .. import anki as a
from ..deps import require_scope
from ..models import User
from ..ratelimit import limit

router = APIRouter(prefix="/anki", tags=["anki"])

_ALLOWED = ("deckNames", "findCards", "sync")
_MAX_QUERY = 500


class InvokeIn(BaseModel):
    action: str = ""
    params: dict = {}


@router.post("/invoke")
async def invoke(
    body: InvokeIn,
    user: User = Depends(require_scope("sync")),
    _rl: None = Depends(limit("anki:invoke", 60, 60, by_user=True)),
):
    action = (body.action or "").strip()
    if action not in _ALLOWED:
        raise HTTPException(status_code=400, detail="Unknown Anki action")
    params: dict = {}
    if action in ("deckNames", "sync"):
        if body.params:
            raise HTTPException(
                status_code=400, detail=f"{action} takes no params"
            )
    elif action == "findCards":
        query = (body.params or {}).get("query")
        if not isinstance(query, str) or not query.strip():
            raise HTTPException(
                status_code=400, detail="findCards needs a query string"
            )
        query = query.strip()
        if len(query) > _MAX_QUERY:
            raise HTTPException(status_code=400, detail="Query too long")
        params = {"query": query}
    try:
        result = await a.invoke(action, params)
    except a.AnkiUpstreamError as e:
        raise HTTPException(status_code=502, detail=str(e))
    return {"result": result}
