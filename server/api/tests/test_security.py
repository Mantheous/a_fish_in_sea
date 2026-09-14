"""Security regression tests: collection allowlist, token scopes,
login oracle mitigation, and SSRF guards on server-side fetches."""

from __future__ import annotations

import os
import tempfile

import pytest
from fastapi.testclient import TestClient

os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{tempfile.mkdtemp()}/test_sec.db"
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


def test_items_reject_unknown_collection(client: TestClient):
    h = _register(client, "sec-items@example.com")
    assert client.get("/api/v1/items/nope", headers=h).status_code == 400
    assert client.get("/api/v1/items/nope/x", headers=h).status_code == 400
    put = client.put(
        "/api/v1/items/nope/x", headers=h, json={"data": {"id": "x"}}
    )
    assert put.status_code == 400
    post = client.post("/api/v1/items/nope", headers=h, json={"data": {}})
    assert post.status_code == 400
    delete = client.delete("/api/v1/items/nope/x", headers=h)
    assert delete.status_code == 400


def test_tokens_reject_unknown_scopes(client: TestClient):
    h = _register(client, "sec-tokens@example.com")
    bad = client.post(
        "/api/v1/tokens", headers=h, json={"name": "x", "scopes": ["admin"]}
    )
    assert bad.status_code == 400
    ok = client.post(
        "/api/v1/tokens",
        headers=h,
        json={"name": "x", "scopes": ["sync", "tasks:read"]},
    )
    assert ok.status_code == 201, ok.text


def test_login_unknown_email_is_401_not_500(client: TestClient):
    r = client.post(
        "/api/v1/auth/login",
        json={"email": "nobody-here@example.com", "password": "password123"},
    )
    assert r.status_code == 401


def test_ical_proxy_blocks_internal_hosts_without_network(client: TestClient):
    for url in (
        "http://127.0.0.1/x.ics",
        "http://169.254.169.254/",
        "http://192.168.1.1/f.ics",
        "ftp://example.com/f.ics",
    ):
        r = client.get("/api/ical", params={"url": url})
        assert r.status_code == 400, (url, r.text)


def test_fetch_refresh_stores_error_for_internal_host(client: TestClient):
    h = _register(client, "sec-fetch@example.com")
    r = client.post(
        "/api/v1/fetch/refresh",
        headers=h,
        json={"feed_id": "evil", "url": "http://127.0.0.1:9/x.ics"},
    )
    assert r.status_code == 200
    assert r.json()["status"] == "error"
