"""Per-user Google OAuth + proxy routes (no network: HTTP layer faked)."""

from __future__ import annotations

import datetime as dt  # noqa: F401  (timestamp readers)
import os
import tempfile
import urllib.parse

import pytest
from cryptography.fernet import Fernet
from fastapi.testclient import TestClient

os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{tempfile.mkdtemp()}/test_google.db"
os.environ["JWT_SECRET"] = "test-secret"

from app.main import create_app  # noqa: E402
from app import google as g  # noqa: E402

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


def test_status_disconnected_by_default(client: TestClient):
    h = _register(client, "g1@example.com")
    r = client.get("/api/google/status", headers=h)
    assert r.status_code == 200
    assert r.json()["connected"] is False


def test_auth_url_needs_server_credentials(client: TestClient, monkeypatch):
    monkeypatch.delenv("GOOGLE_CLIENT_ID", raising=False)
    monkeypatch.delenv("GOOGLE_CLIENT_SECRET", raising=False)
    h = _register(client, "g2@example.com")
    r = client.get("/api/google/auth_url", headers=h)
    assert r.status_code == 500


def test_auth_url_and_callback_roundtrip(client: TestClient, monkeypatch):
    monkeypatch.setenv("GOOGLE_CLIENT_ID", "cid")
    monkeypatch.setenv("GOOGLE_CLIENT_SECRET", "csecret")
    h = _register(client, "g3@example.com")

    auth = client.get("/api/google/auth_url", headers=h)
    assert auth.status_code == 200, auth.text
    url = auth.json()["url"]
    assert "accounts.google.com" in url
    state = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)["state"][0]

    async def fake_redeem(code: str, redirect_uri: str):
        assert code == "the-code"
        return {
            "access_token": "at-1",
            "refresh_token": "rt-1",
            "expires_in": 3600,
            "scope": g.GOOGLE_SCOPE,
        }

    monkeypatch.setattr(g, "redeem_code", fake_redeem)
    cb = client.get(
        "/api/google/callback", params={"code": "the-code", "state": state}
    )
    assert cb.status_code == 200, cb.text
    assert "connected" in cb.text

    status = client.get("/api/google/status", headers=h)
    assert status.json()["connected"] is True
    assert status.json()["contactsGranted"] is True


def test_connections_are_per_user(client: TestClient, monkeypatch):
    monkeypatch.setenv("GOOGLE_CLIENT_ID", "cid")
    monkeypatch.setenv("GOOGLE_CLIENT_SECRET", "csecret")
    alice = _register(client, "alice-g@example.com")
    bob = _register(client, "bob-g@example.com")

    auth = client.get("/api/google/auth_url", headers=alice)
    state = urllib.parse.parse_qs(
        urllib.parse.urlparse(auth.json()["url"]).query
    )["state"][0]

    async def fake_redeem(code: str, redirect_uri: str):
        return {
            "access_token": "at",
            "refresh_token": "rt",
            "expires_in": 3600,
            "scope": g.GOOGLE_SCOPE,
        }

    monkeypatch.setattr(g, "redeem_code", fake_redeem)
    client.get("/api/google/callback", params={"code": "c", "state": state})

    assert client.get("/api/google/status", headers=alice).json()["connected"] is True
    assert client.get("/api/google/status", headers=bob).json()["connected"] is False

    # Bob's tampered state is rejected.
    bad = client.get(
        "/api/google/callback", params={"code": "c", "state": state + "x"}
    )
    assert bad.status_code == 400


async def _never_refresh(refresh_token: str):
    raise AssertionError("should not refresh an unexpired token")


def test_cached_token_used_without_refresh(client: TestClient, monkeypatch):
    monkeypatch.setenv("GOOGLE_CLIENT_ID", "cid")
    monkeypatch.setenv("GOOGLE_CLIENT_SECRET", "csecret")
    h = _register(client, "g4@example.com")
    auth = client.get("/api/google/auth_url", headers=h)
    state = urllib.parse.parse_qs(
        urllib.parse.urlparse(auth.json()["url"]).query
    )["state"][0]

    async def fake_redeem(code: str, redirect_uri: str):
        return {
            "access_token": "cached-at",
            "refresh_token": "rt",
            "expires_in": 3600,
            "scope": g.GOOGLE_SCOPE,
        }

    async def fake_calendars(access_token: str):
        assert access_token == "cached-at"
        return [{"id": "primary", "summary": "Main"}]

    monkeypatch.setattr(g, "redeem_code", fake_redeem)
    monkeypatch.setattr(g, "refresh_access_token", _never_refresh)
    monkeypatch.setattr(g, "list_calendars", fake_calendars)
    client.get("/api/google/callback", params={"code": "c", "state": state})

    r = client.get("/api/google/calendars", headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["calendars"][0]["id"] == "primary"


def test_expired_token_refreshes(client: TestClient, monkeypatch):
    monkeypatch.setenv("GOOGLE_CLIENT_ID", "cid")
    monkeypatch.setenv("GOOGLE_CLIENT_SECRET", "csecret")
    h = _register(client, "g5@example.com")
    auth = client.get("/api/google/auth_url", headers=h)
    state = urllib.parse.parse_qs(
        urllib.parse.urlparse(auth.json()["url"]).query
    )["state"][0]

    async def fake_redeem(code: str, redirect_uri: str):
        # Already-expired access token forces the refresh path.
        return {
            "access_token": "stale-at",
            "refresh_token": "rt-5",
            "expires_in": -100,
            "scope": g.GOOGLE_SCOPE,
        }

    async def fake_refresh(refresh_token: str):
        assert refresh_token == "rt-5"
        return ("fresh-at", 9999999999.0)

    async def fake_calendars(access_token: str):
        assert access_token == "fresh-at"
        return []

    monkeypatch.setattr(g, "redeem_code", fake_redeem)
    monkeypatch.setattr(g, "refresh_access_token", fake_refresh)
    monkeypatch.setattr(g, "list_calendars", fake_calendars)
    client.get("/api/google/callback", params={"code": "c", "state": state})

    r = client.get("/api/google/calendars", headers=h)
    assert r.status_code == 200, r.text


def test_fernet_roundtrip(monkeypatch):
    from app import oauth_store as store

    # A generated key is valid Fernet material.
    assert Fernet(Fernet.generate_key())
    # With the dev .env key loaded, secrets encrypt and round-trip;
    # without any key they pass through (dev only).
    assert store.decrypt_secret(store.encrypt_secret("abc")) == "abc"
    assert store.decrypt_secret("") == ""
    assert store.encrypt_secret("") == ""
