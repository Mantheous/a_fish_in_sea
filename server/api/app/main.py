"""FastAPI sync backend: auth + offline-first pull/push + MCP item helpers."""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from .config import get_settings
from .db import init_db
from .oauth_store import validate_fernet_key
from .routers import auth, anki, canvas, feedback, fetch, google, imports, items, plaid, proxy, syllabus, sync, tokens, usage

log = logging.getLogger("a_fish_in_sea")


class _FishPrefixStrip:
    """Mirror the Tailnet funnel locally.

    Tailscale serve maps /fish -> this server with the prefix stripped,
    so the Flutter client (see ServerConfig.webBase) keeps API calls under
    the page's own prefix: /fish/api/... Local browsers and the UX walker
    hit this server directly at http://host:8000/fish/ with no proxy to
    strip anything, so without this every API call 405s against the
    GET-only SPA fallback and auth is a dead end. Stripping here makes
    direct-local behave exactly like via-funnel; funnelled traffic (no
    prefix left) passes through untouched.
    """

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope.get("type") == "http":
            path = scope.get("path", "")
            if path == "/fish" or path.startswith("/fish/"):
                stripped = path[len("/fish"):] or "/"
                raw = scope.get("raw_path", b"")
                try:
                    raw_stripped = raw[len(b"/fish"):] or b"/"
                except Exception:
                    raw_stripped = stripped.encode("latin-1")
                scope = {**scope, "path": stripped, "raw_path": raw_stripped}
        await self.app(scope, receive, send)

class _SecurityHeaders:
    """Attach baseline browser hardening headers to every HTTP response."""

    _HEADERS = (
        (b"x-content-type-options", b"nosniff"),
        (b"x-frame-options", b"DENY"),
        (b"referrer-policy", b"strict-origin-when-cross-origin"),
    )

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope.get("type") != "http":
            await self.app(scope, receive, send)
            return

        async def _send(message):
            if message.get("type") == "http.response.start":
                headers = list(message.get("headers") or [])
                existing = {k.lower() for k, _ in headers}
                for k, v in self._HEADERS:
                    if k not in existing:
                        headers.append((k, v))
                message = {**message, "headers": headers}
            await send(message)

        await self.app(scope, receive, _send)
# has run. Served same-origin so the web app needs no CORS at all.
WEB_BUILD_DIR = (
    Path(__file__).parent.parent.parent.parent / "build" / "web"
).resolve()


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    yield


def create_app() -> FastAPI:
    s = get_settings()
    app = FastAPI(title="a_fish_in_sea sync API", version="0.1.0", lifespan=lifespan)

    origins = (
        ["*"]
        if s.cors_origins.strip() == "*"
        else [o.strip() for o in s.cors_origins.split(",") if o.strip()]
    )
    # Access-Control-Allow-Origin: * is incompatible with credentials;
    # browsers reject the combination, so only send credentials with an
    # explicit allowlist.
    allow_credentials = origins != ["*"]
    if s.jwt_secret == "dev-only-change-me":
        log.warning(
            "JWT_SECRET is the dev default: set a real secret in .env "
            "before exposing this server beyond localhost."
        )
    if not s.token_fernet_key.strip():
        log.warning(
            "TOKEN_FERNET_KEY is empty: OAuth tokens are stored in "
            "plaintext. Set a Fernet key in .env."
        )
    else:
        validate_fernet_key(s.token_fernet_key)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=origins,
        allow_credentials=allow_credentials,
        allow_methods=["*"],
        allow_headers=["*"],
    )
    app.add_middleware(_SecurityHeaders)
    # Strip the Tailnet subpath before routing (see _FishPrefixStrip).
    app.add_middleware(_FishPrefixStrip)

    @app.get("/api/health")
    async def health():
        return {"status": "ok"}

    app.include_router(auth.router, prefix="/api/v1")
    app.include_router(tokens.router, prefix="/api/v1")
    app.include_router(sync.router, prefix="/api/v1")
    app.include_router(items.router, prefix="/api/v1")
    app.include_router(imports.router, prefix="/api/v1")
    app.include_router(feedback.router, prefix="/api/v1")
    app.include_router(usage.router, prefix="/api/v1")
    # Google keeps its legacy /api/google/* paths so the Flutter client
    # needs no changes; tokens are per-user now (was: global on Flask).
    app.include_router(google.router, prefix="/api")
    app.include_router(anki.router, prefix="/api")
    app.include_router(canvas.router, prefix="/api")
    app.include_router(fetch.router, prefix="/api/v1")
    app.include_router(proxy.router, prefix="/api")
    # Plaid keeps its legacy /api/* paths so the Flutter client needs
    # no changes; bank tokens are per-user now (was: device-header
    # buckets in .plaid_users.json on Flask).
    app.include_router(plaid.router, prefix="/api")
    # Syllabus LLM extract (same open-proxy contract as Flask /api/ical).
    app.include_router(syllabus.router, prefix="/api")

    _mount_web(app)
    return app


def _mount_web(app: FastAPI) -> None:
    """Serve the Flutter web build (if present) with SPA fallback.

    Mounted LAST so /api/* routes always win. Non-API paths that match a
    built file are served; everything else falls back to index.html.
    """
    index = WEB_BUILD_DIR / "index.html"
    if not index.is_file():
        return
    for asset in ("flutter.js", "main.dart.js", "manifest.json", "favicon.png",
                  "icons", "assets", "canvaskit"):
        path = WEB_BUILD_DIR / asset
        if path.is_dir():
            app.mount(
                f"/{asset}",
                StaticFiles(directory=path),
                name=f"web-{asset}",
            )
        elif path.is_file():
            full = path

            @app.get(f"/{asset}", include_in_schema=False)
            async def _single(full=full):  # type: ignore[no-redef]
                return FileResponse(full)

    @app.get("/{path:path}", include_in_schema=False)
    async def _spa(path: str):
        if path and "\x00" not in path:
            try:
                candidate = (WEB_BUILD_DIR / path).resolve()
                candidate.relative_to(WEB_BUILD_DIR)
            except (ValueError, OSError):
                pass
            else:
                if candidate.is_file():
                    return FileResponse(candidate)
        return FileResponse(index)


app = create_app()
