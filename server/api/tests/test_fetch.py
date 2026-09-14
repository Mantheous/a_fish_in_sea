"""waterfall/plaid singleton collections + server-side feed snapshots."""

from __future__ import annotations

import datetime as dt
import os
import tempfile

import pytest
from fastapi.testclient import TestClient

os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{tempfile.mkdtemp()}/test_fetch.db"
os.environ["JWT_SECRET"] = "test-secret"

from app.main import create_app  # noqa: E402
from app.routers import fetch as fetch_router  # noqa: E402

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


def test_waterfall_and_plaid_singletons(client: TestClient):
    h = _register(client, "cfg@example.com")
    push = client.post(
        "/api/v1/sync/push",
        headers=h,
        json={
            "changes": [
                {
                    "collection": "waterfall",
                    "item_id": "singleton",
                    "data": {"startingBalance": 123.45},
                },
                {
                    "collection": "plaid",
                    "item_id": "singleton",
                    "data": {"userId": "u1", "wasConnected": True},
                },
            ]
        },
    )
    assert push.status_code == 200, push.text
    pull = client.get(
        "/api/v1/sync/pull",
        headers=h,
        params={"collections": "waterfall,plaid"},
    )
    assert pull.status_code == 200
    got = {c["collection"]: c["data"] for c in pull.json()["changes"]}
    assert got["waterfall"]["startingBalance"] == 123.45
    assert got["plaid"]["userId"] == "u1"


async def _fake_fetch(url: str) -> tuple[bytes, str]:
    assert url.startswith("https://")
    return b"BEGIN:VCALENDAR\r\nEND:VCALENDAR", 'W/"1"'


async def _failing_fetch(url: str) -> tuple[bytes, str]:
    raise ConnectionError("boom")


def test_refresh_and_snapshot_roundtrip(client: TestClient, monkeypatch):
    monkeypatch.setattr(fetch_router, "fetch_url", _fake_fetch)
    h = _register(client, "feed@example.com")
    # Feed config arrives via normal sync; server reads the URL from it.
    client.post(
        "/api/v1/sync/push",
        headers=h,
        json={
            "changes": [
                {
                    "collection": "feeds",
                    "item_id": "f1",
                    "data": {
                        "id": "f1",
                        "name": "Canvas",
                        "url": "https://example.com/feed.ics",
                        "kind": "canvas",
                        "enabled": True,
                    },
                },
                {
                    "collection": "feeds",
                    "item_id": "g1",
                    "data": {"id": "g1", "kind": "google", "enabled": True},
                },
            ]
        },
    )
    due = client.post("/api/v1/fetch/refresh-due", headers=h)
    assert due.status_code == 200, due.text
    # Google feeds are skipped (OAuth stays client-side until Google port).
    assert [r["feed_id"] for r in due.json()["results"]] == ["f1"]

    snap = client.get("/api/v1/fetch/snapshot", headers=h, params={"feed_id": "f1"})
    assert snap.status_code == 200
    assert "VCALENDAR" in snap.json()["ics"]

    missing = client.get(
        "/api/v1/fetch/snapshot", headers=h, params={"feed_id": "nope"}
    )
    assert missing.status_code == 404


def test_refresh_error_stored_not_raised(client: TestClient, monkeypatch):
    monkeypatch.setattr(fetch_router, "fetch_url", _failing_fetch)
    h = _register(client, "badfeed@example.com")
    r = client.post(
        "/api/v1/fetch/refresh",
        headers=h,
        json={"feed_id": "bad", "url": "https://example.com/x.ics"},
    )
    assert r.status_code == 200
    assert r.json()["status"] == "error"
    assert "boom" in r.json()["error"]
    # Non-http(s) urls are rejected, never fetched.
    bad = client.post(
        "/api/v1/fetch/refresh",
        headers=h,
        json={"feed_id": "bad2", "url": "file:///etc/passwd"},
    )
    assert bad.status_code == 400
