"""Refresh-token rotation, reuse detection, and logout."""

from __future__ import annotations

import os
import tempfile

import pytest
from fastapi.testclient import TestClient

os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{tempfile.mkdtemp()}/test_rt.db"
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


def _refresh(client: TestClient, token: str):
    return client.post("/api/v1/auth/refresh", json={"refresh_token": token})


def test_refresh_rotates_and_old_token_dies(client: TestClient):
    tokens = _register(client, "rt-rotate@example.com")
    r1 = _refresh(client, tokens["refresh_token"])
    assert r1.status_code == 200, r1.text
    fresh = r1.json()["refresh_token"]
    assert fresh != tokens["refresh_token"]
    # Successor works and rotates again.
    r2 = _refresh(client, fresh)
    assert r2.status_code == 200, r2.text
    # The superseded tokens are revoked (presenting one now would look
    # like theft and kill the family, so this goes last).
    assert _refresh(client, tokens["refresh_token"]).status_code == 401


def test_reuse_of_revoked_token_keeps_family_intact(client: TestClient):
    tokens = _register(client, "rt-reuse@example.com")
    r1 = _refresh(client, tokens["refresh_token"])
    assert r1.status_code == 200
    live = r1.json()["refresh_token"]
    # Attacker replays the already-rotated token: rejected, but the rest of
    # the family is NOT wiped (no collateral logout of every device).
    assert _refresh(client, tokens["refresh_token"]).status_code == 401
    # The live successor from the same family still works and rotates again.
    r2 = _refresh(client, live)
    assert r2.status_code == 200
    rotated_again = r2.json()["refresh_token"]
    assert rotated_again != live
    # A fresh login starts a new family and works.
    login = client.post(
        "/api/v1/auth/login",
        json={"email": "rt-reuse@example.com", "password": "password123"},
    )
    assert login.status_code == 200
    assert _refresh(client, login.json()["refresh_token"]).status_code == 200


def test_concurrent_double_refresh_one_winner_family_intact(client: TestClient):
    import threading

    tokens = _register(client, "rt-concurrent@example.com")
    outcomes = []

    def worker() -> None:
        outcomes.append(_refresh(client, tokens["refresh_token"]))

    threads = [threading.Thread(target=worker) for _ in range(6)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    statuses = [o.status_code for o in outcomes]
    # Exactly one rotation wins; the rest are rejected.
    assert statuses.count(200) == 1, statuses
    winner = next(o for o in outcomes if o.status_code == 200)
    successor = winner.json()["refresh_token"]
    # Successor is still live (family intact) and rotates again.
    assert _refresh(client, successor).status_code == 200
    # The original token is now revoked.
    assert _refresh(client, tokens["refresh_token"]).status_code == 401


def test_logout_revokes_single_token(client: TestClient):
    tokens = _register(client, "rt-logout@example.com")
    out = client.post(
        "/api/v1/auth/logout", json={"refresh_token": tokens["refresh_token"]}
    )
    assert out.status_code == 200
    assert _refresh(client, tokens["refresh_token"]).status_code == 401
    # Unknown tokens also answer 200 (no oracle).
    out2 = client.post("/api/v1/auth/logout", json={"refresh_token": "garbage"})
    assert out2.status_code == 200


def test_logout_all_revokes_everything(client: TestClient):
    tokens = _register(client, "rt-logoutall@example.com")
    login = client.post(
        "/api/v1/auth/login",
        json={"email": "rt-logoutall@example.com", "password": "password123"},
    )
    second = login.json()["refresh_token"]
    h = {"Authorization": f"Bearer {tokens['access_token']}"}
    out = client.post("/api/v1/auth/logout_all", headers=h)
    assert out.status_code == 200
    assert _refresh(client, tokens["refresh_token"]).status_code == 401
    assert _refresh(client, second).status_code == 401


def test_garbage_refresh_is_401(client: TestClient):
    assert _refresh(client, "not-a-token").status_code == 401
