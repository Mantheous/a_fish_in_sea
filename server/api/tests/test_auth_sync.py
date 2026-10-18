"""Auth isolation + full push/pull round-trip + tombstones + MCP tokens."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import datetime as dt
import os
import tempfile
import threading
import time

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


def test_pull_keyset_cursor_preserves_same_timestamp_rows_over_many_pages(
    client: TestClient, monkeypatch
):
    from app.routers import sync as sync_router

    tokens = _register(client, "pagination@example.com")
    h = _auth("pagination@example.com", tokens)
    fixed = dt.datetime.fromisoformat("2026-10-18T12:00:00+00:00")
    monkeypatch.setattr(sync_router, "_now", lambda: fixed)
    total = 1500
    changes = [
        {
            "collection": "events",
            "item_id": f"event-{index}",
            "data": {"id": f"event-{index}"},
        }
        for index in range(total)
    ]
    for offset in range(0, total, 400):
        pushed = client.post(
            "/api/v1/sync/push",
            headers=h,
            json={"changes": changes[offset : offset + 400]},
        )
        assert pushed.status_code == 200, pushed.text

    got: list[dict] = []
    params: dict[str, str | int] = {"limit": 37}
    while True:
        page = client.get("/api/v1/sync/pull", headers=h, params=params)
        assert page.status_code == 200, page.text
        body = page.json()
        got.extend(body["changes"])
        if not body["has_more"]:
            break
        assert body["next_cursor"]
        params = {"limit": 37, "cursor": body["next_cursor"]}

    assert len(got) == total
    assert len({record["item_id"] for record in got}) == total
    assert len({record["updated_at"] for record in got}) == 1


def test_legacy_since_pagination_includes_boundary_timestamp_ties(
    client: TestClient, monkeypatch
):
    from app.routers import sync as sync_router

    tokens = _register(client, "legacy-pagination@example.com")
    h = _auth("legacy-pagination@example.com", tokens)
    first_time = dt.datetime.fromisoformat("2026-10-18T12:00:00+00:00")
    monkeypatch.setattr(sync_router, "_now", lambda: first_time)
    tied_changes = [
        {
            "collection": "events",
            "item_id": f"tied-{index}",
            "data": {"id": f"tied-{index}"},
        }
        for index in range(1500)
    ]
    for offset in range(0, len(tied_changes), 400):
        pushed = client.post(
            "/api/v1/sync/push",
            headers=h,
            json={"changes": tied_changes[offset : offset + 400]},
        )
        assert pushed.status_code == 200, pushed.text

    later_time = first_time + dt.timedelta(seconds=1)
    monkeypatch.setattr(sync_router, "_now", lambda: later_time)
    later_changes = [
        {
            "collection": "events",
            "item_id": f"later-{index}",
            "data": {"id": f"later-{index}"},
        }
        for index in range(3)
    ]
    pushed = client.post(
        "/api/v1/sync/push", headers=h, json={"changes": later_changes}
    )
    assert pushed.status_code == 200, pushed.text

    # Simulate an old client: it ignores next_cursor and continues with the
    # final record's timestamp as its strict `since` value.
    since: str | None = None
    got: list[dict] = []
    while True:
        params: dict[str, str | int] = {"limit": 37}
        if since is not None:
            params["since"] = since
        page = client.get("/api/v1/sync/pull", headers=h, params=params)
        assert page.status_code == 200, page.text
        body = page.json()
        got.extend(body["changes"])
        if not body["has_more"]:
            break
        since = body["changes"][-1]["updated_at"]

    assert len(got) == 1503
    assert len({record["item_id"] for record in got}) == 1503
    assert sum(record["item_id"].startswith("tied-") for record in got) == 1500
    assert sum(record["item_id"].startswith("later-") for record in got) == 3


def test_pull_waits_for_inflight_push_before_advancing_watermark(
    client: TestClient, monkeypatch
):
    from app.routers import sync as sync_router

    tokens = _register(client, "concurrent-sync@example.com")
    h = _auth("concurrent-sync@example.com", tokens)
    row_written = threading.Event()
    release_push = threading.Event()
    original_to_record = sync_router._to_record

    def pause_after_push_write(row):
        if row.item_id == "concurrent-event":
            row_written.set()
            assert release_push.wait(5), "timed out waiting to release push request"
        return original_to_record(row)

    monkeypatch.setattr(sync_router, "_to_record", pause_after_push_write)
    with ThreadPoolExecutor(max_workers=2, thread_name_prefix="sync-request") as pool:
        def run_push():
            threading.current_thread().name = "push-request"
            return client.post(
                "/api/v1/sync/push",
                headers=h,
                json={
                    "changes": [
                        {
                            "collection": "events",
                            "item_id": "concurrent-event",
                            "data": {"id": "concurrent-event"},
                        }
                    ]
                },
            )

        push_future = pool.submit(run_push)
        assert row_written.wait(5), "push did not reach its uncommitted write"
        pull_future = pool.submit(
            client.get, "/api/v1/sync/pull", headers=h
        )
        time.sleep(0.1)
        assert not pull_future.done(), "pull passed the in-flight push lock"
        release_push.set()
        pushed = push_future.result(timeout=5)
        pulled = pull_future.result(timeout=5)

    assert pushed.status_code == 200, pushed.text
    assert pulled.status_code == 200, pulled.text
    assert any(
        change["item_id"] == "concurrent-event"
        for change in pulled.json()["changes"]
    )


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
