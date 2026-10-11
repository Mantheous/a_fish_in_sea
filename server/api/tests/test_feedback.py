"""Feedback: pending queue, trusted auto-file, admin approve/deny."""

from __future__ import annotations

import os
import tempfile

import pytest
from fastapi.testclient import TestClient

os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{tempfile.mkdtemp()}/test.db"
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
    assert r.status_code == 201, r.text
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
    return github_issues.FiledIssue(number=42, url="https://x/42")


async def _boom(**kw):
    raise RuntimeError("no token")


def test_untrusted_goes_pending_and_admin_approves(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
):
    admin = _register(client, "fb-admin@example.com")
    user = _register(client, "fb-user@example.com")

    r = client.post("/api/v1/feedback", headers=_auth(user), json=_report())
    assert r.status_code == 201, r.text
    assert r.json()["status"] == "pending"
    rid = r.json()["id"]

    # non-admin cannot see the queue
    q = client.get("/api/v1/feedback/pending", headers=_auth(user))
    assert q.status_code == 403

    q = client.get("/api/v1/feedback/pending", headers=_auth(admin))
    assert q.status_code == 200
    assert any(x["id"] == rid for x in q.json())

    # approve with fake GitHub success + trust the reporter
    monkeypatch.setattr(feedback_router, "create_issue", _fake_filed)
    a = client.post(
        f"/api/v1/feedback/{rid}/approve",
        headers=_auth(admin),
        json={"trust_user": True},
    )
    assert a.status_code == 200, a.text
    assert a.json()["status"] == "filed"
    assert a.json()["github_issue_number"] == 42

    # trusted now: next report files immediately
    monkeypatch.setattr(feedback_router, "create_issue", _fake_filed)
    r2 = client.post(
        "/api/v1/feedback",
        headers=_auth(user),
        json=_report(title="Second bug", kind="feature"),
    )
    assert r2.json()["status"] == "filed"


def test_deny_and_trusted_management(client: TestClient):
    admin = _register(client, "fb-root2@example.com")
    plain = _register(client, "fb-plain@example.com")
    user = _register(client, "fb-user2@example.com")

    r = client.post("/api/v1/feedback", headers=_auth(user), json=_report())
    rid = r.json()["id"]
    d = client.post(
        f"/api/v1/feedback/{rid}/deny",
        headers=_auth(admin),
        json={"reason": "duplicate"},
    )
    assert d.status_code == 200
    assert d.json()["status"] == "denied"

    # non-admin trusted management is forbidden
    assert (
        client.post(
            "/api/v1/feedback/trusted",
            headers=_auth(plain),
            json={"email": "fb-user2@example.com"},
        ).status_code
        == 403
    )
    t = client.post(
        "/api/v1/feedback/trusted",
        headers=_auth(admin),
        json={"email": "fb-user2@example.com"},
    )
    assert t.status_code == 201, t.text
    assert (
        client.post(
            "/api/v1/feedback/trusted",
            headers=_auth(admin),
            json={"email": "fb-user2@example.com"},
        ).status_code
        == 409
    )
    lst = client.get("/api/v1/feedback/trusted", headers=_auth(admin))
    assert any(x["email"] == "fb-user2@example.com" for x in lst.json())
    rm = client.delete(
        "/api/v1/feedback/trusted/fb-user2@example.com",
        headers=_auth(admin),
    )
    assert rm.status_code == 200


def test_github_failure_stays_pending(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
):
    user = _register(client, "fb-failuser@example.com")
    admin = _register(client, "fb-root3@example.com")

    r = client.post("/api/v1/feedback", headers=_auth(user), json=_report())
    rid = r.json()["id"]

    monkeypatch.setattr(feedback_router, "create_issue", _boom)
    a = client.post(
        f"/api/v1/feedback/{rid}/approve",
        headers=_auth(admin),
        json={},
    )
    assert a.status_code == 502

    mine = client.get("/api/v1/feedback/mine", headers=_auth(user)).json()
    assert mine[0]["status"] == "pending"


def test_issue_body_matches_templates():
    bug = github_issues.build_issue_body(
        kind="bug",
        description="It crashes",
        device="Android mantheous-a16",
        extra="log here",
        reporter_email="u@example.com",
    )
    assert "Device / target" in bug
    assert "u@example.com" in bug
    assert "Auto-approved" in bug
    feat = github_issues.build_issue_body(
        kind="feature",
        description="Need X",
        device="",
        extra="Add a button",
        reporter_email="u@example.com",
    )
    assert "Proposed change" in feat
    assert "Auto-approved" not in feat


def test_label_policy_bugs_auto_approved():
    # Bugs skip manual approval (builder fixes automatically);
    # features go through triage + manual approval.
    assert "agent-approved" in github_issues.ISSUE_LABELS["bug"]
    assert "agent-pending" not in github_issues.ISSUE_LABELS["bug"]
    assert "agent-pending" in github_issues.ISSUE_LABELS["feature"]
    assert "agent-approved" not in github_issues.ISSUE_LABELS["feature"]
