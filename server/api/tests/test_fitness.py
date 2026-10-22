"""Fitness proxy auth: JWT-only writes/reads (refs #30).

/api/fitness/* holds per-user Garmin OAuth secrets via oauth_store.
Long-lived API tokens (scoped or review-only) must never read, write,
or clear those secrets — only an interactive JWT may.
"""

from __future__ import annotations

import os
import tempfile

import pytest
from fastapi.testclient import TestClient

os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{tempfile.mkdtemp()}/test_fitness.db"
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


def _mint(
    client: TestClient, h: dict, name: str, scopes: list, review: bool
) -> dict:
    r = client.post(
        "/api/v1/tokens",
        headers=h,
        json={"name": name, "scopes": scopes, "review": review},
    )
    assert r.status_code == 201, r.text
    return {"Authorization": f"Bearer {r.json()['token']}"}


def test_review_token_cannot_connect_or_disconnect(client: TestClient):
    h = _register(client, "fit-review@example.com")
    review = _mint(client, h, "reviewer", ["sync"], True)

    connect = client.post(
        "/api/fitness/connect",
        headers=review,
        json={"access_token": "attacker-value"},
    )
    assert connect.status_code == 403, connect.text

    disconnect = client.post("/api/fitness/disconnect", headers=review)
    assert disconnect.status_code == 403, disconnect.text


def test_scoped_token_cannot_connect_or_disconnect(client: TestClient):
    h = _register(client, "fit-scoped@example.com")
    scoped = _mint(client, h, "scoped", ["nodes:read"], False)

    connect = client.post(
        "/api/fitness/connect",
        headers=scoped,
        json={"access_token": "attacker-value"},
    )
    assert connect.status_code == 403, connect.text

    disconnect = client.post("/api/fitness/disconnect", headers=scoped)
    assert disconnect.status_code == 403, disconnect.text


def test_jwt_can_connect_and_disconnect(client: TestClient):
    h = _register(client, "fit-jwt@example.com")

    connect = client.post(
        "/api/fitness/connect",
        headers=h,
        json={"access_token": "at-1", "refresh_token": "rt-1"},
    )
    assert connect.status_code == 200, connect.text
    assert connect.json()["status"] == "connected"

    status = client.get("/api/fitness/status", headers=h)
    assert status.status_code == 200, status.text
    assert status.json()["connected"] is True

    disconnect = client.post("/api/fitness/disconnect", headers=h)
    assert disconnect.status_code == 200, disconnect.text
