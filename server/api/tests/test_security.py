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
        "http://100.64.0.1/x.ics",
        "http://[::1]/x.ics",
        "http://[::ffff:127.0.0.1]/x.ics",
        "http://[::ffff:169.254.169.254]/x.ics",
        "http://[fd7a:115c:a1e0::1]/x.ics",
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


def test_fetch_public_bytes_reuses_pooled_http_client():
    """fetch_public_bytes reuses one pooled httpx client instead of opening a
    fresh client per request (and per redirect hop), which caps file-descriptor
    churn under fetch abuse."""
    import asyncio

    import httpx

    from app import ssrf

    ssrf._HTTP_CLIENT = None
    try:
        first = ssrf._http_client()
        second = ssrf._http_client()
        assert isinstance(first, httpx.AsyncClient)
        assert first is second  # same pooled instance, not one per request
    finally:
        client = ssrf._HTTP_CLIENT
        ssrf._HTTP_CLIENT = None
        if client is not None:
            asyncio.run(client.aclose())


def test_api_tokens_cannot_self_escalate_or_bypass_review(client: TestClient):
    h = _register(client, "sec-esc@example.com")
    # Mint a review-only token and a read-only events token.
    rev_tok = client.post(
        "/api/v1/tokens",
        headers=h,
        json={"name": "rev", "scopes": ["sync"], "review": True},
    ).json()["token"]
    ro_tok = client.post(
        "/api/v1/tokens",
        headers=h,
        json={"name": "ro", "scopes": ["events:read"], "review": False},
    ).json()["token"]
    rh = {"Authorization": f"Bearer {rev_tok}"}
    roh = {"Authorization": f"Bearer {ro_tok}"}

    # 1) Neither token may mint, list, or revoke tokens.
    for th in (rh, roh):
        assert (
            client.post(
                "/api/v1/tokens",
                headers=th,
                json={"name": "pwn", "scopes": ["sync"], "review": False},
            ).status_code
            == 403
        )
        assert client.get("/api/v1/tokens", headers=th).status_code == 403
        assert client.delete("/api/v1/tokens/1", headers=th).status_code == 403

    # 2) Review token cannot push/pull sync or write/read items directly.
    assert (
        client.post(
            "/api/v1/sync/push",
            headers=rh,
            json={
                "changes": [
                    {
                        "collection": "nodes",
                        "item_id": "n1",
                        "data": {"id": "n1", "title": "bypass"},
                    }
                ]
            },
        ).status_code
        == 403
    )
    assert client.get("/api/v1/sync/pull", headers=rh).status_code == 403
    assert (
        client.put(
            "/api/v1/items/nodes/n1",
            headers=rh,
            json={"data": {"id": "n1", "title": "bypass"}},
        ).status_code
        == 403
    )
    assert client.delete("/api/v1/items/nodes/n1", headers=rh).status_code == 403

    # 3) Narrow events:read token can read events, but cannot write events,
    #    cannot read nodes, cannot push/import, and cannot reach side services.
    assert client.get("/api/v1/items/events", headers=roh).status_code == 200
    assert (
        client.get(
            "/api/v1/sync/pull", headers=roh, params={"collections": "events"}
        ).status_code
        == 200
    )
    assert client.get("/api/v1/sync/pull", headers=roh).status_code == 403
    assert (
        client.get(
            "/api/v1/sync/pull", headers=roh, params={"collections": "nodes"}
        ).status_code
        == 403
    )
    assert client.get("/api/v1/items/nodes", headers=roh).status_code == 403
    assert (
        client.put(
            "/api/v1/items/events/e1",
            headers=roh,
            json={"data": {"id": "e1", "subject": "x"}},
        ).status_code
        == 403
    )
    assert (
        client.post(
            "/api/v1/imports",
            headers=roh,
            json={
                "items": [
                    {
                        "collection": "events",
                        "item_id": "e1",
                        "data": {"id": "e1", "subject": "x"},
                    }
                ]
            },
        ).status_code
        == 403
    )
    for side in (
        ("POST", "/api/info"),
        ("GET", "/api/google/status"),
        ("GET", "/api/canvas/status"),
        ("GET", "/api/v1/feedback/status"),
        ("POST", "/api/v1/auth/logout_all"),
    ):
        resp = client.request(side[0], side[1], headers=roh)
        assert resp.status_code == 403, (side, resp.text)


def test_google_callback_escapes_xss_and_validates_event_types(client: TestClient):
    r = client.get(
        "/api/google/callback",
        params={"error": "<script>alert(1)</script>"},
    )
    assert r.status_code == 400
    assert "<script>" not in r.text
    assert "&lt;script&gt;" in r.text
    assert "default-src 'none'" in r.headers.get("content-security-policy", "")

    h = _register(client, "sec-gtypes@example.com")
    bad_cal = client.post(
        "/api/google/events", headers=h, json={"calendarId": 123}
    )
    assert bad_cal.status_code == 400
    bad_start = client.post(
        "/api/google/events",
        headers=h,
        json={"calendarId": "primary", "allDay": True, "start": 12345},
    )
    assert bad_start.status_code == 400


def test_fernet_key_validation_and_ciphertext_guard():
    from app import oauth_store as store

    # 32 raw ASCII bytes are accepted and round-trip.
    f = store.validate_fernet_key("a" * 32)
    token = f.encrypt(b"secret").decode()
    assert token.startswith("gAAAAAB")

    # Malformed keys raise ValueError instead of silently returning None.
    with pytest.raises(ValueError):
        store.validate_fernet_key("not-a-valid-key")

    # Ciphertext is never returned raw when decryption fails.
    assert store.decrypt_secret(token) == ""


def test_rate_limiter_evicts_and_bounds_memory():
    from app.ratelimit import RateLimiter

    rl = RateLimiter()
    rl._MAX_BUCKETS = 50
    for i in range(120):
        assert rl.allowed(f"ip:{i}", 5, 10.0, now=100.0)
    assert len(rl._hits) <= 50
    # After window expiry, stale entries are evicted cleanly.
    for i in range(60):
        assert rl.allowed(f"fresh:{i}", 5, 10.0, now=200.0)
    assert len(rl._hits) <= 50
    assert all(k.startswith("fresh:") for k in rl._hits)


def test_canvas_pagination_rejects_cross_host_link(monkeypatch):
    import asyncio
    import httpx
    from app import canvas as c

    seen_urls: list[str] = []

    class FakeResp:
        status_code = 200
        headers = {"Link": '<https://evil.example.com/api/v1/planner/items?page=2>; rel="next"'}
        text = "[]"

        def json(self):
            return []

    class FakeClient:
        def __init__(self, **kw):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            pass

        async def get(self, url, headers=None, params=None):
            seen_urls.append(url)
            return FakeResp()

    monkeypatch.setattr(httpx, "AsyncClient", FakeClient)
    with pytest.raises(c.CanvasAuthError):
        asyncio.run(c.list_planner_items("byu.instructure.com", "secret-token"))
    assert seen_urls == ["https://byu.instructure.com/api/v1/planner/items"]
