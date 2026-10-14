"""Authenticated AnkiConnect proxy (upstream faked, no network)."""

from __future__ import annotations

import os
import tempfile

import pytest
from fastapi.testclient import TestClient

os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{tempfile.mkdtemp()}/test_anki.db"
os.environ["JWT_SECRET"] = "test-secret"

from app import anki as a  # noqa: E402
from app.main import create_app  # noqa: E402

app = create_app()


@pytest.fixture()
def client():
    with TestClient(app) as cl:
        yield cl


def _register(client: TestClient, email: str) -> dict:
    r = client.post(
        "/api/v1/auth/register", json={"email": email, "password": "password123"}
    )
    assert r.status_code == 201, r.text
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


def _ok(result):
    async def fake_invoke(action: str, params: dict):
        return result

    return fake_invoke


def test_requires_auth(client: TestClient):
    r = client.post("/api/anki/invoke", json={"action": "deckNames"})
    assert r.status_code == 401, r.text


def test_allowlists_actions(client: TestClient):
    h = _register(client, "a1@example.com")
    for bad in ["", "addNote", "DECKNAMES", "deckNames "[:-1] + "x"]:
        r = client.post("/api/anki/invoke", json={"action": bad}, headers=h)
        assert r.status_code == 400, (bad, r.text)


def test_deck_names_passthrough(client: TestClient, monkeypatch):
    h = _register(client, "a2@example.com")
    seen = {}

    async def fake_invoke(action: str, params: dict):
        seen["action"] = action
        seen["params"] = params
        return ["Default", "Japanese"]

    monkeypatch.setattr(a, "invoke", fake_invoke)
    r = client.post("/api/anki/invoke", json={"action": "deckNames"}, headers=h)
    assert r.status_code == 200, r.text
    assert r.json() == {"result": ["Default", "Japanese"]}
    assert seen == {"action": "deckNames", "params": {}}


def test_deck_names_rejects_params(client: TestClient):
    h = _register(client, "a3@example.com")
    r = client.post(
        "/api/anki/invoke",
        json={"action": "deckNames", "params": {"x": 1}},
        headers=h,
    )
    assert r.status_code == 400, r.text


def test_find_cards_rebuilds_params(client: TestClient, monkeypatch):
    h = _register(client, "a4@example.com")
    seen = {}

    async def fake_invoke(action: str, params: dict):
        seen["action"] = action
        seen["params"] = params
        return [1, 2, 3]

    monkeypatch.setattr(a, "invoke", fake_invoke)
    r = client.post(
        "/api/anki/invoke",
        json={
            "action": "findCards",
            "params": {"query": 'deck:"Japanese" rated:1', "smuggled": True},
        },
        headers=h,
    )
    assert r.status_code == 200, r.text
    assert r.json() == {"result": [1, 2, 3]}
    # Extra keys are dropped; only the validated query is forwarded.
    assert seen == {
        "action": "findCards",
        "params": {"query": 'deck:"Japanese" rated:1'},
    }


def test_find_cards_validates_query(client: TestClient):
    h = _register(client, "a5@example.com")
    for params in [{}, {"query": ""}, {"query": "  "}, {"query": 42}]:
        r = client.post(
            "/api/anki/invoke",
            json={"action": "findCards", "params": params},
            headers=h,
        )
        assert r.status_code == 400, (params, r.text)
    r = client.post(
        "/api/anki/invoke",
        json={"action": "findCards", "params": {"query": "x" * 501}},
        headers=h,
    )
    assert r.status_code == 400, r.text


def test_sync_action_allowed(client: TestClient, monkeypatch):
    h = _register(client, "a6@example.com")
    monkeypatch.setattr(a, "invoke", _ok(None))
    r = client.post("/api/anki/invoke", json={"action": "sync"}, headers=h)
    assert r.status_code == 200, r.text
    assert r.json() == {"result": None}


def test_upstream_failure_is_502(client: TestClient, monkeypatch):
    h = _register(client, "a7@example.com")

    async def fake_invoke(action: str, params: dict):
        raise a.AnkiUpstreamError("Anki is unreachable: boom")

    monkeypatch.setattr(a, "invoke", fake_invoke)
    r = client.post("/api/anki/invoke", json={"action": "deckNames"}, headers=h)
    assert r.status_code == 502, r.text
    assert "unreachable" in r.json()["detail"]
