"""Pydantic I/O. Validation is intentionally lenient: unknown fields pass
through (forward-compat with Dart model evolution), matching the client's
per-item-tolerant restores."""

from __future__ import annotations

import datetime as dt
import json

from pydantic import BaseModel, EmailStr, Field, field_validator, model_validator

from .models import COLLECTIONS

Collections = COLLECTIONS

# Per-item and per-request body caps: sync payloads are small model
# objects, so anything larger is a runaway client or abuse. Oversize
# requests answer 422.
MAX_ITEM_BYTES = 256 * 1024
MAX_PUSH_BYTES = 10 * 1024 * 1024


def _check_item_size(data: dict) -> dict:
    if len(json.dumps(data).encode("utf-8")) > MAX_ITEM_BYTES:
        raise ValueError(f"item data exceeds {MAX_ITEM_BYTES} bytes")
    return data


class RegisterIn(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)


class LoginIn(BaseModel):
    email: EmailStr
    password: str


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"


class RefreshIn(BaseModel):
    refresh_token: str


class LogoutIn(BaseModel):
    refresh_token: str


class MeOut(BaseModel):
    id: int
    email: str


class ApiTokenCreateIn(BaseModel):
    name: str = ""
    # e.g. ["sync", "tasks:read", "tasks:write", "events:read", "events:write"]
    # "sync" implies full sync pull/push; collection scopes gate /items/*.
    scopes: list[str] = Field(default_factory=lambda: ["sync"])


class ApiTokenOut(BaseModel):
    id: int
    name: str
    prefix: str
    scopes: list[str]


class ApiTokenCreated(ApiTokenOut):
    token: str  # plaintext, shown once


class SyncChangeIn(BaseModel):
    collection: str
    item_id: str = Field(min_length=1, max_length=256)
    data: dict = Field(default_factory=dict)
    deleted: bool = False
    # client-supplied updated_at is informational only; server stamps time.

    model_config = {"extra": "ignore"}

    @field_validator("data", mode="after")
    @classmethod
    def _check_size(cls, data: dict) -> dict:
        return _check_item_size(data)


class PushIn(BaseModel):
    changes: list[SyncChangeIn] = Field(max_length=1000)

    @model_validator(mode="after")
    def _check_total_size(self) -> PushIn:
        total = sum(len(json.dumps(c.data).encode("utf-8")) for c in self.changes)
        if total > MAX_PUSH_BYTES:
            raise ValueError(f"push body exceeds {MAX_PUSH_BYTES} bytes")
        return self


class SyncRecord(BaseModel):
    collection: str
    item_id: str
    data: dict
    deleted: bool
    rev: int
    updated_at: dt.datetime


class PullOut(BaseModel):
    changes: list[SyncRecord]
    server_time: dt.datetime
    has_more: bool = False


class PushOut(BaseModel):
    applied: list[SyncRecord]
    server_time: dt.datetime


class ItemUpsertIn(BaseModel):
    data: dict = Field(default_factory=dict)

    model_config = {"extra": "ignore"}

    @field_validator("data", mode="after")
    @classmethod
    def _check_size(cls, data: dict) -> dict:
        return _check_item_size(data)
