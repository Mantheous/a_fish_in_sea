"""Syllabus extraction route (same contract as the retired Flask server)."""

from __future__ import annotations

import datetime as dt

from fastapi import APIRouter
from fastapi.responses import JSONResponse

from .. import llm

router = APIRouter(tags=["syllabus"])


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
async def syllabus_extract(body: dict):
    text = body.get("text") or ""
    text = text.strip() if isinstance(text, str) else ""
    if not text:
        return JSONResponse(status_code=400, content={"error": "Missing text"})
    text = text[:15000]
    base = llm.ollama_base()
    model = llm.syllabus_model()
    today = dt.date.today().isoformat()
    content, err = await llm.call_ollama_chat(
        base,
        model,
        llm.SYSTEM_PROMPT,
        f"Today is {today}.\n\nSyllabus text:\n{text}",
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
