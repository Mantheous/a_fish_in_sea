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
