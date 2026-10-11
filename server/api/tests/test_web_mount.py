"""Web-build mount: the Flutter bundle must load both stripped (Tailnet
/fish -> / via Tailscale) and unstripped (local http://host:8000/fish/)."""

from __future__ import annotations

import os
import tempfile

from fastapi.testclient import TestClient

os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{tempfile.mkdtemp()}/test_web.db"
os.environ["JWT_SECRET"] = "test-secret"

from app.main import WEB_BUILD_DIR, create_app  # noqa: E402

app = create_app()

INDEX = WEB_BUILD_DIR / "index.html"
HAS_BUILD = INDEX.is_file()


def test_fish_prefix_serves_real_assets_not_index():
    if not HAS_BUILD:
        import pytest

        pytest.skip("no Flutter web build present")
    with TestClient(app) as client:
        r = client.get("/fish/flutter.js")
        assert r.status_code == 200, r.text[:200]
        assert "text/javascript" in r.headers["content-type"], r.headers
        assert not r.text.lstrip().startswith("<!DOCTYPE"), r.text[:120]


def test_fish_root_serves_index_with_subpath_base():
    if not HAS_BUILD:
        import pytest

        pytest.skip("no Flutter web build present")
    with TestClient(app) as client:
        for url in ("/fish", "/fish/"):
            r = client.get(url)
            assert r.status_code == 200, url
            assert '<base href="/fish/">' in r.text, url


def test_stripped_paths_and_api_still_win():
    if not HAS_BUILD:
        import pytest

        pytest.skip("no Flutter web build present")
    with TestClient(app) as client:
        r = client.get("/flutter.js")
        assert r.status_code == 200
        assert "text/javascript" in r.headers["content-type"]
        r = client.get("/api/health")
        assert r.status_code == 200
        assert r.json() == {"status": "ok"}


def test_api_under_fish_prefix_mirrors_funnel():
    """Direct-local /fish/api/... must route like the funnel strips it.

    Regression test for the UX-walker blocker: the web client keeps API
    calls under the page prefix (ServerConfig.webBase), so POST
    /fish/api/v1/auth/login 405d and auth was a dead end locally.
    """
    with TestClient(app) as client:
        r = client.get("/fish/api/health")
        assert r.status_code == 200, r.text
        assert r.json() == {"status": "ok"}
        r = client.post(
            "/fish/api/v1/auth/register",
            json={"email": "fish-prefix@example.com", "password": "password123"},
        )
        assert r.status_code == 201, r.text
        r = client.post(
            "/fish/api/v1/auth/login",
            json={"email": "fish-prefix@example.com", "password": "password123"},
        )
        assert r.status_code == 200, r.text
        assert r.json()["token_type"] == "bearer"
