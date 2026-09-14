"""Sync-backend configuration (env-driven, 12-factor)."""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from dotenv import load_dotenv
from pydantic_settings import BaseSettings, SettingsConfigDict

# Shared secrets live in ONE place: server/.env (GOOGLE_/PLAID_/OLLAMA_
# keys plus JWT/TOKEN_FERNET_KEY). A local server/api/.env overrides it.
_API_DIR = Path(__file__).parent.parent
load_dotenv(dotenv_path=_API_DIR.parent / ".env")
load_dotenv(dotenv_path=_API_DIR / ".env", override=True)


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # sqlite (dev) default; postgres in prod, e.g.
    # postgresql+asyncpg://app:app@db:5432/app
    database_url: str = "sqlite+aiosqlite:///./data/app.db"

    jwt_secret: str = "dev-only-change-me"
    jwt_algorithm: str = "HS256"
    access_token_minutes: int = 15
    refresh_token_days: int = 30

    cors_origins: str = "*"  # comma-separated or "*"

    # Token encryption for Plaid/Google OAuth secrets stored per-user.
    # Fernet key (base64). If empty, tokens are stored plaintext (dev only).
    token_fernet_key: str = ""


@lru_cache
def get_settings() -> Settings:
    return Settings()
