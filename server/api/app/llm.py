"""Syllabus → task-draft extraction via a local LLM (ported from Flask).

The Flutter app POSTs syllabus text here; this proxy calls Ollama over
localhost (``OLLAMA_BASE_URL``, default ``http://127.0.0.1:11434``) so
Ollama itself is never exposed to the network. Syllabus bodies are never
logged. Like ``/api/ical``, the route is unauthenticated (any failure on
the client falls back to local parsing).
"""

from __future__ import annotations

import json
import os
import re

import httpx

SYSTEM_PROMPT = (
    "You extract assignments from a class syllabus. "
    "Return ONLY a JSON array, no prose, no code fences. "
    'Each item: {"title": str, "due": "YYYY-MM-DD" or null, "notes": str or null}. '
    "Include homework, quizzes, exams, projects, papers, labs, readings with "
    "explicit deliverables. Skip lecture topics, office hours, grading policy, "
    "and contact info. Resolve relative dates against the \"Today is\" date; "
    "use null when no date can be grounded. Keep titles short."
)


def ollama_base() -> str:
    return os.getenv("OLLAMA_BASE_URL", "http://127.0.0.1:11434").rstrip("/")


def syllabus_model() -> str:
    return os.getenv("SYLLABUS_MODEL", "qwen2.5:3b")


def extract_json_array(text: str) -> list:
    """Pull the first top-level JSON array out of model output (or raise)."""
    candidate = text.strip()
    fence = re.search(r"```(?:json)?\s*(.*?)```", candidate, re.DOTALL)
    if fence:
        candidate = fence.group(1).strip()
    start = candidate.find("[")
    end = candidate.rfind("]")
    if start != -1 and end != -1 and end > start:
        candidate = candidate[start : end + 1]
    parsed = json.loads(candidate)
    return parsed if isinstance(parsed, list) else []


async def call_ollama_chat(
    base: str, model: str, system: str, user: str
) -> tuple[str | None, str | None]:
    """Return (content, None) on success or (None, error) on failure."""
    payload = {
        "model": model,
        "stream": False,
        "format": "json",
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    }
    try:
        async with httpx.AsyncClient(timeout=90) as c:
            resp = await c.post(f"{base}/api/chat", json=payload)
    except httpx.HTTPError as e:
        return None, f"Ollama unreachable: {e}"
    if resp.status_code == 404:
        # llama.cpp OpenAI-compat server instead of Ollama.
        try:
            async with httpx.AsyncClient(timeout=90) as c:
                oai = await c.post(
                    f"{base}/v1/chat/completions",
                    json={
                        "model": model,
                        "messages": [
                            {"role": "system", "content": system},
                            {"role": "user", "content": user},
                        ],
                        "response_format": {"type": "json_object"},
                    },
                )
        except httpx.HTTPError as e:
            return None, f"LLM unreachable: {e}"
        if oai.status_code != 200:
            return None, f"LLM returned {oai.status_code}"
        try:
            content = (oai.json().get("choices") or [{}])[0].get(
                "message", {}
            ).get("content", "")
        except (ValueError, AttributeError):
            return None, "Bad LLM response"
        return content, None
    if resp.status_code != 200:
        return None, f"Ollama returned {resp.status_code}"
    try:
        content = resp.json().get("message", {}).get("content", "")
    except (ValueError, AttributeError):
        return None, "Bad Ollama response"
    return content, None
