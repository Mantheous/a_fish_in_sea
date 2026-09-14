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
from .routers import auth, fetch, google, items, plaid, proxy, syllabus, sync, tokens

log = logging.getLogger("a_fish_in_sea")

# Flutter web build lives at <repo>/build/web when `flutter build web`
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
    app.add_middleware(
        CORSMiddleware,
        allow_origins=origins,
        allow_credentials=allow_credentials,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    @app.get("/api/health")
    async def health():
        return {"status": "ok"}

    app.include_router(auth.router, prefix="/api/v1")
    app.include_router(tokens.router, prefix="/api/v1")
    app.include_router(sync.router, prefix="/api/v1")
    app.include_router(items.router, prefix="/api/v1")
    # Google keeps its legacy /api/google/* paths so the Flutter client
    # needs no changes; tokens are per-user now (was: global on Flask).
    app.include_router(google.router, prefix="/api")
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
        candidate = WEB_BUILD_DIR / path
        if path and candidate.is_file():
            try:
                candidate.relative_to(WEB_BUILD_DIR)
            except ValueError:
                pass
            else:
                return FileResponse(candidate)
        return FileResponse(index)


app = create_app()
