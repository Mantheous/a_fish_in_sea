"""Auth dependencies: JWT access tokens first, then scoped MCP API tokens."""

from __future__ import annotations

import datetime as dt

from fastapi import Depends, Header, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .db import get_session
from .models import ApiToken, User
from .security import decode_token, hash_api_token


async def get_current_user(
    authorization: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
) -> User:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing bearer token"
        )
    raw = authorization.split(" ", 1)[1].strip()
    # 1) JWT access token
    try:
        user_id = decode_token(raw, expect="access")
        user = await session.get(User, user_id)
        if user is None:
            raise HTTPException(status_code=401, detail="Unknown user")
        return user
    except HTTPException:
        raise
    except Exception:
        pass  # fall through to API-token lookup
    # 2) Scoped MCP / device API token (sha256, constant-time enough here)
    digest = hash_api_token(raw)
    row = (
        await session.execute(
            select(ApiToken).where(
                ApiToken.token_hash == digest, ApiToken.revoked.is_(False)
            )
        )
    ).scalar_one_or_none()
    if row is None:
        raise HTTPException(status_code=401, detail="Invalid token")
    row.last_used_at = dt.datetime.now(dt.timezone.utc)
    await session.commit()
    user = await session.get(User, row.user_id)
    if user is None:
        raise HTTPException(status_code=401, detail="Unknown user")
    # stash scopes for downstream scope checks
    user._scopes = list(row.scopes or [])  # type: ignore[attr-defined]
    return user


def require_scope(scope: str):
    """Gate /items/* collection routes. JWT users bypass (full access);
    API tokens must carry the scope or the blanket 'sync' scope."""

    async def _check(user: User = Depends(get_current_user)) -> User:
        scopes: list[str] | None = getattr(user, "_scopes", None)
        if scopes is None:
            return user  # JWT: full access
        if "sync" in scopes or scope in scopes:
            return user
        from fastapi import HTTPException

        raise HTTPException(status_code=403, detail=f"Missing scope: {scope}")

    return _check
