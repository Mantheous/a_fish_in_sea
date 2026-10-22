"""Per-user Canvas token proxy (no network: Canvas API layer faked)."""

from __future__ import annotations

import os
import tempfile

import pytest
from fastapi.testclient import TestClient

os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{tempfile.mkdtemp()}/test_canvas.db"
os.environ["JWT_SECRET"] = "test-secret"

from app.main import create_app  # noqa: E402
from app import canvas as c  # noqa: E402

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


def _connect(client: TestClient, monkeypatch, email: str, host="byu.instructure.com"):
    h = _register(client, email)

    async def fake_verify(host_arg: str, token: str):
        assert host_arg == host
        assert token == "good-token"
        return {"id": 1, "name": "Test"}

    monkeypatch.setattr(c, "verify_token", fake_verify)
    r = client.post(
        "/api/canvas/connect", json={"token": "good-token", "host": host}, headers=h
    )
    assert r.status_code == 200, r.text
    return h


def test_status_disconnected_by_default(client: TestClient):
    h = _register(client, "c1@example.com")
    r = client.get("/api/canvas/status", headers=h)
    assert r.status_code == 200
    assert r.json() == {"connected": False, "host": None}


def test_host_allowlist_rejects_arbitrary_hosts(client: TestClient):
    h = _register(client, "c2@example.com")
    r = client.post(
        "/api/canvas/connect",
        json={"token": "x", "host": "https://evil.example.com/steal"},
        headers=h,
    )
    assert r.status_code == 400, r.text


def test_connect_rejects_bad_token(client: TestClient, monkeypatch):
    h = _register(client, "c3@example.com")

    async def fake_verify(host: str, token: str):
        raise c.CanvasAuthError("Canvas rejected the token", status=401)

    monkeypatch.setattr(c, "verify_token", fake_verify)
    r = client.post(
        "/api/canvas/connect",
        json={"token": "bad", "host": "byu.instructure.com"},
        headers=h,
    )
    assert r.status_code == 401, r.text
    body = r.json()["detail"]
    assert body["needsReconnect"] is True

    # Still disconnected afterwards.
    assert client.get("/api/canvas/status", headers=h).json()["connected"] is False


def test_connect_status_submissions_disconnect_roundtrip(
    client: TestClient, monkeypatch
):
    h = _connect(client, monkeypatch, "c4@example.com")

    status = client.get("/api/canvas/status", headers=h)
    assert status.json() == {"connected": True, "host": "byu.instructure.com"}

    async def fake_items(host: str, token: str, start=None, end=None, max_pages=10):
        assert host == "byu.instructure.com"
        assert token == "good-token"
        return [
            {
                "assignment_id": 1474426,
                "course_id": 1,
                "title": "Networking Kickoff",
                "due_at": "2026-09-11T21:00:00Z",
                "submitted": True,
                "excused": False,
                "graded": False,
                "missing": False,
                "late": False,
            }
        ]

    monkeypatch.setattr(c, "list_planner_items", fake_items)
    r = client.get("/api/canvas/submissions", headers=h)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["host"] == "byu.instructure.com"
    assert len(body["submissions"]) == 1
    assert body["submissions"][0]["assignment_id"] == 1474426
    assert body["submissions"][0]["submitted"] is True

    d = client.post("/api/canvas/disconnect", headers=h)
    assert d.status_code == 200
    assert client.get("/api/canvas/status", headers=h).json()["connected"] is False


def test_connections_are_per_user(client: TestClient, monkeypatch):
    alice = _connect(client, monkeypatch, "alice-c@example.com")
    bob = _register(client, "bob-c@example.com")
    assert client.get("/api/canvas/status", headers=alice).json()["connected"] is True
    assert client.get("/api/canvas/status", headers=bob).json()["connected"] is False


def test_disconnected_submissions_prompt_reconnect(client: TestClient):
    h = _register(client, "c5@example.com")
    r = client.get("/api/canvas/submissions", headers=h)
    assert r.status_code == 401, r.text
    body = r.json()["detail"]
    assert body["needsReconnect"] is True


def test_validate_host():
    assert c.validate_host("byu.instructure.com") == "byu.instructure.com"
    assert c.validate_host("https://byu.instructure.com/") == "byu.instructure.com"
    assert c.validate_host("BYU.Instructure.com") == "byu.instructure.com"
    for bad in ("evil.com", "instructure.com", "byu.instructure.com.evil.com", "", "http://127.0.0.1:8000"):
        try:
            c.validate_host(bad)
        except c.CanvasAuthError:
            continue
        raise AssertionError(f"host accepted: {bad!r}")


def test_normalize_planner_item():
    item = {
        "plannable_type": "assignment",
        "plannable_id": 1474426,
        "course_id": 42,
        "submissions": {
            "submitted": True,
            "excused": False,
            "graded": False,
            "missing": False,
            "late": False,
        },
        "plannable": {"title": "Networking Kickoff", "due_at": "2026-09-11T21:00:00Z"},
    }
    out = c.normalize_planner_item(item)
    assert out is not None
    assert out["assignment_id"] == 1474426
    assert out["submitted"] is True
    # Non-assignments and boolean submissions carry no state.
    assert c.normalize_planner_item({**item, "plannable_type": "announcement"}) is None
    assert c.normalize_planner_item({**item, "submissions": False}) is None
    assert c.normalize_planner_item({}) is None


def test_assignment_detail_roundtrip(client: TestClient, monkeypatch):
    h = _connect(client, monkeypatch, "c6@example.com")
    seen: dict = {}

    async def fake_get_assignment(host, token, assignment_id, course_id=None):
        seen.update(
            host=host, token=token, assignment_id=assignment_id, course_id=course_id
        )
        return {
            "assignment_id": assignment_id,
            "course_id": course_id or 7,
            "title": "Essay 2",
            "description": "<p>Write 800 words.</p>",
            "html_url": "https://byu.instructure.com/courses/7/assignments/99",
            "due_at": "2026-10-20T23:59:00Z",
            "points_possible": 100,
        }

    monkeypatch.setattr(c, "get_assignment", fake_get_assignment)
    r = client.get("/api/canvas/assignment/99", headers=h)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["assignment_id"] == 99
    assert body["assignment"]["description"] == "<p>Write 800 words.</p>"
    # Flattened for callers that read fields at the top level.
    assert body["description"] == "<p>Write 800 words.</p>"
    assert body["html_url"].endswith("/assignments/99")
    assert seen["course_id"] is None

    r = client.get("/api/canvas/assignment/99?course_id=7", headers=h)
    assert r.status_code == 200, r.text
    assert seen["course_id"] == 7

    # In-course path variants resolve the same helper.
    r = client.get("/api/canvas/courses/7/assignments/99", headers=h)
    assert r.status_code == 200, r.text
    assert seen["course_id"] == 7


def test_assignment_detail_not_found_and_disconnected(
    client: TestClient, monkeypatch
):
    h = _connect(client, monkeypatch, "c7@example.com")

    async def fake_missing(host, token, assignment_id, course_id=None):
        raise c.CanvasAuthError("Assignment not found", status=404)

    monkeypatch.setattr(c, "get_assignment", fake_missing)
    r = client.get("/api/canvas/assignment/12345", headers=h)
    assert r.status_code == 404, r.text

    outsider = _register(client, "c8@example.com")
    r = client.get("/api/canvas/assignment/99", headers=outsider)
    assert r.status_code == 401, r.text
    assert r.json()["detail"]["needsReconnect"] is True


class _FakeResp:
    def __init__(self, payload, status_code=200):
        self._payload = payload
        self.status_code = status_code
        self.text = str(payload)
        self.headers = {}

    def json(self):
        return self._payload


class _FakeHttpx:
    """Stands in for httpx.AsyncClient; records GET URLs."""

    instances: list = []

    def __init__(self, *args, **kwargs):
        self.calls: list = []
        _FakeHttpx.instances.append(self)

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        return False

    async def get(self, url, headers=None, params=None):
        self.calls.append(url)
        if url.endswith("/api/v1/courses/7/assignments/99"):
            return _FakeResp(
                {
                    "id": 99,
                    "course_id": 7,
                    "name": "Essay 2",
                    "description": "<p>Write.</p>",
                    "html_url": "https://byu.instructure.com/x/99",
                    "due_at": None,
                    "points_possible": 10,
                }
            )
        return _FakeResp({"error": "nope"}, status_code=404)


def test_get_assignment_direct_course(monkeypatch):
    import asyncio

    _FakeHttpx.instances.clear()
    monkeypatch.setattr(c.httpx, "AsyncClient", _FakeHttpx)
    out = asyncio.run(c.get_assignment("byu.instructure.com", "tok", 99, 7))
    assert out["assignment_id"] == 99
    assert out["course_id"] == 7
    assert out["description"] == "<p>Write.</p>"
    assert _FakeHttpx.instances[0].calls == [
        "https://byu.instructure.com/api/v1/courses/7/assignments/99"
    ]
