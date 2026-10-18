"""Server-side refresh-token rotation + revocation.

Each refresh JWT carries a jti tracked in refresh_tokens. Redeeming a
token revokes it and issues a successor; presenting an already-revoked
token signals theft, so the whole family (all of the user's refresh
tokens) is revoked. Only sha256 hashes are stored.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import secrets

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .models import RefreshToken, User
from .security import decode_refresh, refresh_token


class InvalidRefresh(Exception):
    pass


class ReusedRefresh(Exception):
    """A revoked token was presented: the family has been killed."""

    def __init__(self, user_id: int) -> None:
        super().__init__("refresh token reused")
        self.user_id = user_id


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


async def issue(session: AsyncSession, user_id: int) -> tuple[str, str]:
    """Create and store a fresh refresh token. Returns (token, jti)."""
    token, jti = refresh_token(user_id)
    session.add(
        RefreshToken(
            user_id=user_id,
            jti=jti,
            token_hash=_hash(token),
            expires_at=_now()
            + dt.timedelta(days=get_settings().refresh_token_days),
        )
    )
    await session.commit()
    return token, jti


async def redeem(session: AsyncSession, presented: str) -> tuple[int, str]:
    """Rotate: revoke the presented token, issue a successor.

    Returns (user_id, new_token). Raises InvalidRefresh (unknown, expired,
    legacy-unusable, or already-revoked token). A revoked token presented
    again is rejected with 401 without touching the rest of the user's
    token family, so a concurrent double-refresh yields exactly one winner
    and leaves the family intact.

    The revoke+claim is a single atomic UPDATE (... WHERE jti AND NOT
    revoked) whose rowcount decides the winner, so concurrent redemptions
    of the same token cannot mint parallel chains.
    """
    try:
        user_id, jti = decode_refresh(presented)
    except Exception:
        raise InvalidRefresh from None
    if jti is None:
        # Pre-rotation tokens carry no jti and cannot be rotated; reject
        # instead of issuing an untracked successor that bypasses revocation.
        raise InvalidRefresh
    user = await session.get(User, user_id)
    if user is None:
        raise InvalidRefresh
    presented_hash = _hash(presented)
    row = (
        await session.execute(
            select(RefreshToken).where(RefreshToken.jti == jti)
        )
    ).scalar_one_or_none()
    if (
        row is None
        or row.user_id != user_id
        or not secrets.compare_digest(row.token_hash or "", presented_hash)
    ):
        raise InvalidRefresh
    now = _now()
    expires = row.expires_at
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=dt.timezone.utc)
    if expires <= now:
        raise InvalidRefresh
    new_token, new_jti = refresh_token(user_id)
    # Atomically claim the token: only one transaction can flip an unrevoked
    # row to revoked, so concurrent redemptions yield exactly one winner;
    # the loser is rejected without revoking the family.
    claim = await session.execute(
        update(RefreshToken)
        .where(
            RefreshToken.jti == jti,
            RefreshToken.user_id == user_id,
            RefreshToken.revoked.is_(False),
        )
        .values(revoked=True, replaced_by=new_jti, last_used_at=now)
    )
    if (claim.rowcount or 0) != 1:
        await session.rollback()
        raise InvalidRefresh
    session.add(
        RefreshToken(
            user_id=user_id,
            jti=new_jti,
            token_hash=_hash(new_token),
            expires_at=now
            + dt.timedelta(days=get_settings().refresh_token_days),
        )
    )
    await session.commit()
    return user_id, new_token


async def revoke_one(session: AsyncSession, presented: str) -> None:
    """Revoke a single refresh token (logout). Never raises for unknown
    tokens, so logout can't be used as an oracle."""
    try:
        row = (
            await session.execute(
                select(RefreshToken).where(
                    RefreshToken.token_hash == _hash(presented)
                )
            )
        ).scalar_one_or_none()
    except Exception:
        return
    if row is not None and not row.revoked:
        row.revoked = True
        await session.commit()


async def revoke_all(session: AsyncSession, user_id: int) -> None:
    await session.execute(
        update(RefreshToken)
        .where(
            RefreshToken.user_id == user_id,
            RefreshToken.revoked.is_(False),
        )
        .values(revoked=True)
    )
    await session.commit()
