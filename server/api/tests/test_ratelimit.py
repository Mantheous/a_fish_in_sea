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


def test_limiter_stays_bounded_under_key_churn():
    rl = RateLimiter()
    now = 1000.0
    # Churn far more keys than the bucket cap.
    for i in range(rl._MAX_BUCKETS + 5000):
        rl.allowed(f"key-{i}", 5, 60, now=now + i * 0.001)
    assert len(rl._hits) <= rl._MAX_BUCKETS, len(rl._hits)
    assert len(rl._windows) <= rl._MAX_BUCKETS


def test_stale_buckets_swept_periodically():
    rl = RateLimiter()
    # An old key that should be reclaimed.
    rl.allowed("old", 5, 60, now=1000.0)
    # Enough new keys to trigger a stale sweep (_SWEEP_EVERY insertions).
    for i in range(rl._SWEEP_EVERY):
        rl.allowed(f"new-{i}", 5, 60, now=2000.0)
    assert "old" not in rl._hits, "stale bucket should have been swept"

    # A key accessed at the sweep time is not considered stale and survives.
    rl2 = RateLimiter()
    rl2.allowed("recent", 5, 60, now=5000.0)
    for i in range(rl2._SWEEP_EVERY):
        rl2.allowed(f"n-{i}", 5, 60, now=5000.0)
    assert "recent" in rl2._hits, "recent bucket should survive the sweep"
