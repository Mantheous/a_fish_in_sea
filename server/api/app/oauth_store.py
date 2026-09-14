"""Per-user secret storage for OAuth tokens (Google, Plaid).

Tokens are Fernet-encrypted when TOKEN_FERNET_KEY is set, else stored
plaintext (dev only — never production). The oauth_connections table
already exists; this module is the only read/write path.
"""

from __future__ import annotations

import base64
import datetime as dt

from cryptography.fernet import Fernet, InvalidToken
from sqlalchemy import and_, select
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .models import OAuthConnection


def _fernet() -> Fernet | None:
    key = get_settings().token_fernet_key.strip()
    if not key:
        return None
    raw = key.encode()
    # Accept both raw 32 bytes and base64-encoded keys.
    try:
        return Fernet(base64.urlsafe_b64encode(base64.urlsafe_b64decode(raw)))
    except Exception:
        try:
            return Fernet(raw)
        except Exception:
            return None


def encrypt_secret(value: str) -> str:
    if not value:
        return ""
    f = _fernet()
    if f is None:
        return value
    return f.encrypt(value.encode()).decode()


def decrypt_secret(value: str) -> str:
    if not value:
        return ""
    f = _fernet()
    if f is None:
        return value
    try:
        return f.decrypt(value.encode()).decode()
    except InvalidToken:
        # Pre-key plaintext row: return as-is so the next save encrypts it.
        return value


async def get_connection(
    session: AsyncSession, user_id: int, provider: str
) -> OAuthConnection | None:
    return (
        await session.execute(
            select(OAuthConnection).where(
                and_(
                    OAuthConnection.user_id == user_id,
                    OAuthConnection.provider == provider,
                )
            )
        )
    ).scalar_one_or_none()


async def save_connection(
    session: AsyncSession,
    user_id: int,
    provider: str,
    *,
    access_token: str = "",
    refresh_token: str = "",
    item_id: str = "",
    scopes: str = "",
    expires_at: dt.datetime | None = None,
    merge_refresh: bool = True,
) -> OAuthConnection:
    """Upsert tokens. With merge_refresh, an empty refresh_token keeps the
    stored one (Google only returns it on first consent)."""
    row = await get_connection(session, user_id, provider)
    now = dt.datetime.now(dt.timezone.utc)
    if row is None:
        row = OAuthConnection(
            user_id=user_id,
            provider=provider,
            access_token=encrypt_secret(access_token),
            refresh_token=encrypt_secret(refresh_token),
            item_id=item_id,
            scopes=scopes,
            expires_at=expires_at,
            updated_at=now,
        )
        session.add(row)
    else:
        if access_token:
            row.access_token = encrypt_secret(access_token)
        if refresh_token or not merge_refresh:
            row.refresh_token = encrypt_secret(refresh_token)
        if item_id:
            row.item_id = item_id
        if scopes:
            row.scopes = scopes
        row.expires_at = expires_at
        row.updated_at = now
    await session.commit()
    await session.refresh(row)
    return row


async def clear_connection(
    session: AsyncSession, user_id: int, provider: str
) -> None:
    row = await get_connection(session, user_id, provider)
    if row is not None:
        await session.delete(row)
        await session.commit()
