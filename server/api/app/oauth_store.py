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
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .models import OAuthConnection


def validate_fernet_key(raw_key: str) -> Fernet:
    """Parse and validate a Fernet key (44-char urlsafe base64 or 32 raw bytes).

    Raises ValueError when the key is malformed so the server never silently
    falls back to storing plaintext secrets when TOKEN_FERNET_KEY is set.
    """
    key = raw_key.strip()
    if not key:
        raise ValueError("TOKEN_FERNET_KEY is empty")
    raw = key.encode("utf-8")
    if len(raw) == 32:
        return Fernet(base64.urlsafe_b64encode(raw))
    try:
        return Fernet(raw)
    except Exception:
        try:
            decoded = base64.urlsafe_b64decode(raw)
            if len(decoded) == 32:
                return Fernet(base64.urlsafe_b64encode(decoded))
        except Exception:
            pass
    raise ValueError(
        "Invalid TOKEN_FERNET_KEY: expected a 32-byte urlsafe-base64 Fernet key "
        "or 32 raw ASCII bytes"
    )


def _fernet() -> Fernet | None:
    key = get_settings().token_fernet_key.strip()
    if not key:
        return None
    return validate_fernet_key(key)


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
        if value.startswith("gAAAAAB"):
            return ""
        return value
    try:
        return f.decrypt(value.encode()).decode()
    except InvalidToken:
        # Ciphertext from another key must never be sent upstream as a bearer
        # token; only pre-key plaintext rows pass through for upgrade-on-save.
        if value.startswith("gAAAAAB"):
            return ""
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
        try:
            await session.commit()
        except IntegrityError:
            await session.rollback()
            row = await get_connection(session, user_id, provider)
            if row is None:
                raise
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
