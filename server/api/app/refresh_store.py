"""Server-side refresh-token rotation + revocation.

Each refresh JWT carries a jti tracked in refresh_tokens. Redeeming a
token revokes it and issues a successor; presenting an already-revoked
token signals theft, so the whole family (all of the user's refresh
tokens) is revoked. Only sha256 hashes are stored.
"""

from __future__ import annotations

import datetime as dt
import hashlib

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .models import RefreshToken
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

    Returns (user_id, new_token). Raises InvalidRefresh (unknown,
    expired, or legacy-unusable token) or ReusedRefresh (revoked token
    presented: the user's whole family is revoked as a theft response).
    """
    try:
        user_id, jti = decode_refresh(presented)
    except Exception:
        raise InvalidRefresh from None
    if jti is None:
        # Pre-rotation legacy token (no jti claim): valid signature, so
        # upgrade the session in place instead of forcing a re-login.
        # The legacy token itself is stateless and stays usable until it
        # expires; the issued successor rotates from here on.
        return user_id, (await issue(session, user_id))[0]
    row = (
        await session.execute(
            select(RefreshToken).where(RefreshToken.jti == jti)
        )
    ).scalar_one_or_none()
    if row is None or row.user_id != user_id:
        raise InvalidRefresh
    if row.revoked:
        await session.execute(
            update(RefreshToken)
            .where(
                RefreshToken.user_id == user_id,
                RefreshToken.revoked.is_(False),
            )
            .values(revoked=True)
        )
        await session.commit()
        raise ReusedRefresh(user_id)
    expires = row.expires_at
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=dt.timezone.utc)
    if expires <= _now():
        row.revoked = True
        await session.commit()
        raise InvalidRefresh
    new_token, new_jti = refresh_token(user_id)
    row.revoked = True
    row.replaced_by = new_jti
    row.last_used_at = _now()
    session.add(
        RefreshToken(
            user_id=user_id,
            jti=new_jti,
            token_hash=_hash(new_token),
            expires_at=_now()
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
