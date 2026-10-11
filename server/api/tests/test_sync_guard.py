"""Mass-deletion guard: tombstones that would wipe most of a collection are
withheld (they are almost always a client that lost its local store), while
ordinary small deletes still propagate. Mirrors the Dart SyncEngine guard."""

from __future__ import annotations

import os
import tempfile

import pytest
from fastapi.testclient import TestClient

os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{tempfile.mkdtemp()}/test.db"
os.environ["JWT_SECRET"] = "test-secret"

from app.main import create_app  # noqa: E402
from app.routers.sync import _looks_like_mass_delete  # noqa: E402

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


def _push(client: TestClient, h: dict, changes: list[dict]) -> dict:
    r = client.post("/api/v1/sync/push", headers=h, json={"changes": changes})
    assert r.status_code == 200, r.text
    return r.json()


def _live_ids(client: TestClient, h: dict, collection: str) -> set[str]:
    r = client.get(
        "/api/v1/sync/pull", headers=h, params={"collections": collection}
    )
    assert r.status_code == 200, r.text
    return {
        c["item_id"] for c in r.json()["changes"] if not c["deleted"]
    }


def test_guard_thresholds():
    # Small collections: near-total loss is guarded, a couple of deletes is not.
    assert _looks_like_mass_delete(6, 6)
    assert not _looks_like_mass_delete(2, 6)
    # Large collections: a big chunk of the collection at once is guarded;
    # a smaller share (below 20%) passes, matching the Dart client guard.
    assert _looks_like_mass_delete(500, 2330)
    assert not _looks_like_mass_delete(400, 2330)
    assert not _looks_like_mass_delete(50, 2330)
    # Nothing to protect / nothing pending is never guarded.
    assert not _looks_like_mass_delete(5, 0)
    assert not _looks_like_mass_delete(0, 100)


def test_mass_feed_delete_is_withheld(client: TestClient):
    tokens = _register(client, "guard-feeds@example.com")
    h = _auth(tokens)
    feeds = [
        {
            "collection": "feeds",
            "item_id": f"feed:{i}",
            "data": {"id": f"feed:{i}", "name": f"Feed {i}", "url": ""},
        }
        for i in range(6)
    ]
    _push(client, h, feeds)

    out = _push(
        client,
        h,
        [
            {
                "collection": "feeds",
                "item_id": f["item_id"],
                "data": {},
                "deleted": True,
            }
            for f in feeds
        ],
    )
    assert out["applied"] == []
    assert len(out["guarded"]) == 6
    assert {g["item_id"] for g in out["guarded"]} == {
        f["item_id"] for f in feeds
    }
    # The cloud copy survives.
    assert len(_live_ids(client, h, "feeds")) == 6


def test_small_legit_deletes_still_apply(client: TestClient):
    tokens = _register(client, "guard-small@example.com")
    h = _auth(tokens)
    nodes = [
        {
            "collection": "nodes",
            "item_id": f"n{i}",
            "data": {"id": f"n{i}", "title": f"Node {i}"},
        }
        for i in range(3)
    ]
    _push(client, h, nodes)

    out = _push(
        client,
        h,
        [
            {"collection": "nodes", "item_id": f"n{i}", "data": {}, "deleted": True}
            for i in range(2)
        ],
    )
    assert len(out["applied"]) == 2
    assert out["guarded"] == []
    assert _live_ids(client, h, "nodes") == {"n2"}


def test_partial_cleanup_applies_until_it_looks_like_a_wipe(client: TestClient):
    tokens = _register(client, "guard-partial@example.com")
    h = _auth(tokens)
    events = [
        {
            "collection": "events",
            "item_id": f"e{i}",
            "data": {"id": f"e{i}", "subject": f"Event {i}"},
        }
        for i in range(20)
    ]
    _push(client, h, events)

    # Deleting 6 of 20 is plausible cleanup: applies.
    out = _push(
        client,
        h,
        [
            {"collection": "events", "item_id": f"e{i}", "data": {}, "deleted": True}
            for i in range(6)
        ],
    )
    assert len(out["applied"]) == 6
    assert out["guarded"] == []

    # Deleting (nearly) the rest at once is a wipe: withheld.
    out = _push(
        client,
        h,
        [
            {"collection": "events", "item_id": f"e{i}", "data": {}, "deleted": True}
            for i in range(6, 19)
        ],
    )
    assert out["applied"] == []
    assert len(out["guarded"]) == 13
    assert len(_live_ids(client, h, "events")) == 14


def test_escape_hatch_env(client: TestClient, monkeypatch: pytest.MonkeyPatch):
    tokens = _register(client, "guard-env@example.com")
    h = _auth(tokens)
    feeds = [
        {
            "collection": "feeds",
            "item_id": f"env:{i}",
            "data": {"id": f"env:{i}", "name": f"F{i}", "url": ""},
        }
        for i in range(5)
    ]
    _push(client, h, feeds)

    monkeypatch.setenv("SYNC_ALLOW_MASS_DELETE", "1")
    out = _push(
        client,
        h,
        [
            {
                "collection": "feeds",
                "item_id": f["item_id"],
                "data": {},
                "deleted": True,
            }
            for f in feeds
        ],
    )
    assert len(out["applied"]) == 5
    assert out["guarded"] == []
    assert _live_ids(client, h, "feeds") == set()
