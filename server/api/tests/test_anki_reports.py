"""Anki add-on ingest + review reads (no network, temp SQLite)."""

from __future__ import annotations

import datetime as dt
import importlib.util
import io
import json
import os
import tempfile
import zipfile
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

os.environ["DATABASE_URL"] = (
    f"sqlite+aiosqlite:///{tempfile.mkdtemp()}/test_anki_reports.db"
)
os.environ["JWT_SECRET"] = "test-secret"

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


def _token(client: TestClient, jwt: dict, scopes: list[str]) -> dict:
    r = client.post(
        "/api/v1/tokens",
        json={"name": "anki", "scopes": scopes},
        headers=jwt,
    )
    assert r.status_code == 201, r.text
    return {"Authorization": f"Bearer {r.json()['token']}"}


def _report(days: list[dict], client: str = "test/1.0") -> dict:
    return {"version": 1, "client": client, "days": days}


def _day(offset: int = 0) -> str:
    return (dt.date.today() + dt.timedelta(days=offset)).isoformat()


def test_report_requires_auth(client: TestClient):
    r = client.post("/api/v1/anki/report", json=_report([]))
    assert r.status_code == 401, r.text


def test_report_accepts_anki_write_token(client: TestClient):
    jwt = _register(client, "anki1@example.com")
    tok = _token(client, jwt, ["anki:write"])
    r = client.post(
        "/api/v1/anki/report",
        json=_report(
            [
                {"day": _day(), "deck": "Japanese", "cards": 12, "reviews": 18},
                {"day": _day(), "deck": "Japanese::Vocab", "cards": 3, "reviews": 4},
            ]
        ),
        headers=tok,
    )
    assert r.status_code == 200, r.text
    assert r.json()["accepted"] == 2
    assert r.json()["ok"] is True


def test_sync_token_can_report_but_anki_token_cannot_read(client: TestClient):
    jwt = _register(client, "anki2@example.com")
    sync = _token(client, jwt, ["sync"])
    narrow = _token(client, jwt, ["anki:write"])
    body = _report([{"day": _day(), "deck": "Deck", "cards": 1, "reviews": 1}])
    assert client.post("/api/v1/anki/report", json=body, headers=sync).status_code == 200
    # The narrow token is ingest-only: it must not read review history.
    r = client.get("/api/v1/anki/reviews", headers=narrow)
    assert r.status_code == 403, r.text
    assert client.get("/api/v1/anki/reviews", headers=sync).status_code == 200


def test_reviews_are_per_user(client: TestClient):
    a = _register(client, "anki3@example.com")
    b = _register(client, "anki4@example.com")
    ta = _token(client, a, ["anki:write"])
    tb = _token(client, b, ["anki:write"])
    client.post(
        "/api/v1/anki/report",
        json=_report([{"day": _day(), "deck": "A", "cards": 9, "reviews": 9}]),
        headers=ta,
    )
    client.post(
        "/api/v1/anki/report",
        json=_report([{"day": _day(), "deck": "B", "cards": 4, "reviews": 4}]),
        headers=tb,
    )
    ra = client.get("/api/v1/anki/reviews", headers=a)
    rb = client.get("/api/v1/anki/reviews", headers=b)
    assert [d["deck"] for d in ra.json()["days"]] == ["A"]
    assert [d["deck"] for d in rb.json()["days"]] == ["B"]


def test_reports_are_idempotent_and_keep_max(client: TestClient):
    jwt = _register(client, "anki5@example.com")
    tok = _token(client, jwt, ["anki:write"])
    for cards in (10, 4, 10):
        r = client.post(
            "/api/v1/anki/report",
            json=_report(
                [{"day": _day(), "deck": "Deck", "cards": cards, "reviews": cards}]
            ),
            headers=tok,
        )
        assert r.status_code == 200, r.text
    body = client.get("/api/v1/anki/reviews", headers=jwt).json()
    assert len(body["days"]) == 1
    assert body["days"][0]["cards"] == 10
    assert body["days"][0]["reviews"] == 10


def test_duplicate_keys_in_one_report_keep_max(client: TestClient):
    jwt = _register(client, "anki6@example.com")
    tok = _token(client, jwt, ["anki:write"])
    r = client.post(
        "/api/v1/anki/report",
        json=_report(
            [
                {"day": _day(), "deck": "Deck", "cards": 2, "reviews": 2},
                {"day": _day(), "deck": "Deck", "cards": 7, "reviews": 6},
            ]
        ),
        headers=tok,
    )
    assert r.status_code == 200, r.text
    body = client.get("/api/v1/anki/reviews", headers=jwt).json()
    assert body["days"][0]["cards"] == 7
    assert body["days"][0]["reviews"] == 6


def test_rejects_bad_rows(client: TestClient):
    jwt = _register(client, "anki7@example.com")
    tok = _token(client, jwt, ["anki:write"])
    cases = [
        [{"day": _day(-900), "deck": "Deck", "cards": 1, "reviews": 1}],
        [{"day": _day(4), "deck": "Deck", "cards": 1, "reviews": 1}],
        [{"day": _day(), "deck": "  ", "cards": 1, "reviews": 1}],
        [{"day": _day(), "deck": "Deck", "cards": -1, "reviews": 0}],
        [{"day": _day(), "deck": "Deck", "cards": 1, "reviews": 1.5}],
        [{"day": "not-a-date", "deck": "Deck", "cards": 1, "reviews": 1}],
    ]
    for days in cases:
        r = client.post("/api/v1/anki/report", json=_report(days), headers=tok)
        assert r.status_code in (400, 422), (days, r.text)
    r = client.post(
        "/api/v1/anki/report",
        json={"version": 2, "days": []},
        headers=tok,
    )
    assert r.status_code == 422, r.text


def test_rejects_bad_ranges(client: TestClient):
    jwt = _register(client, "anki8@example.com")
    r = client.get(
        "/api/v1/anki/reviews",
        params={"start": _day(), "end": _day(-2)},
        headers=jwt,
    )
    assert r.status_code == 400, r.text
    r = client.get(
        "/api/v1/anki/reviews",
        params={"start": _day(-401), "end": _day()},
        headers=jwt,
    )
    assert r.status_code == 400, r.text


def test_reviews_aggregate_decks_and_window(client: TestClient):
    jwt = _register(client, "anki9@example.com")
    tok = _token(client, jwt, ["anki:write"])
    client.post(
        "/api/v1/anki/report",
        json=_report(
            [
                {"day": _day(-1), "deck": "A", "cards": 2, "reviews": 3},
                {"day": _day(), "deck": "A", "cards": 5, "reviews": 6},
                {"day": _day(-500), "deck": "A", "cards": 99, "reviews": 99},
                {"day": _day(-1), "deck": "B", "cards": 1, "reviews": 1},
            ]
        ),
        headers=tok,
    )
    body = client.get(
        "/api/v1/anki/reviews",
        params={"start": _day(-7), "end": _day()},
        headers=jwt,
    ).json()
    assert [d["day"] for d in body["days"]] == [_day(-1), _day(-1), _day()]
    decks = {d["name"]: d for d in body["decks"]}
    assert decks["A"]["cards"] == 7
    assert decks["A"]["reviews"] == 9
    assert decks["A"]["last_day"] == _day()
    assert decks["B"]["cards"] == 1
    assert body["last_report_at"] is not None
    # SQLite drops tzinfo; the API must restamp UTC so the app's relative
    # "last report" label is not shifted by the viewer's offset.
    assert body["last_report_at"].endswith("Z") or body[
        "last_report_at"
    ].endswith("+00:00")
    assert body["last_client"] == "test/1.0"


def test_summary_for_addon_connection_test(client: TestClient):
    jwt = _register(client, "anki10@example.com")
    tok = _token(client, jwt, ["anki:write"])
    client.post(
        "/api/v1/anki/report",
        json=_report(
            [
                {"day": _day(), "deck": "A", "cards": 2, "reviews": 3},
                {"day": _day(-10), "deck": "B", "cards": 4, "reviews": 5},
            ]
        ),
        headers=tok,
    )
    r = client.get("/api/v1/anki/summary", headers=tok)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["ok"] is True
    # The write-only token must not disclose the account email.
    assert body["email"] == ""
    # A signed-in JWT still gets it.
    assert client.get("/api/v1/anki/summary", headers=jwt).json()["email"] == (
        "anki10@example.com"
    )
    assert body["decks"] == 2
    assert body["days"] == 2
    # Only the last seven days count toward the weekly totals.
    assert body["cards_7d"] == 2
    assert body["reviews_7d"] == 3
    assert body["last_report_at"] is not None


def test_addon_payload_is_accepted_by_the_server(client: TestClient):
    """The add-on's pure payload builder and the server schema agree.

    This is the one contract the two halves share; it caught schema drift
    without needing a real Anki install.
    """
    addon = (
        Path(__file__).resolve().parents[3]
        / "anki_addon"
        / "a_fish_in_sea"
        / "report.py"
    )
    if not addon.exists():
        pytest.skip("add-on source not present")
    spec = importlib.util.spec_from_file_location("fish_anki_report", addon)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)

    jwt = _register(client, "anki11@example.com")
    tok = _token(client, jwt, ["anki:write"])
    now = dt.datetime(2026, 11, 3, 12, tzinfo=dt.timezone.utc)
    moment = int(now.timestamp() * 1000)
    payload = module.build_payload(
        [(moment, 1, 100), (moment, 1, 101)],
        {1: "Japanese"},
        local_fromtimestamp=lambda _ms: now,
    )
    r = client.post("/api/v1/anki/report", json=payload, headers=tok)
    assert r.status_code == 200, r.text
    body = client.get(
        "/api/v1/anki/reviews",
        params={"start": "2026-11-03", "end": "2026-11-03"},
        headers=jwt,
    ).json()
    assert body["days"] == [
        {
            "day": "2026-11-03",
            "deck": "Japanese",
            "cards": 2,
            "reviews": 2,
        }
    ]


def test_addon_archive_is_downloadable(client: TestClient):
    r = client.get("/api/v1/anki/addon")
    assert r.status_code == 200, r.text
    assert "a_fish_in_sea.ankiaddon" in r.headers["content-disposition"]
    archive = zipfile.ZipFile(io.BytesIO(r.content))
    files = archive.namelist()
    assert "manifest.json" in files
    assert "__init__.py" in files
    assert "report.py" in files
    assert "config.json" in files
    assert "config.md" in files
    config = json.loads(archive.read("config.json"))
    assert config == {
        "server_url": "",
        "api_token": "",
        "enabled": True,
        "report_days": 400,
        "rollover_hour": 0,
    }
