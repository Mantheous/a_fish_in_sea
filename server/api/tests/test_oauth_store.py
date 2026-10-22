"""OAuth secret encryption + startup refusal of a malformed Fernet key."""

from __future__ import annotations

import os

import pytest
from cryptography.fernet import Fernet

os.environ["DATABASE_URL"] = "sqlite+aiosqlite:///:memory:"
os.environ["JWT_SECRET"] = "test-secret"

from app.config import get_settings  # noqa: E402
from app.main import create_app  # noqa: E402
from app.oauth_store import (  # noqa: E402
    decrypt_secret,
    encrypt_secret,
    validate_fernet_key,
)


def _set_fernet(key: str | None) -> None:
    if key is None:
        os.environ.pop("TOKEN_FERNET_KEY", None)
    else:
        os.environ["TOKEN_FERNET_KEY"] = key
    get_settings.cache_clear()


def test_fernet_key_rejects_malformed():
    for bad in ["", "not-a-key", "too-short", "x" * 43, "garbage!!!invalid-key"]:
        with pytest.raises(ValueError):
            validate_fernet_key(bad)


def test_fernet_key_accepts_valid():
    key = Fernet.generate_key().decode()
    assert isinstance(validate_fernet_key(key), Fernet)
    # 32 raw ASCII bytes are accepted and converted to a Fernet key.
    raw32 = "0123456789abcdef0123456789abcdef"
    assert isinstance(validate_fernet_key(raw32), Fernet)


def test_encrypt_decrypt_roundtrip():
    _set_fernet(Fernet.generate_key().decode())
    try:
        secret = encrypt_secret("plaid-access-token-value")
        assert secret != "plaid-access-token-value"
        assert decrypt_secret(secret) == "plaid-access-token-value"
    finally:
        _set_fernet(None)


def test_empty_key_stores_plaintext_dev_only():
    _set_fernet(None)
    try:
        assert encrypt_secret("atoken") == "atoken"
        assert decrypt_secret("atoken") == "atoken"
    finally:
        _set_fernet(None)


def test_ciphertext_from_other_key_not_returned():
    # Fernet ciphertext produced under a different (rotated-away) key must
    # not be handed back to a provider as a bearer token.
    _set_fernet(Fernet.generate_key().decode())
    try:
        other = Fernet(Fernet.generate_key()).encrypt(b"old-token").decode()
        assert decrypt_secret(other) == ""
    finally:
        _set_fernet(None)


def test_invalid_key_refuses_startup():
    _set_fernet("definitely-not-a-valid-fernet-key!!!")
    try:
        with pytest.raises(ValueError):
            create_app()
    finally:
        _set_fernet(None)
