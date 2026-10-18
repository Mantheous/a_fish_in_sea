"""Concurrency hardening: sign-ups and same-key upserts never return 500.

Fires concurrent requests for the same email / same sync item key and
asserts every response is a clean client or success code (never 500) and
exactly one side-effect wins.
"""

from __future__ import annotations

import asyncio
import os
import tempfile
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor

os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{tempfile.mkdtemp()}/concurrency.db"
os.environ["JWT_SECRET"] = "test-secret"

import httpx  # noqa: E402
from app.db import init_db  # noqa: E402
from app.main import app  # noqa: E402

# Initialize the schema once. httpx ASGITransport clients do not run the
# FastAPI lifespan, so this single init_db is enough for every worker.
asyncio.run(init_db())

_WORKERS = 10


async def _async_request(method: str, path: str, headers: dict, json_body: dict):
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as c:
        if method == "POST":
            return await c.post(path, headers=headers, json=json_body)
        return await c.get(path, headers=headers, params=json_body)


def _register(email: str) -> str:
    r = asyncio.run(
        _async_request(
            "POST",
            "/api/v1/auth/register",
            {},
            {"email": email, "password": "password123"},
        )
    )
    assert r.status_code == 201, r.text
    return r.json()["access_token"]


def _headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _concurrent_post(path: str, headers: dict, json_body: dict) -> list[int]:
    results: list[int] = []
    barrier = threading.Barrier(_WORKERS)

    def worker() -> None:
        async def run() -> None:
            barrier.wait()
            r = await _async_request("POST", path, headers, json_body)
            results.append(r.status_code)

        asyncio.run(run())

    with ThreadPoolExecutor(max_workers=_WORKERS) as ex:
        list(ex.map(lambda _: worker(), range(_WORKERS)))
    return results


def test_concurrent_register_same_email_never_500():
    email = f"conc-reg-{uuid.uuid4().hex[:8]}@example.com"
    results = _concurrent_post(
        "/api/v1/auth/register", {}, {"email": email, "password": "password123"}
    )
    assert 500 not in results, results
    assert results.count(201) == 1, results
    assert all(code in (201, 409) for code in results), results


def test_concurrent_push_same_key_never_500():
    email = f"conc-push-{uuid.uuid4().hex[:8]}@example.com"
    token = _register(email)
    headers = _headers(token)
    payload = {
        "changes": [
            {
                "collection": "tasks",
                "item_id": "conc-key",
                "data": {"id": "conc-key", "title": "concurrent"},
            }
        ]
    }
    results = _concurrent_post("/api/v1/sync/push", headers, payload)
    assert 500 not in results, results
    assert results.count(200) == _WORKERS, results

    # Exactly one row exists for the key.
    r = asyncio.run(
        _async_request(
            "GET",
            "/api/v1/sync/pull",
            headers,
            {"collections": "tasks"},
        )
    )
    assert r.status_code == 200, r.text
    items = [x for x in r.json()["changes"] if x["item_id"] == "conc-key"]
    assert len(items) == 1, items


def test_concurrent_import_same_item_never_500():
    email = f"conc-import-{uuid.uuid4().hex[:8]}@example.com"
    token = _register(email)
    headers = _headers(token)
    payload = {
        "items": [
            {
                "collection": "events",
                "item_id": "conc-key",
                "data": {"id": "conc-key", "title": "concurrent"},
            }
        ]
    }
    results = _concurrent_post("/api/v1/imports", headers, payload)
    assert 500 not in results, results
    assert results.count(201) == _WORKERS, results
