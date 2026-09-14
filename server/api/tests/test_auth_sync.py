"""Auth isolation + full push/pull round-trip + tombstones + MCP tokens."""

from __future__ import annotations

import os
import tempfile

import pytest
from fastapi.testclient import TestClient

os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{tempfile.mkdtemp()}/test.db"
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
    return r.json()


def _auth(email: str, tokens: dict) -> dict:
    return {"Authorization": f"Bearer {tokens['access_token']}"}


def test_register_login_me(client: TestClient):
    tokens = _register(client, "a@example.com")
    me = client.get("/api/v1/auth/me", headers=_auth("a@example.com", tokens))
    assert me.status_code == 200
    assert me.json()["email"] == "a@example.com"

    login = client.post(
        "/api/v1/auth/login",
        json={"email": "a@example.com", "password": "password123"},
    )
    assert login.status_code == 200

    bad = client.post(
        "/api/v1/auth/login",
        json={"email": "a@example.com", "password": "wrongpass1"},
    )
    assert bad.status_code == 401


def test_users_are_isolated(client: TestClient):
    alice = _register(client, "alice@example.com")
    bob = _register(client, "bob@example.com")

    push = client.post(
        "/api/v1/sync/push",
        headers=_auth("alice@example.com", alice),
        json={
            "changes": [
                {
                    "collection": "tasks",
                    "item_id": "t1",
                    "data": {"id": "t1", "title": "Alice task"},
                }
            ]
        },
    )
    assert push.status_code == 200, push.text

    pull_bob = client.get(
        "/api/v1/sync/pull", headers=_auth("bob@example.com", bob)
    )
    assert pull_bob.status_code == 200
    assert pull_bob.json()["changes"] == []


def test_push_pull_roundtrip_all_collections(client: TestClient):
    tokens = _register(client, "all@example.com")
    h = _auth("all@example.com", tokens)
    changes = [
        {
            "collection": "tasks",
            "item_id": "t1",
            "data": {"id": "t1", "title": "Buy milk", "done": False},
        },
        {
            "collection": "events",
            "item_id": "e1",
            "data": {
                "id": "e1",
                "subject": "Standup",
                "start": "2026-09-14T09:00:00Z",
                "end": "2026-09-14T09:30:00Z",
            },
        },
        {
            "collection": "settings",
            "item_id": "singleton",
            "data": {"snapMinutes": 15},
        },
    ]
    push = client.post("/api/v1/sync/push", headers=h, json={"changes": changes})
    assert push.status_code == 200, push.text
    assert len(push.json()["applied"]) == 3

    pull = client.get("/api/v1/sync/pull", headers=h)
    assert pull.status_code == 200
    got = {(c["collection"], c["item_id"]) for c in pull.json()["changes"]}
    assert ("tasks", "t1") in got
    assert ("events", "e1") in got
    assert ("settings", "singleton") in got

    # incremental pull with server_time returns nothing new
    server_time = pull.json()["server_time"]
    again = client.get("/api/v1/sync/pull", headers=h, params={"since": server_time})
    assert again.status_code == 200
    assert again.json()["changes"] == []


def test_tombstone_propagates_delete(client: TestClient):
    tokens = _register(client, "del@example.com")
    h = _auth("del@example.com", tokens)
    client.post(
        "/api/v1/sync/push",
        headers=h,
        json={
            "changes": [
                {
                    "collection": "tasks",
                    "item_id": "t9",
                    "data": {"id": "t9", "title": "x"},
                }
            ]
        },
    )
    client.post(
        "/api/v1/sync/push",
        headers=h,
        json={
            "changes": [
                {
                    "collection": "tasks",
                    "item_id": "t9",
                    "data": {"id": "t9", "title": "x"},
                    "deleted": True,
                }
            ]
        },
    )
    pull = client.get(
        "/api/v1/sync/pull", headers=h, params={"collections": "tasks"}
    )
    tomb = [c for c in pull.json()["changes"] if c["item_id"] == "t9"][-1]
    assert tomb["deleted"] is True


def test_items_crud_and_mcp_token(client: TestClient):
    tokens = _register(client, "mcp@example.com")
    h = _auth("mcp@example.com", tokens)

    created = client.post(
        "/api/v1/tokens", headers=h, json={"name": "agent", "scopes": ["sync"]}
    )
    assert created.status_code == 201, created.text
    agent_key = created.json()["token"]
    ah = {"Authorization": f"Bearer {agent_key}"}

    put = client.put(
        "/api/v1/items/tasks/agent-task-1",
        headers=ah,
        json={"data": {"title": "From agent"}},
    )
    assert put.status_code == 200, put.text
    assert put.json()["data"]["id"] == "agent-task-1"

    listed = client.get("/api/v1/items/tasks", headers=ah)
    assert listed.status_code == 200
    assert any(r["item_id"] == "agent-task-1" for r in listed.json())

    # JWT user sees the same row via pull (shared envelope)
    pull = client.get("/api/v1/sync/pull", headers=h)
    assert any(c["item_id"] == "agent-task-1" for c in pull.json()["changes"])
