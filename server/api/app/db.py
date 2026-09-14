"""Async engine + session factory + init hook."""

from __future__ import annotations

from sqlalchemy.ext.asyncio import (
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase

from .config import get_settings


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


async def init_db() -> None:
    from . import models  # noqa: F401  (register tables)

    async with engine().begin() as conn:
        await conn.run_sync(Base.metadata.create_all)


async def get_session() -> AsyncSession:  # FastAPI dependency
    factory = session_factory()
    async with factory() as session:
        yield session
