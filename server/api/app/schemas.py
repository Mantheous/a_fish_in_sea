"""Pydantic I/O. Validation is intentionally lenient: unknown fields pass
through (forward-compat with Dart model evolution), matching the client's
per-item-tolerant restores."""

from __future__ import annotations

import datetime as dt
import json
import re
import time
from typing import Literal

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
    # review=True marks a third-party writer: its POST /imports drafts
    # into the in-app approval queue instead of writing sync directly.
    # Default False (trusted) so existing mint flows are unchanged.
    review: bool = False


class ApiTokenOut(BaseModel):
    id: int
    name: str
    prefix: str
    scopes: list[str]
    review: bool = False


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
    # Opaque keyset cursor for the next page. Additive so older clients can
    # continue sending `since` and ignore this field.
    next_cursor: str | None = None


class GuardedChange(BaseModel):
    """A tombstone the mass-deletion guard withheld: the item stays on the
    server (and on every other device) instead of being deleted."""

    collection: str
    item_id: str
    reason: str = "mass deletion from a client that lost its local data"


class PushOut(BaseModel):
    applied: list[SyncRecord]
    server_time: dt.datetime
    guarded: list[GuardedChange] = []


class ItemUpsertIn(BaseModel):
    data: dict = Field(default_factory=dict)

    model_config = {"extra": "ignore"}

    @field_validator("data", mode="after")
    @classmethod
    def _check_size(cls, data: dict) -> dict:
        return _check_item_size(data)


# ── Feedback (in-app bug reports / feature requests) ────────────────────

FEEDBACK_KINDS = ("bug", "feature")
FEEDBACK_STATUSES = ("pending", "filed", "denied")


class FeedbackSubmitIn(BaseModel):
    kind: str = Field(pattern="^(bug|feature)$")
    title: str = Field(min_length=1, max_length=200)
    description: str = Field(min_length=1, max_length=8000)
    device: str = Field(default="", max_length=4000)
    extra: str = Field(default="", max_length=8000)
    app_platform: str = Field(default="", max_length=64)
    app_version: str = Field(default="", max_length=64)


class FeedbackOut(BaseModel):
    id: int
    kind: str
    title: str
    description: str
    device: str
    extra: str
    status: str
    github_issue_number: int | None = None
    github_issue_url: str = ""
    deny_reason: str = ""
    created_at: dt.datetime


class FeedbackAdminOut(FeedbackOut):
    email: str
    reviewed_by: str = ""
    reviewed_at: dt.datetime | None = None


class FeedbackStatusOut(BaseModel):
    is_admin: bool
    is_trusted: bool


class FeedbackApproveIn(BaseModel):
    trust_user: bool = False


class FeedbackDenyIn(BaseModel):
    reason: str = Field(default="", max_length=2000)


class TrustedAddIn(BaseModel):
    email: EmailStr


class TrustedOut(BaseModel):
    email: str
    added_by: str
    created_at: dt.datetime


# ── Staged imports (third-party writers + in-app approval) ─────────────

class ImportItemIn(BaseModel):
    collection: str
    item_id: str = Field(min_length=1, max_length=256)
    data: dict = Field(default_factory=dict)

    model_config = {"extra": "ignore"}

    @field_validator("data", mode="after")
    @classmethod
    def _check_size(cls, data: dict) -> dict:
        return _check_item_size(data)


class ImportCreateIn(BaseModel):
    items: list[ImportItemIn] = Field(min_length=1, max_length=200)
    source: str = Field(default="", max_length=120)


class ImportItemOut(BaseModel):
    collection: str
    item_id: str
    data: dict
    status: str = "pending"
    # Snapshot of the live sync row with the same collection+item_id,
    # so reviewers see "updates existing" instead of a silent overwrite.
    existing: dict | None = None
    # True when that live row is a tombstone (user deleted it in the
    # app): approving restores it. Surfaced so resurrection is explicit.
    existing_deleted: bool = False


class ImportBatchOut(BaseModel):
    id: int
    source: str
    status: str
    created_at: dt.datetime
    items: list[ImportItemOut] = Field(default_factory=list)


class ImportCreateOut(BaseModel):
    status: str  # "applied" | "pending"
    batch_id: int | None = None
    applied: list[SyncRecord] = Field(default_factory=list)


class ImportApproveIn(BaseModel):
    # None/empty means "approve every still-pending item".
    item_ids: list[str] | None = None


class ImportDiscardIn(BaseModel):
    item_ids: list[str] = Field(min_length=1)

# ── Content-free usage events ───────────────────────────────────────────
# The app records closed-set names and primitives only (see
# lib/common/usage/usage_event.dart). Validate that contract server-side:
# an authenticated client must not be able to store free text, and every
# field is bounded so a bad batch can only lose itself, never the DB.

_USAGE_TOKEN = re.compile(r"^[a-z0-9][a-z0-9_.:-]{0,63}$")
_USAGE_META_KEY = re.compile(r"^[a-z][a-z0-9_]{0,23}$")
_USAGE_META_VALUE = re.compile(r"^[a-z0-9][a-z0-9_.:-]{0,39}$")
_MAX_USAGE_META_KEYS = 8
_MAX_USAGE_EVENT_BYTES = 2048
_MAX_USAGE_BATCH_BYTES = 1024 * 1024


class UsageEventIn(BaseModel):
    id: str = Field(
        min_length=8, max_length=64, pattern=r"^[A-Za-z0-9_.:-]+$"
    )
    at: int = Field(ge=0)
    kind: Literal["app", "screen", "action", "error", "slow", "sync"]
    name: str = Field(pattern=r"^[a-z0-9][a-z0-9_.:-]{0,63}$")
    screen: str = Field(default="", max_length=64)
    duration_ms: int | None = Field(default=None, ge=0, le=86_400_000)
    meta: dict[str, str | int | float | bool] = Field(default_factory=dict)

    @field_validator("screen")
    @classmethod
    def _screen(cls, value: str) -> str:
        if value and not _USAGE_TOKEN.fullmatch(value):
            raise ValueError("screen must be a closed-set token")
        return value

    @field_validator("at")
    @classmethod
    def _at(cls, value: int) -> int:
        now_ms = int(time.time() * 1000)
        # Offline queues may lag; reject only absurd clocks so sorting and
        # retention stay sane.
        if value < now_ms - 90 * 86_400_000:
            raise ValueError("event is older than the retention window")
        if value > now_ms + 86_400_000:
            raise ValueError("event timestamp is in the future")
        return value

    @field_validator("meta")
    @classmethod
    def _meta(cls, value: dict) -> dict:
        if len(value) > _MAX_USAGE_META_KEYS:
            raise ValueError("too many meta keys")
        for key, item in value.items():
            if not _USAGE_META_KEY.fullmatch(key):
                raise ValueError(f"invalid meta key: {key!r}")
            if isinstance(item, str) and not _USAGE_META_VALUE.fullmatch(item):
                raise ValueError(f"meta value for {key!r} must be a short token")
        if len(json.dumps(value).encode("utf-8")) > _MAX_USAGE_EVENT_BYTES:
            raise ValueError("meta is too large")
        return value


class UsageBatchIn(BaseModel):
    events: list[UsageEventIn] = Field(default_factory=list, max_length=500)
    platform: str = Field(default="", max_length=32)
    session_id: str = Field(default="", max_length=64)

    @field_validator("platform")
    @classmethod
    def _platform(cls, value: str) -> str:
        if value and not _USAGE_TOKEN.fullmatch(value):
            raise ValueError("platform must be a closed-set token")
        return value

    @field_validator("session_id")
    @classmethod
    def _session(cls, value: str) -> str:
        if value and not _USAGE_TOKEN.fullmatch(value):
            raise ValueError("session_id must be a closed-set token")
        return value

    @model_validator(mode="after")
    def _batch_size(self) -> "UsageBatchIn":
        total = sum(len(json.dumps(e.model_dump()).encode("utf-8")) for e in self.events)
        if total > _MAX_USAGE_BATCH_BYTES:
            raise ValueError(f"usage batch exceeds {_MAX_USAGE_BATCH_BYTES} bytes")
        return self
