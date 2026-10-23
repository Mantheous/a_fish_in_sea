"""Strava fitness proxy: JWT-only, per-user tokens, real OAuth state.

/api/fitness/* stores per-user Strava OAuth secrets via oauth_store.
Long-lived API tokens (scoped or review-only) must never read, write,
or clear those secrets — only an interactive JWT may.
"""

from __future__ import annotations

import datetime as dt
import os
import tempfile
import urllib.parse

import httpx
import pytest
from fastapi.testclient import TestClient

os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{tempfile.mkdtemp()}/test_fitness.db"
os.environ["JWT_SECRET"] = "test-secret"

from app.main import create_app  # noqa: E402
from app.routers import fitness as fitness_router  # noqa: E402
from app import strava  # noqa: E402

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


def _auth_url_state(client: TestClient, h: dict) -> str:
    r = client.get("/api/fitness/auth_url", headers=h)
    assert r.status_code == 200, r.text
    url = urllib.parse.urlparse(r.json()["url"])
    return urllib.parse.parse_qs(url.query)["state"][0]


def test_review_token_cannot_touch_fitness(client: TestClient):
    h = _register(client, "fit-review@example.com")
    review = _mint(client, h, "reviewer", ["sync"], True)

    assert client.get("/api/fitness/status", headers=review).status_code == 403
    assert client.get("/api/fitness/auth_url", headers=review).status_code == 403
    assert client.get("/api/fitness/activities", headers=review).status_code == 403
    assert client.post("/api/fitness/disconnect", headers=review).status_code == 403
    # The old scaffold took a raw token from anyone; that door is gone.
    assert (
        client.post(
            "/api/fitness/connect",
            headers=review,
            json={"access_token": "attacker-value"},
        ).status_code
        in (403, 404)
    )


def test_scoped_token_cannot_touch_fitness(client: TestClient):
    h = _register(client, "fit-scoped@example.com")
    scoped = _mint(client, h, "scoped", ["nodes:read"], False)

    assert client.get("/api/fitness/status", headers=scoped).status_code == 403
    assert (
        client.get("/api/fitness/activities", headers=scoped).status_code == 403
    )
    assert client.post("/api/fitness/disconnect", headers=scoped).status_code == 403


def test_status_reports_unconfigured_server(client: TestClient, monkeypatch):
    monkeypatch.delenv("STRAVA_CLIENT_ID", raising=False)
    monkeypatch.delenv("STRAVA_CLIENT_SECRET", raising=False)
    h = _register(client, "fit-unconfigured@example.com")

    status = client.get("/api/fitness/status", headers=h)
    assert status.status_code == 200, status.text
    body = status.json()
    assert body["provider"] == "strava"
    assert body["connected"] is False
    assert body["configured"] is False
    assert body["supportsSleep"] is False
    assert body["redirectUri"].endswith("/api/fitness/callback")


def test_auth_url_needs_setup_without_credentials(client: TestClient, monkeypatch):
    monkeypatch.delenv("STRAVA_CLIENT_ID", raising=False)
    monkeypatch.delenv("STRAVA_CLIENT_SECRET", raising=False)
    h = _register(client, "fit-needs-setup@example.com")

    r = client.get("/api/fitness/auth_url", headers=h)
    assert r.status_code == 503, r.text
    detail = r.json()["detail"]
    assert detail["needsSetup"] is True
    assert detail["redirectUri"].endswith("/api/fitness/callback")


def test_connect_flow_stores_tokens_and_disconnects(
    client: TestClient, monkeypatch
):
    monkeypatch.setenv("STRAVA_CLIENT_ID", "1234")
    monkeypatch.setenv("STRAVA_CLIENT_SECRET", "shh")
    monkeypatch.setenv(
        "STRAVA_REDIRECT_URI", "https://example.test/fish/api/fitness/callback"
    )
    h = _register(client, "fit-jwt@example.com")

    state = _auth_url_state(client, h)

    async def fake_redeem(code: str, redirect_uri: str) -> dict:
        assert code == "the-code"
        assert redirect_uri == "https://example.test/fish/api/fitness/callback"
        return {
            "access_token": "at-1",
            "refresh_token": "rt-1",
            "expires_at": 2000000000,
            "athlete": {"id": 99, "firstname": "Ash", "lastname": "Runner"},
        }

    async def fake_deauthorize(token: str) -> None:
        assert token == "at-1"

    monkeypatch.setattr(strava, "redeem_code", fake_redeem)
    monkeypatch.setattr(strava, "deauthorize", fake_deauthorize)

    cb = client.get(
        "/api/fitness/callback", params={"code": "the-code", "state": state}
    )
    assert cb.status_code == 200, cb.text
    assert "Strava connected" in cb.text

    status = client.get("/api/fitness/status", headers=h)
    assert status.status_code == 200, status.text
    body = status.json()
    assert body["connected"] is True
    assert body["configured"] is True
    assert body["athlete"] == "Ash Runner"

    # A second user never sees the first user's connection.
    other = _register(client, "fit-other@example.com")
    assert client.get("/api/fitness/status", headers=other).json()["connected"] is False

    disconnect = client.post("/api/fitness/disconnect", headers=h)
    assert disconnect.status_code == 200, disconnect.text
    assert client.get("/api/fitness/status", headers=h).json()["connected"] is False


def test_callback_rejects_forged_state(client: TestClient, monkeypatch):
    monkeypatch.setenv("STRAVA_CLIENT_ID", "1234")
    monkeypatch.setenv("STRAVA_CLIENT_SECRET", "shh")
    h = _register(client, "fit-forged@example.com")
    _auth_url_state(client, h)  # ensures credentials look fine

    cb = client.get(
        "/api/fitness/callback", params={"code": "x", "state": "not-a-jwt"}
    )
    assert cb.status_code == 400
    assert "expired" in cb.text.lower()


def test_activities_map_strava_payloads(client: TestClient, monkeypatch):
    h = _register(client, "fit-activities@example.com")

    async def fake_token(session, user_id):
        return "at"

    async def fake_list(token, after, before):
        assert token == "at"
        assert after < before
        return [
            {
                "id": "strava:1",
                "type": "run",
                "name": "Morning run",
                "start": "2026-10-20T13:00:00+00:00",
                "end": "2026-10-20T13:30:00+00:00",
                "minutes": 30.0,
                "distanceMeters": 5000.0,
                "provider": "strava",
            }
        ]

    monkeypatch.setattr(fitness_router, "_access_token", fake_token)
    monkeypatch.setattr(strava, "list_activities", fake_list)

    r = client.get("/api/fitness/activities?days=7", headers=h)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["connected"] is True
    assert body["activities"][0]["type"] == "run"
    assert body["activities"][0]["minutes"] == 30.0


def test_activities_needs_reconnect(client: TestClient, monkeypatch):
    h = _register(client, "fit-reconnect@example.com")

    async def fake_token(session, user_id):
        raise strava.StravaAuthError("Strava connection needs renewal", status=401)

    monkeypatch.setattr(fitness_router, "_access_token", fake_token)

    r = client.get("/api/fitness/activities", headers=h)
    assert r.status_code == 401, r.text
    assert r.json()["detail"]["needsReconnect"] is True


def test_sleep_is_explicitly_unsupported(client: TestClient):
    h = _register(client, "fit-sleep@example.com")
    r = client.get("/api/fitness/sleep", headers=h)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["supported"] is False
    assert body["sleep"] == []


def test_activity_mapping_uses_moving_time_and_sport_alias():
    mapped = strava._activity(
        {
            "id": 42,
            "sport_type": "VirtualRun",
            "name": "Treadmill",
            "start_date": "2026-10-20T13:00:00Z",
            "moving_time": 1800,
            "elapsed_time": 2400,
            "distance": 5000,
        }
    )
    assert mapped is not None
    assert mapped["id"] == "strava:42"
    assert mapped["type"] == "run"
    assert mapped["minutes"] == 30.0
    assert mapped["provider"] == "strava"
    assert mapped["end"] > mapped["start"]


def test_activity_mapping_skips_zero_duration():
    assert (
        strava._activity(
            {"id": 1, "sport_type": "Ride", "start_date": "2026-10-20T13:00:00Z"}
        )
        is None
    )


async def _fake_activities(token, after, before):
    return []


def test_list_activities_pages_and_sorts(monkeypatch):
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request)
        assert request.headers["Authorization"] == "Bearer token"
        if len(calls) == 1:
            return httpx.Response(
                200,
                json=[
                    {
                        "id": 2,
                        "sport_type": "Ride",
                        "start_date": "2026-10-21T10:00:00Z",
                        "moving_time": 3600,
                    },
                    {
                        "id": 1,
                        "sport_type": "Run",
                        "start_date": "2026-10-20T10:00:00Z",
                        "moving_time": 600,
                    },
                ],
            )
        return httpx.Response(200, json=[])

    transport = httpx.MockTransport(handler)
    real_client = httpx.AsyncClient

    def fake_client(*args, **kwargs):
        return real_client(transport=transport)

    monkeypatch.setattr(strava.httpx, "AsyncClient", fake_client)

    import asyncio

    out = asyncio.run(
        strava.list_activities(
            "token",
            dt.datetime(2026, 10, 1, tzinfo=dt.timezone.utc),
            dt.datetime(2026, 10, 23, tzinfo=dt.timezone.utc),
        )
    )
    assert [a["id"] for a in out] == ["strava:1", "strava:2"]
