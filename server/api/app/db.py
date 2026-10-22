"""Async engine + session factory + init hook."""

from __future__ import annotations

import logging

from sqlalchemy import event, text
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
        return {"connect_args": {"check_same_thread": False, "timeout": 5.0}}
    return {"pool_pre_ping": True}


_engine = None
_session_factory: async_sessionmaker[AsyncSession] | None = None


def engine():
    global _engine
    if _engine is None:
        url = get_settings().database_url
        _engine = create_async_engine(url, **_engine_kwargs(url))
        if url.startswith("sqlite"):

            @event.listens_for(_engine.sync_engine, "connect")
            def _set_sqlite_pragmas(dbapi_conn, _conn_record) -> None:
                cur = dbapi_conn.cursor()
                try:
                    cur.execute("PRAGMA busy_timeout=5000")
                    cur.execute("PRAGMA journal_mode=WAL")
                    cur.execute("PRAGMA synchronous=NORMAL")
                    cur.execute("PRAGMA foreign_keys=ON")
                except Exception:
                    pass
                finally:
                    cur.close()

    return _engine


def session_factory() -> async_sessionmaker[AsyncSession]:
    global _session_factory
    if _session_factory is None:
        _session_factory = async_sessionmaker(engine(), expire_on_commit=False)
    return _session_factory


_dialect_insert = None


def dialect_insert(table):
    """DML insert construct that supports ON CONFLICT DO UPDATE on the
    configured dialect. SQLite and Postgres both compile this to the same
    ON CONFLICT syntax, so the call sites stay dialect-agnostic."""
    global _dialect_insert
    if _dialect_insert is None:
        if get_settings().database_url.startswith("sqlite"):
            from sqlalchemy.dialects.sqlite import insert as _insert
        else:
            from sqlalchemy.dialects.postgresql import insert as _insert
        _dialect_insert = _insert
    return _dialect_insert(table)


async def _backfill_api_tokens_review(conn) -> None:
    """Additive-only backfill for pre-existing DBs: create_all never
    alters tables, and api_tokens.review postdates the table. Plain
    ADD COLUMN with a static default is non-destructive on both sqlite
    and postgres (existing rows read back as false). Split out so tests
    can run it against a pre-change schema directly."""
    dialect = getattr(getattr(conn, "dialect", None), "name", "")
    if dialect == "sqlite":
        try:
            cols = (
                await conn.execute(text("PRAGMA table_info(api_tokens)"))
            ).all()
            if cols and all(c[1] != "review" for c in cols):
                await conn.execute(
                    text(
                        "ALTER TABLE api_tokens ADD COLUMN review BOOLEAN DEFAULT 0"
                    )
                )
        except Exception as e:
            log.warning("api_tokens.review sqlite backfill skipped: %s", e)
        return
    try:
        async with conn.begin_nested():
            cols = (
                await conn.execute(text("PRAGMA table_info(api_tokens)"))
            ).all()
            if cols and all(c[1] != "review" for c in cols):
                await conn.execute(
                    text(
                        "ALTER TABLE api_tokens ADD COLUMN review BOOLEAN DEFAULT 0"
                    )
                )
            return
    except Exception as e:  # postgres: PRAGMA is unknown; use catalog
        try:
            async with conn.begin_nested():
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
