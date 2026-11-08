"""Content-free usage ingest: auth, validation, dedupe."""

from __future__ import annotations

import os
import tempfile
import time

import pytest
from fastapi.testclient import TestClient

os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{tempfile.mkdtemp()}/test_usage.db"
os.environ["JWT_SECRET"] = "test-secret"

from app.main import create_app  # noqa: E402

app = create_app()


@pytest.fixture()
def client():
    with TestClient(app) as c:
        yield c


def _register(client: TestClient, email: str) -> dict:
    r = client.post(
        "/api/v1/auth/register", json={"email": email, "password": "password123"}
    )
    assert r.status_code == 201, r.text
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


def _event(**kw) -> dict:
    base = {
        "id": f"evt-{time.time_ns()}",
        "at": int(time.time() * 1000),
        "kind": "action",
        "name": "calendar.view.set",
        "screen": "calendar",
        "duration_ms": 1200,
        "meta": {"view": "week"},
    }
    base.update(kw)
    return base


def test_usage_requires_auth(client: TestClient):
    r = client.post("/api/v1/usage/events", json={"events": [_event()]})
    assert r.status_code == 401


def test_usage_accepts_and_dedupes(client: TestClient):
    auth = _register(client, "usage@example.com")
    event = _event()
    body = {"events": [event], "platform": "web", "session_id": "s123456"}
    first = client.post("/api/v1/usage/events", headers=auth, json=body)
    assert first.status_code == 200, first.text
    assert first.json()["accepted"] == 1

    # A retried batch after a lost response must not duplicate the row.
    second = client.post("/api/v1/usage/events", headers=auth, json=body)
    assert second.status_code == 200, second.text
    assert second.json()["accepted"] == 0


def test_usage_rejects_free_text_and_unknown_kinds(client: TestClient):
    auth = _register(client, "usage-bad@example.com")

    bad_kind = client.post(
        "/api/v1/usage/events",
        headers=auth,
        json={"events": [_event(kind="keystroke")]},
    )
    assert bad_kind.status_code == 422

    free_text = client.post(
        "/api/v1/usage/events",
        headers=auth,
        json={"events": [_event(meta={"title": "Quiz 4 study notes"})]},
    )
    assert free_text.status_code == 422

    bad_name = client.post(
        "/api/v1/usage/events",
        headers=auth,
        json={"events": [_event(name="Quiz 4")]},
    )
    assert bad_name.status_code == 422

    too_many_events = client.post(
        "/api/v1/usage/events",
        headers=auth,
        json={"events": [_event() for _ in range(501)]},
    )
    assert too_many_events.status_code == 422


def test_usage_accepts_empty_screen_and_no_meta(client: TestClient):
    auth = _register(client, "usage-min@example.com")
    event = _event(kind="app", name="start", screen="", meta={})
    event.pop("duration_ms")
    r = client.post("/api/v1/usage/events", headers=auth, json={"events": [event]})
    assert r.status_code == 200, r.text
    assert r.json()["accepted"] == 1
