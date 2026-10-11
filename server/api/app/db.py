"""Async engine + session factory + init hook."""

from __future__ import annotations

import logging

from sqlalchemy import text
from sqlalchemy.ext.asyncio import (
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase

from .config import get_settings

log = logging.getLogger("a_fish_in_sea.db")


class Base(DeclarativeBase):
    pass


def _engine_kwargs(url: str) -> dict:
    if url.startswith("sqlite"):
        return {"connect_args": {"check_same_thread": False}}
    return {"pool_pre_ping": True}


_engine = None
_session_factory: async_sessionmaker[AsyncSession] | None = None


def engine():
    global _engine
    if _engine is None:
        url = get_settings().database_url
        _engine = create_async_engine(url, **_engine_kwargs(url))
    return _engine


def session_factory() -> async_sessionmaker[AsyncSession]:
    global _session_factory
    if _session_factory is None:
        _session_factory = async_sessionmaker(engine(), expire_on_commit=False)
    return _session_factory


async def _backfill_api_tokens_review(conn) -> None:
    """Additive-only backfill for pre-existing DBs: create_all never
    alters tables, and api_tokens.review postdates the table. Plain
    ADD COLUMN with a static default is non-destructive on both sqlite
    and postgres (existing rows read back as false). Split out so tests
    can run it against a pre-change schema directly."""
    try:
        cols = (await conn.execute(text("PRAGMA table_info(api_tokens)"))).all()
        if cols and all(c[1] != "review" for c in cols):
            await conn.execute(
                text("ALTER TABLE api_tokens ADD COLUMN review BOOLEAN DEFAULT 0")
            )
    except Exception as e:  # postgres: PRAGMA is unknown; use catalog
        try:
            has = (
                await conn.execute(
                    text(
                        "SELECT 1 FROM information_schema.columns "
                        "WHERE table_name='api_tokens' AND column_name='review'"
                    )
                )
            ).first()
            if not has:
                await conn.execute(
                    text(
                        "ALTER TABLE api_tokens ADD COLUMN review BOOLEAN DEFAULT FALSE"
                    )
                )
        except Exception as e2:
            log.warning("api_tokens.review backfill skipped: %s / %s", e, e2)


async def init_db() -> None:
    from . import models  # noqa: F401  (register tables)

    async with engine().begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        await _backfill_api_tokens_review(conn)


async def get_session() -> AsyncSession:  # FastAPI dependency
    factory = session_factory()
    async with factory() as session:
        yield session
