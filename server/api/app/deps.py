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
    now = dt.datetime.now(dt.timezone.utc)
    last_used = row.last_used_at
    if last_used is not None and last_used.tzinfo is None:
        last_used = last_used.replace(tzinfo=dt.timezone.utc)
    # Touch last_used_at best-effort, with no per-GET commit. Committing on
    # every authenticated GET serializes writers and is a lock/contention
    # source under concurrent sync + token use; WAL + busy_timeout already
    # guard the real write paths, and last_used_at is only an advisory
    # "last seen" hint, so an in-memory touch that rolls back with the
    # request session is acceptable.
    if last_used is None or (now - last_used) >= dt.timedelta(seconds=60):
        row.last_used_at = now
    user = await session.get(User, row.user_id)
    if user is None:
        raise HTTPException(status_code=401, detail="Unknown user")
    # stash scopes for downstream scope checks
    user._scopes = list(row.scopes or [])  # type: ignore[attr-defined]
    # stash the review flag + label so POST /imports can route this token
    # into the approval queue without another lookup. getattr-guarded
    # reads keep old rows (pre-review-column) working.
    user._token_review = bool(getattr(row, "review", False) or False)  # type: ignore[attr-defined]
    user._token_name = row.name or ""  # type: ignore[attr-defined]
    return user


def is_api_token(user: User) -> bool:
    return getattr(user, "_scopes", None) is not None


def is_review_token(user: User) -> bool:
    return bool(getattr(user, "_token_review", False))


async def require_jwt_user(user: User = Depends(get_current_user)) -> User:
    """Require an interactive user JWT (never a long-lived API token)."""
    if is_api_token(user):
        raise HTTPException(
            status_code=403,
            detail="This endpoint requires a user session (JWT), not an API token",
        )
    return user


def check_token_scope(
    user: User, *accepted_scopes: str, allow_review: bool = False
) -> None:
    """Verify API-token scopes and review-mode restrictions."""
    scopes: list[str] | None = getattr(user, "_scopes", None)
    if scopes is None:
        return  # JWT: full access
    if is_review_token(user) and not allow_review:
        raise HTTPException(
            status_code=403,
            detail="Review-only tokens cannot access this endpoint; use POST /api/v1/imports",
        )
    if "sync" in scopes or any(s in scopes for s in accepted_scopes):
        return
    needed = accepted_scopes[0] if accepted_scopes else "sync"
    raise HTTPException(status_code=403, detail=f"Missing scope: {needed}")


def require_scope(scope: str, *, allow_review: bool = False):
    """Gate routes by scope. JWT users bypass (full access);
    API tokens must carry the scope or the blanket 'sync' scope."""

    async def _check(user: User = Depends(get_current_user)) -> User:
        check_token_scope(user, scope, allow_review=allow_review)
        return user

    return _check
