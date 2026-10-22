"""Scoped / review-only API token authorization (refs #58).

The authz enforcement itself (JWT-only token endpoints, scope-gated
sync/items, review-lane imports) lives in deps/tokens/sync/items/imports;
the broad escalation matrix is covered in test_security.py and the staging
lane in test_imports.py. These tests pin the remaining gaps: narrow scopes
on /sync/push, review tokens on item create/read, and that a review-token
import stages without touching the sync envelope.
"""

from __future__ import annotations

import os
import tempfile

import pytest
from fastapi.testclient import TestClient

os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{tempfile.mkdtemp()}/test_authz.db"
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


def _mint(client: TestClient, h: dict, name: str, scopes: list, review: bool) -> dict:
    r = client.post(
        "/api/v1/tokens",
        headers=h,
        json={"name": name, "scopes": scopes, "review": review},
    )
    assert r.status_code == 201, r.text
    return {"Authorization": f"Bearer {r.json()['token']}"}


def _push_change(collection: str, item_id: str) -> dict:
    return {
        "collection": collection,
        "item_id": item_id,
        "data": {"id": item_id, "title": "scoped"},
    }


def test_scoped_token_push_is_collection_gated(client: TestClient):
    h = _register(client, "authz-push@example.com")
    ro = _mint(client, h, "ro", ["events:read"], False)
    wo = _mint(client, h, "wo", ["events:write"], False)

    # Read-only token cannot push anything.
    for payload in (
        _push_change("events", "authz-e1"),
        _push_change("nodes", "authz-n1"),
    ):
        r = client.post("/api/v1/sync/push", headers=ro, json={"changes": [payload]})
        assert r.status_code == 403, (payload, r.text)

    # Write-scoped token pushes its own collection but not others.
    ok = client.post(
        "/api/v1/sync/push", headers=wo, json={"changes": [_push_change("events", "authz-e2")]}
    )
    assert ok.status_code == 200, ok.text
    assert [c["item_id"] for c in ok.json()["applied"]] == ["authz-e2"]
    bad = client.post(
        "/api/v1/sync/push", headers=wo, json={"changes": [_push_change("nodes", "authz-n2")]}
    )
    assert bad.status_code == 403, bad.text
    # A mixed batch is rejected whole: nothing is applied.
    mixed = client.post(
        "/api/v1/sync/push",
        headers=wo,
        json={"changes": [_push_change("events", "authz-e3"), _push_change("nodes", "authz-n3")]},
    )
    assert mixed.status_code == 403, mixed.text
    pull = client.get("/api/v1/sync/pull", headers=h)
    assert all(
        c["item_id"] not in ("authz-e1", "authz-n1", "authz-n2", "authz-e3", "authz-n3")
        for c in pull.json()["changes"]
    )

    # Full login still pushes anywhere.
    jwt_ok = client.post(
        "/api/v1/sync/push", headers=h, json={"changes": [_push_change("nodes", "authz-n4")]}
    )
    assert jwt_ok.status_code == 200, jwt_ok.text


def test_review_token_item_create_and_read_blocked(client: TestClient):
    h = _register(client, "authz-items@example.com")
    rh = _mint(client, h, "rev", ["sync"], True)

    assert (
        client.post("/api/v1/items/nodes", headers=rh, json={"data": {"title": "x"}}).status_code
        == 403
    )
    assert client.get("/api/v1/items/nodes", headers=rh).status_code == 403
    assert client.get("/api/v1/items/nodes/whatever", headers=rh).status_code == 403

    # Full login is unaffected.
    put = client.put(
        "/api/v1/items/nodes/authz-direct",
        headers=h,
        json={"data": {"id": "authz-direct", "title": "x"}},
    )
    assert put.status_code == 200, put.text


def test_review_token_import_stages_without_applying(client: TestClient):
    h = _register(client, "authz-stage@example.com")
    rh = _mint(client, h, "rev", ["nodes:write"], True)

    sub = client.post(
        "/api/v1/imports",
        headers=rh,
        json={
            "items": [
                {
                    "collection": "nodes",
                    "item_id": "authz-staged-1",
                    "data": {"id": "authz-staged-1", "title": "staged"},
                }
            ],
            "source": "agent",
        },
    )
    assert sub.status_code == 201, sub.text
    assert sub.json()["status"] == "pending"
    assert sub.json()["batch_id"] is not None

    # Nothing reached the sync envelope until the user approves.
    pull = client.get("/api/v1/sync/pull", headers=h)
    assert all(c["item_id"] != "authz-staged-1" for c in pull.json()["changes"])
