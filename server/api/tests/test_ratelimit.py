"""Rate limiter behavior + payload size caps."""

from __future__ import annotations

import os
import tempfile

import pytest
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient

os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{tempfile.mkdtemp()}/test_rl.db"
os.environ["JWT_SECRET"] = "test-secret"

from app.main import create_app  # noqa: E402
from app.ratelimit import RateLimiter, limit  # noqa: E402

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


def test_limiter_sliding_window():
    rl = RateLimiter()
    assert all(rl.allowed("k", 3, 60, now=1000.0 + i) for i in range(3))
    assert not rl.allowed("k", 3, 60, now=1000.5)
    # Window slides: first hits expire.
    assert rl.allowed("k", 3, 60, now=1061.0)
    assert rl.retry_after("k", 3, 60) >= 0
    rl.reset()
    assert rl.allowed("k", 3, 60, now=1062.0)


def test_limit_dependency_answers_429_with_retry_after():
    rl = RateLimiter()
    mini = FastAPI()

    @mini.get("/ping", dependencies=[Depends(limit("t:ping", 2, 60, instance=rl))])
    async def ping():
        return {"ok": True}

    with TestClient(mini) as c:
        assert c.get("/ping").status_code == 200
        assert c.get("/ping").status_code == 200
        r = c.get("/ping")
        assert r.status_code == 429
        assert "Retry-After" in r.headers


def test_oversize_push_rejected(client: TestClient):
    h = _register(client, "sec-size@example.com")
    big = "x" * (300 * 1024)
    r = client.post(
        "/api/v1/sync/push",
        headers=h,
        json={"changes": [{"collection": "tasks", "item_id": "big", "data": {"blob": big}}]},
    )
    assert r.status_code == 422, r.text
    put = client.put(
        "/api/v1/items/tasks/big", headers=h, json={"data": {"blob": big}}
    )
    assert put.status_code == 422
    # Normal payloads still pass.
    ok = client.post(
        "/api/v1/sync/push",
        headers=h,
        json={"changes": [{"collection": "tasks", "item_id": "t1", "data": {"id": "t1"}}]},
    )
    assert ok.status_code == 200, ok.text
