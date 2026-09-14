"""Plaid proxy routes: per-user connections, client contract, error mapping.

The Plaid SDK is faked (no network); the focus is auth gating,
per-user isolation, request/response shapes the Flutter client depends
on, and that access tokens never leave the server.
"""

from __future__ import annotations

import json
import os
import tempfile
import types

import plaid
import pytest
from fastapi.testclient import TestClient

os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{tempfile.mkdtemp()}/test_plaid.db"
os.environ["JWT_SECRET"] = "test-secret"
os.environ["PLAID_CLIENT_ID"] = "test-id"
os.environ["PLAID_SECRET"] = "test-secret"
os.environ["PLAID_ENV"] = "sandbox"

from app import plaid as plaid_mod  # noqa: E402
from app.main import create_app  # noqa: E402

app = create_app()


class R(dict):
    """Plaid model stand-in: dict access + .to_dict()."""

    def to_dict(self):  # noqa: D102
        return dict(self)


class FakePlaid:
    """Minimal SDK surface used by the ported routes."""

    def sandbox_public_token_create(self, req):
        return R(public_token="public-sandbox-1")

    def item_public_token_exchange(self, req):
        return R(access_token="access-abc", item_id="item-123")

    def link_token_create(self, req):
        return R(link_token="link-xyz", expiration="x", request_id="r1")

    def auth_get(self, req):
        assert req.access_token == "access-abc"
        return R(accounts=[{"account_id": "a1"}], numbers={"ach": []})

    def transactions_sync(self, req):
        assert req.access_token == "access-abc"
        return R(
            added=[{"date": "2026-01-02", "name": "B"}, {"date": "2026-01-01", "name": "A"}],
            modified=[],
            removed=[],
            has_more=False,
            next_cursor="cursor-1",
        )

    def identity_get(self, req):
        return R(accounts=[{"account_id": "a1"}])

    def accounts_balance_get(self, req):
        return R(accounts=[{"account_id": "a1", "balances": {"current": 10}}])

    def accounts_get(self, req):
        return R(accounts=[{"account_id": "a1", "name": "Checking"}])

    def item_get(self, req):
        return R(item={"item_id": "item-123", "institution_id": "ins-1"})

    def institutions_get_by_id(self, req):
        return R(institution={"institution_id": "ins-1", "name": "Bank"})


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.setattr(plaid_mod, "get_client", lambda: FakePlaid())
    with TestClient(app) as c:
        yield c


def _register(client: TestClient, email: str) -> dict:
    r = client.post(
        "/api/v1/auth/register", json={"email": email, "password": "password123"}
    )
    assert r.status_code == 201, r.text
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


def test_routes_require_auth(client: TestClient):
    assert client.post("/api/info").status_code == 401
    assert client.get("/api/balance").status_code == 401
    assert client.get("/api/accounts").status_code == 401
    assert client.get("/api/transactions").status_code == 401
    assert client.get("/api/auth").status_code == 401
    assert client.get("/api/identity").status_code == 401
    assert client.get("/api/item").status_code == 401
    assert client.post("/api/create_link_token").status_code == 401
    assert client.post("/api/set_access_token", data={"public_token": "x"}).status_code == 401
    assert client.post("/api/disconnect").status_code == 401


def test_info_disconnected_by_default(client: TestClient, monkeypatch):
    monkeypatch.delenv("PLAID_PRODUCTS", raising=False)
    h = _register(client, "p1@example.com")
    r = client.post("/api/info", headers=h)
    assert r.status_code == 200, r.text
    assert r.json() == {
        "connected": False,
        "item_id": None,
        "products": ["transactions"],
    }


def test_exchange_connects_and_never_echoes_token(client: TestClient):
    h = _register(client, "p2@example.com")
    # Flutter sends form-encoded bodies (http.post with a Map).
    r = client.post(
        "/api/set_access_token",
        headers=h,
        data={"public_token": "public-xyz"},
    )
    assert r.status_code == 200, r.text
    assert r.json() == {"item_id": "item-123"}
    assert "access-abc" not in r.text

    info = client.post("/api/info", headers=h)
    assert info.json()["connected"] is True
    assert info.json()["item_id"] == "item-123"


def test_exchange_accepts_json_body(client: TestClient):
    h = _register(client, "p2j@example.com")
    r = client.post(
        "/api/set_access_token",
        headers=h,
        json={"public_token": "public-xyz"},
    )
    assert r.status_code == 200, r.text
    assert r.json() == {"item_id": "item-123"}


def test_exchange_missing_token_is_400(client: TestClient):
    h = _register(client, "p2m@example.com")
    r = client.post("/api/set_access_token", headers=h, data={})
    assert r.status_code == 400


def test_connections_are_per_user(client: TestClient):
    alice = _register(client, "alice-p@example.com")
    bob = _register(client, "bob-p@example.com")
    client.post("/api/set_access_token", headers=alice, data={"public_token": "p"})

    assert client.post("/api/info", headers=alice).json()["connected"] is True
    assert client.post("/api/info", headers=bob).json()["connected"] is False
    # Bob's data routes fail without his own connection.
    assert client.get("/api/balance", headers=bob).status_code == 401


def test_data_routes_shape(client: TestClient):
    h = _register(client, "p3@example.com")
    client.post("/api/set_access_token", headers=h, data={"public_token": "p"})

    link = client.post("/api/create_link_token", headers=h)
    assert link.status_code == 200, link.text
    assert link.json()["link_token"] == "link-xyz"

    balance = client.get("/api/balance", headers=h)
    assert balance.status_code == 200
    assert balance.json()["accounts"][0]["account_id"] == "a1"

    accounts = client.get("/api/accounts", headers=h)
    assert accounts.json()["accounts"][0]["name"] == "Checking"

    tx = client.get("/api/transactions", headers=h)
    assert tx.status_code == 200, tx.text
    names = [t["name"] for t in tx.json()["latest_transactions"]]
    assert names == ["A", "B"]  # sorted by date

    auth = client.get("/api/auth", headers=h)
    assert auth.json()["accounts"][0]["account_id"] == "a1"

    ident = client.get("/api/identity", headers=h)
    assert ident.json() == {"error": None, "identity": [{"account_id": "a1"}]}

    item = client.get("/api/item", headers=h)
    assert item.json()["item"]["item_id"] == "item-123"
    assert item.json()["institution"]["name"] == "Bank"


def test_disconnect_clears_connection(client: TestClient):
    h = _register(client, "p4@example.com")
    client.post("/api/set_access_token", headers=h, data={"public_token": "p"})
    assert client.post("/api/info", headers=h).json()["connected"] is True

    assert client.post("/api/disconnect", headers=h).json() == {
        "status": "disconnected"
    }
    assert client.post("/api/info", headers=h).json()["connected"] is False
    assert client.get("/api/balance", headers=h).status_code == 401


def test_sandbox_auto_connect(client: TestClient, monkeypatch):
    monkeypatch.setenv("PLAID_ENV", "sandbox")
    h = _register(client, "p5@example.com")
    r = client.post("/api/sandbox/auto_connect", headers=h)
    assert r.status_code == 200, r.text
    assert r.json() == {"status": "connected", "item_id": "item-123"}
    assert "access-abc" not in r.text


def test_sandbox_auto_connect_blocked_outside_sandbox(
    client: TestClient, monkeypatch
):
    monkeypatch.setenv("PLAID_ENV", "production")
    h = _register(client, "p6@example.com")
    r = client.post("/api/sandbox/auto_connect", headers=h)
    assert r.status_code == 400


@pytest.fixture()
def raw_client():
    """TestClient without the fake Plaid SDK (for config-error paths)."""
    with TestClient(app) as c:
        yield c


def test_missing_server_keys_are_500_not_500_html(
    raw_client: TestClient, monkeypatch
):
    monkeypatch.delenv("PLAID_CLIENT_ID", raising=False)
    monkeypatch.delenv("PLAID_SECRET", raising=False)
    h = _register(raw_client, "p7@example.com")
    r = raw_client.post("/api/create_link_token", headers=h)
    assert r.status_code == 500
    assert "PLAID_CLIENT_ID" in r.json()["error"]["message"]


def test_plaid_api_errors_keep_shape_and_status(
    client: TestClient, monkeypatch
):
    body = json.dumps(
        {
            "error_type": "INVALID_REQUEST",
            "error_code": "INVALID_PUBLIC_TOKEN",
            "error_message": "bad token",
        }
    )
    http_resp = types.SimpleNamespace(
        status=400, reason="Bad Request", data=body, getheaders=lambda: {}
    )

    class ExplodingClient(FakePlaid):
        def accounts_get(self, req):
            raise plaid.ApiException(http_resp=http_resp)

    monkeypatch.setattr(plaid_mod, "get_client", lambda: ExplodingClient())
    h = _register(client, "p8@example.com")
    client.post("/api/set_access_token", headers=h, data={"public_token": "p"})
    r = client.get("/api/accounts", headers=h)
    assert r.status_code == 400, r.text
    assert r.json()["error"]["error_code"] == "INVALID_PUBLIC_TOKEN"
    assert r.json()["error"]["status_code"] == 400


def test_link_exit_error_is_open_telemetry(client: TestClient):
    r = client.post("/api/link_exit_error", json={"error": "user closed"})
    assert r.status_code == 200
    assert r.json() == {"status": "logged"}
