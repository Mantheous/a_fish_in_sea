"""Staged imports: review lane, trusted lane, approve/discard/reject."""

from __future__ import annotations

import os
import tempfile

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import event

os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{tempfile.mkdtemp()}/test.db"
os.environ["JWT_SECRET"] = "test-secret"

from app.db import engine  # noqa: E402
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


def _auth(tokens: dict) -> dict:
    return {"Authorization": f"Bearer {tokens['access_token']}"}


def _node(item_id: str, title: str = "HW 1", due: str = "2026-03-04T23:59:00"):
    return {
        "collection": "nodes",
        "item_id": item_id,
        "data": {
            "id": item_id,
            "title": title,
            "status": "open",
            "schedule": {"due": due},
            "classLabel": "Math",
        },
    }


def test_review_token_stages_and_approve_applies(client: TestClient):
    tokens = _register(client, "imp1@example.com")
    h = _auth(tokens)

    created = client.post(
        "/api/v1/tokens",
        headers=h,
        json={"name": "laptop import", "scopes": ["sync"], "review": True},
    )
    assert created.status_code == 201, created.text
    assert created.json()["review"] is True
    ah = {"Authorization": f"Bearer {created.json()['token']}"}

    sub = client.post(
        "/api/v1/imports",
        headers=ah,
        json={"items": [_node("ls:math:aaaabbbbccccdddd")], "source": "scraper"},
    )
    assert sub.status_code == 201, sub.text
    assert sub.json()["status"] == "pending"
    batch_id = sub.json()["batch_id"]

    # Nothing reached the sync envelope.
    pull = client.get("/api/v1/sync/pull", headers=h)
    assert all(c["item_id"] != "ls:math:aaaabbbbccccdddd" for c in pull.json()["changes"])

    # Pending inbox shows the batch with no existing conflict.
    pend = client.get("/api/v1/imports/pending", headers=h)
    assert pend.status_code == 200
    assert len(pend.json()) == 1
    assert pend.json()[0]["items"][0]["existing"] is None

    # Token cannot self-approve.
    denied = client.post(f"/api/v1/imports/{batch_id}/approve", headers=ah, json={})
    assert denied.status_code == 403

    # User approves; the node lands in the envelope for all devices.
    ok = client.post(f"/api/v1/imports/{batch_id}/approve", headers=h, json={})
    assert ok.status_code == 200, ok.text
    assert ok.json()["status"] == "approved"
    pull2 = client.get("/api/v1/sync/pull", headers=h)
    got = [c for c in pull2.json()["changes"] if c["item_id"] == "ls:math:aaaabbbbccccdddd"]
    assert len(got) == 1
    assert got[0]["data"]["title"] == "HW 1"

    # Inbox is empty again.
    assert client.get("/api/v1/imports/pending", headers=h).json() == []


def test_trusted_token_applies_directly(client: TestClient):
    tokens = _register(client, "imp2@example.com")
    h = _auth(tokens)
    created = client.post(
        "/api/v1/tokens", headers=h, json={"name": "agent", "scopes": ["sync"]}
    )
    ah = {"Authorization": f"Bearer {created.json()['token']}"}
    sub = client.post(
        "/api/v1/imports", headers=ah, json={"items": [_node("n-direct-1")]}
    )
    assert sub.json()["status"] == "applied"
    pull = client.get("/api/v1/sync/pull", headers=h)
    assert any(c["item_id"] == "n-direct-1" for c in pull.json()["changes"])


def test_reject_and_discard_never_touch_app_data(client: TestClient):
    tokens = _register(client, "imp3@example.com")
    h = _auth(tokens)
    created = client.post(
        "/api/v1/tokens",
        headers=h,
        json={"name": "r", "scopes": ["sync"], "review": True},
    )
    ah = {"Authorization": f"Bearer {created.json()['token']}"}

    sub = client.post(
        "/api/v1/imports",
        headers=ah,
        json={"items": [_node("n-a"), _node("n-b"), _node("n-c")]},
    )
    batch_id = sub.json()["batch_id"]

    # Discard one item; batch stays pending with two left.
    d = client.post(
        f"/api/v1/imports/{batch_id}/discard", headers=h, json={"item_ids": ["n-a"]}
    )
    assert d.status_code == 200, d.text
    assert d.json()["status"] == "pending"

    # Approve one of the remaining two; batch still pending.
    a = client.post(
        f"/api/v1/imports/{batch_id}/approve", headers=h, json={"item_ids": ["n-b"]}
    )
    assert a.json()["status"] == "pending"

    # Reject the batch: n-c never lands, n-b stays (approval is write-only).
    r = client.post(f"/api/v1/imports/{batch_id}/reject", headers=h)
    assert r.json()["status"] == "rejected"
    pull = client.get("/api/v1/sync/pull", headers=h)
    ids = {c["item_id"] for c in pull.json()["changes"]}
    assert "n-a" not in ids and "n-c" not in ids
    assert "n-b" in ids


def test_conflict_row_shows_existing_and_update_wins(client: TestClient):
    tokens = _register(client, "imp4@example.com")
    h = _auth(tokens)
    created = client.post(
        "/api/v1/tokens",
        headers=h,
        json={"name": "r", "scopes": ["sync"], "review": True},
    )
    ah = {"Authorization": f"Bearer {created.json()['token']}"}

    first = client.post(
        "/api/v1/imports", headers=ah, json={"items": [_node("n-fix", due="2026-03-04T23:59:00")]}
    )
    client.post(f"/api/v1/imports/{first.json()['batch_id']}/approve", headers=h, json={})

    # Re-scrape with the corrected due date: same item_id, new due.
    second = client.post(
        "/api/v1/imports", headers=ah, json={"items": [_node("n-fix", due="2026-03-07T23:59:00")]}
    )
    pend = client.get("/api/v1/imports/pending", headers=h).json()
    assert len(pend) == 1
    item = pend[0]["items"][0]
    assert item["existing"]["schedule"]["due"] == "2026-03-04T23:59:00"
    assert item["data"]["schedule"]["due"] == "2026-03-07T23:59:00"

    client.post(
        f"/api/v1/imports/{second.json()['batch_id']}/approve", headers=h, json={}
    )
    pull = client.get(
        "/api/v1/sync/pull", headers=h, params={"collections": "nodes"}
    )
    rows = [c for c in pull.json()["changes"] if c["item_id"] == "n-fix"]
    assert rows[-1]["data"]["schedule"]["due"] == "2026-03-07T23:59:00"


def test_tasks_collection_rejected_and_caps_enforced(client: TestClient):
    tokens = _register(client, "imp5@example.com")
    h = _auth(tokens)
    bad = client.post(
        "/api/v1/imports",
        headers=h,
        json={"items": [{"collection": "tasks", "item_id": "t1", "data": {}}]},
    )
    assert bad.status_code == 400
    empty = client.post("/api/v1/imports", headers=h, json={"items": []})
    assert empty.status_code == 422


def test_backfill_adds_review_column_to_pre_change_schema():
    """A live app.db minted before the review flag has api_tokens WITHOUT
    the column. init_db's backfill must add it without touching rows."""
    import asyncio
    import sqlite3

    from sqlalchemy.ext.asyncio import create_async_engine

    from app.db import _backfill_api_tokens_review

    path = f"{tempfile.mkdtemp()}/old.db"
    con = sqlite3.connect(path)
    con.execute(
        "CREATE TABLE api_tokens (id INTEGER PRIMARY KEY, user_id INTEGER, "
        "name VARCHAR(120), token_hash VARCHAR(128), prefix VARCHAR(16), "
        "scopes JSON, revoked BOOLEAN, created_at DATETIME, "
        "last_used_at DATETIME)"
    )
    con.execute(
        "INSERT INTO api_tokens (user_id, name, token_hash, prefix, scopes, "
        "revoked) VALUES (1, 'old', 'abc', 'afm', '[\"sync\"]', 0)"
    )
    con.commit()
    con.close()

    async def run():
        engine = create_async_engine(f"sqlite+aiosqlite:///{path}")
        async with engine.begin() as conn:
            await _backfill_api_tokens_review(conn)
            res = await conn.exec_driver_sql("PRAGMA table_info(api_tokens)")
            assert "review" in [c[1] for c in res.all()]
            # second run is a no-op (idempotent, never re-adds)
            await _backfill_api_tokens_review(conn)
        await engine.dispose()

    asyncio.run(run())
    con = sqlite3.connect(path)
    row = con.execute("SELECT name, review FROM api_tokens").fetchone()
    assert row == ("old", 0)
    con.close()


def test_deleted_row_is_flagged_not_hidden(client: TestClient):
    tokens = _register(client, "imp6@example.com")
    h = _auth(tokens)
    created = client.post(
        "/api/v1/tokens",
        headers=h,
        json={"name": "r", "scopes": ["sync"], "review": True},
    )
    ah = {"Authorization": f"Bearer {created.json()['token']}"}

    # Live node, then user deletes it in the app (tombstone, via sync).
    client.post(
        "/api/v1/sync/push",
        headers=h,
        json={"changes": [_node("n-gone")]},
    )
    client.post(
        "/api/v1/sync/push",
        headers=h,
        json={"changes": [dict(_node("n-gone"), deleted=True)]},
    )

    sub = client.post(
        "/api/v1/imports", headers=ah, json={"items": [_node("n-gone")]}
    )
    pend = client.get("/api/v1/imports/pending", headers=h).json()
    assert len(pend) == 1
    item = pend[0]["items"][0]
    assert item["existing"] is not None
    assert item["existing_deleted"] is True

    # Approving is an explicit restore: the row comes back, undeleted.
    client.post(
        f"/api/v1/imports/{sub.json()['batch_id']}/approve", headers=h, json={}
    )
    pull = client.get(
        "/api/v1/sync/pull", headers=h, params={"collections": "nodes"}
    )
    rows = [c for c in pull.json()["changes"] if c["item_id"] == "n-gone"]
    assert rows[-1]["deleted"] is False


def _review_token(client: TestClient, h: dict, scopes: list[str]) -> dict:
    created = client.post(
        "/api/v1/tokens", headers=h,
        json={"name": "review", "scopes": scopes, "review": True},
    )
    assert created.status_code == 201, created.text
    assert created.json()["review"] is True
    return {"Authorization": f"Bearer {created.json()['token']}"}


def test_approve_discard_keyed_by_collection_item_id(client: TestClient):
    """The same item_id in two collections must act independently:
    approving nodes:X must not touch events:X, and a bare id shared across
    collections is rejected instead of silently acting on both."""
    tokens = _register(client, "imp-x@example.com")
    h = _auth(tokens)
    ah = _review_token(client, h, ["nodes:write", "events:write"])

    x = "shared-x"
    sub = client.post(
        "/api/v1/imports", headers=ah,
        json={
            "items": [
                {"collection": "nodes", "item_id": x,
                 "data": {"id": x, "title": "Node X"}},
                {"collection": "events", "item_id": x,
                 "data": {"id": x, "subject": "Event X"}},
            ],
            "source": "scraper",
        },
    )
    assert sub.status_code == 201, sub.text
    batch_id = sub.json()["batch_id"]

    # Approve/discard are JWT-only; the review token only stages.
    amb = client.post(
        f"/api/v1/imports/{batch_id}/approve", headers=ah, json={"item_ids": [x]}
    )
    assert amb.status_code == 403

    # A bare id shared across collections is ambiguous: rejected, not acted on both.
    amb = client.post(
        f"/api/v1/imports/{batch_id}/approve", headers=h, json={"item_ids": [x]}
    )
    assert amb.status_code == 400, amb.text
    assert "multiple collections" in amb.json()["detail"]

    # Approve only the nodes row: events:X stays pending and never syncs.
    ok = client.post(
        f"/api/v1/imports/{batch_id}/approve", headers=h,
        json={"item_ids": [f"nodes:{x}"]},
    )
    assert ok.status_code == 200, ok.text
    by_pair = {
        (it["collection"], it["item_id"]): it["status"]
        for it in ok.json()["items"]
    }
    assert by_pair[("nodes", x)] == "approved"
    assert by_pair[("events", x)] == "pending"
    pull = client.get("/api/v1/sync/pull", headers=h)
    got = [c for c in pull.json()["changes"] if c["item_id"] == x]
    assert len(got) == 1
    assert got[0]["collection"] == "nodes"

    # Discard only the events row: nodes:X stays approved.
    d = client.post(
        f"/api/v1/imports/{batch_id}/discard", headers=h,
        json={"item_ids": [f"events:{x}"]},
    )
    assert d.status_code == 200, d.text
    by_pair = {
        (it["collection"], it["item_id"]): it["status"]
        for it in d.json()["items"]
    }
    assert by_pair[("events", x)] == "rejected"
    assert by_pair[("nodes", x)] == "approved"

    # Inbox is empty once everything is decided.
    assert client.get("/api/v1/imports/pending", headers=h).json() == []


def test_put_item_singleton_force_corrects_id(client: TestClient):
    """PUT /items on a singleton never stores a data.id that disagrees with
    the row id (settings, waterfall and plaid are all singletons), so a
    later push of that row is accepted instead of wedging."""
    tokens = _register(client, "imp-singleton@example.com")
    h = _auth(tokens)

    for collection in ("settings", "waterfall", "plaid"):
        r = client.put(
            f"/api/v1/items/{collection}/singleton", headers=h,
            json={"data": {"id": "WRONG", "k": "v"}},
        )
        assert r.status_code == 200, (collection, r.text)
        assert r.json()["data"]["id"] == "singleton", (collection, r.json())

        # A matching push of that row is accepted: not wedgeable.
        out = client.post(
            "/api/v1/sync/push", headers=h,
            json={"changes": [{
                "collection": collection, "item_id": "singleton",
                "data": {"id": "singleton", "k": "v2"}, "deleted": False,
            }]},
        )
        assert out.status_code == 200, (collection, out.text)


def test_pending_fetch_batches_existence_lookups(client: TestClient):
    """The pending inbox looks up existing sync rows per collection (one
    batched IN query per collection), not one query per item."""
    tokens = _register(client, "imp-b@example.com")
    h = _auth(tokens)
    ah = _review_token(client, h, ["nodes:write", "events:write"])

    items = [
        {"collection": "nodes", "item_id": f"n{i}",
         "data": {"id": f"n{i}", "title": f"N{i}"}}
        for i in range(25)
    ] + [
        {"collection": "events", "item_id": f"e{i}",
         "data": {"id": f"e{i}", "subject": f"E{i}"}}
        for i in range(25)
    ]
    sub = client.post("/api/v1/imports", headers=ah, json={"items": items, "source": "scraper"})
    assert sub.status_code == 201, sub.text

    eng = engine().sync_engine
    hits: list[str] = []

    def before(conn, cursor, statement, parameters, context, executemany):
        hits.append(statement)

    event.listen(eng, "before_cursor_execute", before)
    try:
        pend = client.get("/api/v1/imports/pending", headers=h)
    finally:
        event.remove(eng, "before_cursor_execute", before)

    assert pend.status_code == 200
    assert len(pend.json()) == 1
    assert len(pend.json()[0]["items"]) == 50
    selects = [s for s in hits if s.lstrip().lower().startswith("select")]
    # Bounded (handful of queries), not one per item: with 50 staged items
    # an N+1 lookup would issue far more than this.
    assert len(selects) < 40, selects
