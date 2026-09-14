"""Syllabus extraction route (LLM layer faked; contract + normalization)."""

from __future__ import annotations

import os
import tempfile

import pytest
from fastapi.testclient import TestClient

os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{tempfile.mkdtemp()}/test_syl.db"
os.environ["JWT_SECRET"] = "test-secret"

from app import llm  # noqa: E402
from app.main import create_app  # noqa: E402
from app.routers import syllabus as syllabus_router  # noqa: E402

app = create_app()


@pytest.fixture()
def client():
    with TestClient(app) as c:
        yield c


def test_missing_text_is_400(client: TestClient):
    assert client.post("/api/syllabus/extract", json={}).status_code == 400
    assert client.post("/api/syllabus/extract", json={"text": "  "}).status_code == 400


def test_extract_json_array_shapes():
    assert llm.extract_json_array('[{"title": "A"}]') == [{"title": "A"}]
    # Code fences + surrounding prose are tolerated.
    out = llm.extract_json_array(
        'Here you go:\n```json\n[{"title": "HW1", "due": "2026-01-05"}]\n```\ndone'
    )
    assert out == [{"title": "HW1", "due": "2026-01-05"}]
    # Non-list JSON degrades to no drafts (same as the old server).
    assert llm.extract_json_array('{"title": "oops"}') == []
    # Malformed JSON raises (route maps to 502).
    with pytest.raises(ValueError):
        llm.extract_json_array("sorry, no json here {{{")


def test_normalize_drafts():
    raw = [
        {"title": "  HW 1  ", "due": "2026-03-04", "notes": " ch 2 "},
        {"title": "Quiz", "due": "not-a-date", "notes": ""},
        {"title": "   ", "due": None},
        "junk",
        {"title": "No due", "due": None, "notes": None},
    ]
    drafts = syllabus_router._normalize_drafts(raw)
    assert drafts == [
        {"title": "HW 1", "due": "2026-03-04", "notes": "ch 2"},
        {"title": "Quiz", "due": None, "notes": None},
        {"title": "No due", "due": None, "notes": None},
    ]


def test_extract_roundtrip_with_faked_llm(client: TestClient, monkeypatch):
    async def fake_chat(base, model, system, user):
        assert "Today is" in user
        return (
            '[{"title": "Midterm", "due": "2026-10-01", "notes": null}]',
            None,
        )

    monkeypatch.setattr(llm, "call_ollama_chat", fake_chat)
    r = client.post("/api/syllabus/extract", json={"text": "midterm oct 1"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["drafts"] == [
        {"title": "Midterm", "due": "2026-10-01", "notes": None}
    ]
    assert body["model"]


def test_llm_failure_is_502(client: TestClient, monkeypatch):
    async def fake_chat(base, model, system, user):
        return None, "Ollama unreachable: boom"

    monkeypatch.setattr(llm, "call_ollama_chat", fake_chat)
    r = client.post("/api/syllabus/extract", json={"text": "hello"})
    assert r.status_code == 502
    assert "boom" in r.json()["error"]


def test_non_json_model_output_is_502(client: TestClient, monkeypatch):
    async def fake_chat(base, model, system, user):
        return ("sorry, no json here", None)

    monkeypatch.setattr(llm, "call_ollama_chat", fake_chat)
    r = client.post("/api/syllabus/extract", json={"text": "hello"})
    assert r.status_code == 502
