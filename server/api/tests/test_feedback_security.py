"""Feedback trust gate: only approved users file GitHub issues directly.

Regression cover for the untrusted-user → GitHub → builder RCE path:
- Untrusted bug/feature reports stay `pending` and never call GitHub.
- Non-admins get 403 on pending/approve/deny/trusted management.
- Approving WITHOUT trust_user does not add to the allowlist.
- Approving WITH trust_user adds exactly once; trusted reporters auto-file.
- Trust matching is case-insensitive (server lowercases).
"""

from __future__ import annotations

import os
import tempfile

import pytest
from fastapi.testclient import TestClient

os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{tempfile.mkdtemp()}/test_fbsec.db"
os.environ["JWT_SECRET"] = "test-secret"
os.environ["ADMIN_EMAILS"] = "fb-admin@example.com,fb-root2@example.com,fb-root3@example.com"

from app import github_issues  # noqa: E402
from app.config import get_settings  # noqa: E402
from app.routers import feedback as feedback_router  # noqa: E402

get_settings.cache_clear()  # re-read env: ADMIN_EMAILS must apply in-process

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
    if r.status_code == 409:
        # Shared DB when the whole suite runs together (settings are
        # cached from the first-imported test module): log in instead.
        r = client.post(
            "/api/v1/auth/login", json={"email": email, "password": "password123"}
        )
    assert r.status_code in (200, 201), r.text
    return r.json()


def _auth(tokens: dict) -> dict:
    return {"Authorization": f"Bearer {tokens['access_token']}"}


def _report(**kw) -> dict:
    base = {
        "kind": "bug",
        "title": "Crash on launch",
        "description": "Steps: open app, it crashes.",
        "device": "Android",
        "extra": "",
    }
    base.update(kw)
    return base


async def _fake_filed(**kw):
    return github_issues.FiledIssue(number=99, url="https://x/99")


async def _must_not_file(**kw):
    raise AssertionError("untrusted submit must not reach GitHub")


def test_untrusted_bug_stays_pending_without_github_call(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
):
    user = _register(client, "secx-stranger@example.com")
    monkeypatch.setattr(feedback_router, "create_issue", _must_not_file)
    r = client.post("/api/v1/feedback", headers=_auth(user), json=_report())
    assert r.status_code == 201, r.text
    assert r.json()["status"] == "pending"
    assert r.json()["github_issue_number"] is None


def test_non_admin_cannot_approve_deny_or_manage_trust(client: TestClient):
    admin = _register(client, "fb-admin@example.com")
    plain = _register(client, "secx-plain@example.com")
    user = _register(client, "secx-victim@example.com")

    r = client.post("/api/v1/feedback", headers=_auth(user), json=_report())
    rid = r.json()["id"]

    assert (
        client.post(
            f"/api/v1/feedback/{rid}/approve", headers=_auth(plain), json={}
        ).status_code
        == 403
    )
    assert (
        client.post(
            f"/api/v1/feedback/{rid}/deny",
            headers=_auth(plain),
            json={"reason": "no"},
        ).status_code
        == 403
    )
    assert (
        client.get("/api/v1/feedback/pending", headers=_auth(plain)).status_code
        == 403
    )
    assert (
        client.get("/api/v1/feedback/trusted", headers=_auth(plain)).status_code
        == 403
    )
    assert (
        client.delete(
            "/api/v1/feedback/trusted/secx-victim@example.com",
            headers=_auth(plain),
        ).status_code
        == 403
    )
    # admin can still see it (proves the report exists and is pending)
    q = client.get("/api/v1/feedback/pending", headers=_auth(admin))
    assert q.status_code == 200
    assert any(x["id"] == rid for x in q.json())


def test_approve_without_trust_does_not_allowlist(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
):
    admin = _register(client, "fb-root2@example.com")
    user = _register(client, "secx-once@example.com")

    r = client.post("/api/v1/feedback", headers=_auth(user), json=_report())
    rid = r.json()["id"]

    monkeypatch.setattr(feedback_router, "create_issue", _fake_filed)
    a = client.post(
        f"/api/v1/feedback/{rid}/approve", headers=_auth(admin), json={}
    )
    assert a.status_code == 200, a.text
    assert a.json()["status"] == "filed"

    # allowlist must NOT contain this reporter (trust defaults off)
    lst = client.get("/api/v1/feedback/trusted", headers=_auth(admin)).json()
    assert not any(
        x["email"] == "secx-once@example.com" for x in lst
    ), "approve without trust_user must not trust"

    # next report still goes to review
    monkeypatch.setattr(feedback_router, "create_issue", _must_not_file)
    r2 = client.post(
        "/api/v1/feedback",
        headers=_auth(user),
        json=_report(title="Second bug"),
    )
    assert r2.json()["status"] == "pending"


def test_explicit_trust_grants_direct_file_case_insensitive(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
):
    admin = _register(client, "fb-root3@example.com")
    user = _register(client, "secx-friend@example.com")

    # admin trusts with different casing; server normalizes to lowercase
    t = client.post(
        "/api/v1/feedback/trusted",
        headers=_auth(admin),
        json={"email": "SECX-Friend@Example.COM"},
    )
    assert t.status_code == 201, t.text
    assert t.json()["email"] == "secx-friend@example.com"

    status = client.get("/api/v1/feedback/status", headers=_auth(user)).json()
    assert status["is_trusted"] is True
    assert status["is_admin"] is False

    monkeypatch.setattr(feedback_router, "create_issue", _fake_filed)
    r = client.post(
        "/api/v1/feedback", headers=_auth(user), json=_report(title="Trusted bug")
    )
    assert r.json()["status"] == "filed"
    assert r.json()["github_issue_number"] == 99
