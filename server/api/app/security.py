"""Password hashing, JWT, and scoped MCP API tokens."""

from __future__ import annotations

import datetime as dt
import hashlib
import secrets

import jwt
from passlib.context import CryptContext

from .config import get_settings
_pwd = CryptContext(schemes=["bcrypt"], deprecated="auto")
_API_PREFIX = "afm_"


def hash_password(password: str) -> str:
    return _pwd.hash(password)


def verify_password(password: str, hashed: str) -> bool:
    return _pwd.verify(password, hashed)


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def _encode(
    user_id: int, kind: str, delta: dt.timedelta, jti: str | None = None
) -> str:
    s = get_settings()
    payload = {
        "sub": str(user_id),
        "type": kind,
        "exp": _now() + delta,
        "iat": _now(),
    }
    if jti is not None:
        payload["jti"] = jti
    return jwt.encode(payload, s.jwt_secret, algorithm=s.jwt_algorithm)


def access_token(user_id: int) -> str:
    return _encode(
        user_id, "access", dt.timedelta(minutes=get_settings().access_token_minutes)
    )


def refresh_token(user_id: int) -> tuple[str, str]:
    """Return (token, jti). The jti is tracked server-side for rotation."""
    jti = secrets.token_hex(16)
    return (
        _encode(
            user_id,
            "refresh",
            dt.timedelta(days=get_settings().refresh_token_days),
            jti=jti,
        ),
        jti,
    )


def decode_token(token: str, expect: str) -> int:
    s = get_settings()
    payload = jwt.decode(token, s.jwt_secret, algorithms=[s.jwt_algorithm])
    if payload.get("type") != expect:
        raise ValueError(f"expected {expect} token")
    return int(payload["sub"])


def decode_refresh(token: str) -> tuple[int, str | None]:
    """Return (user_id, jti). jti is None for pre-rotation legacy tokens,
    which carry no jti claim."""
    s = get_settings()
    payload = jwt.decode(token, s.jwt_secret, algorithms=[s.jwt_algorithm])
    if payload.get("type") != "refresh":
        raise ValueError("expected refresh token")
    jti = payload.get("jti")
    return int(payload["sub"]), str(jti) if jti is not None else None


def new_api_token() -> tuple[str, str, str]:
    """Return (plaintext, prefix, sha256 hash). Only the hash is stored."""
    raw = secrets.token_urlsafe(32)
    plaintext = f"{_API_PREFIX}{raw}"
    digest = hashlib.sha256(plaintext.encode()).hexdigest()
    return plaintext, _API_PREFIX.rstrip("_"), digest


def hash_api_token(plaintext: str) -> str:
    return hashlib.sha256(plaintext.encode()).hexdigest()
