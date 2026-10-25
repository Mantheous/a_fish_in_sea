"""Syllabus extraction route (same contract as the retired Flask server)."""

from __future__ import annotations

import datetime as dt

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse

from .. import llm
from ..ratelimit import limit

router = APIRouter(tags=["syllabus"])

_MAX_SYLLABUS_BODY_BYTES = 128 * 1024


def _normalize_drafts(raw: list) -> list[dict]:
    drafts: list[dict] = []
    for item in raw[:100]:
        if not isinstance(item, dict):
            continue
        title = item.get("title") or ""
        title = title.strip() if isinstance(title, str) else ""
        if not title:
            continue
        due = item.get("due")
        if isinstance(due, str) and due.strip():
            try:
                due = dt.date.fromisoformat(due.strip()[:10]).isoformat()
            except ValueError:
                due = None
        else:
            due = None
        notes = item.get("notes")
        notes = (
            notes.strip()
            if isinstance(notes, str) and notes.strip()
            else None
        )
        drafts.append({"title": title[:140], "due": due, "notes": notes})
    return drafts


@router.post("/syllabus/extract")
async def syllabus_extract(
    request: Request,
    body: dict,
    _rl: None = Depends(limit("syllabus:extract", 15, 60)),
):
    raw_len = len(await request.body())
    if raw_len > _MAX_SYLLABUS_BODY_BYTES:
        return JSONResponse(
            status_code=413, content={"error": "Syllabus payload too large"}
        )
    text = body.get("text") if isinstance(body, dict) else ""
    text = text.strip() if isinstance(text, str) else ""
    if not text:
        return JSONResponse(status_code=400, content={"error": "Missing text"})
    text = text[:15000]
    base = llm.ollama_base()
    model = llm.syllabus_model()
    # "Today" must be the user's local day, not the server's: an LLM is
    # being asked to resolve relative dates ("next Friday") from it, and
    # the server usually runs in UTC while the user can be a day ahead or
    # behind. The client sends its local date; validate and fall back.
    today = dt.date.today()
    raw_today = body.get("today")
    if isinstance(raw_today, str):
        try:
            today = dt.date.fromisoformat(raw_today.strip()[:10])
        except ValueError:
            pass
    content, err = await llm.call_ollama_chat(
        base,
        model,
        llm.SYSTEM_PROMPT,
        f"Today is {today.isoformat()}.\n\nSyllabus text:\n{text}",
    )
    if err is not None:
        return JSONResponse(status_code=502, content={"error": err})
    try:
        raw = llm.extract_json_array(content or "")
    except ValueError:
        return JSONResponse(
            status_code=502, content={"error": "Model did not return JSON"}
        )
    return {"drafts": _normalize_drafts(raw), "model": model}
