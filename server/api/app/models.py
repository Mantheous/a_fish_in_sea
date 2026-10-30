"""DB tables.

Sync strategy: one generic envelope table covers every client domain so
"everything at once" ships in a single migration and stays tolerant to
Dart model evolution (mirrors the per-item-tolerant Hydrated restores).
Typed per-collection validation lives in schemas.py, not in DDL.
"""

from __future__ import annotations

import datetime as dt

from sqlalchemy import (
    JSON,
    BigInteger,
    Boolean,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base

# Every HydratedBloc domain the Flutter app syncs. 'settings' is a
# singleton doc (item_id='singleton') in the same envelope.
COLLECTIONS = (
    "nodes",
    "events",
    "feeds",
    "transactions",
    "places",
    "reported_entries",
    "tracked_points",
    "settings",
    # Singleton docs (item_id='singleton'): client-only config that still
    # roams across devices. 'waterfall' = ledger view config (+ starting
    # balance); 'plaid' = bank-link identity (userId/wasConnected/itemId).
    # Live balances/transactions stay server-proxied, never stored here.
    "waterfall",
    "plaid",
    # Retired (client no longer syncs; kept server-side so old rows stay
    # readable): tasks, goals, tags, expenses, budgets, recurring_rules.
    "tasks",
    "goals",
    "tags",
    "expenses",
    "budgets",
    "recurring_rules",
)


def _utcnow() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    email: Mapped[str] = mapped_column(String(320), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(String(255))
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=_utcnow
    )


class ApiToken(Base):
    """Long-lived scoped token for MCP agents / secondary devices.

    `review` marks third-party writers: their POST /imports drafts into
    the approval queue instead of writing the sync envelope directly.
    Additive column (see init_db backfill); defaults to trusted.
    """

    __tablename__ = "api_tokens"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    name: Mapped[str] = mapped_column(String(120), default="")
    token_hash: Mapped[str] = mapped_column(String(128), unique=True)
    prefix: Mapped[str] = mapped_column(String(16), index=True)
    scopes: Mapped[list] = mapped_column(JSON, default=list)
    review: Mapped[bool] = mapped_column(Boolean, default=False)
    revoked: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=_utcnow
    )
    last_used_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )


class RefreshToken(Base):
    """Server-side refresh-token records for rotation + revocation.

    Access tokens stay stateless (15min); refresh tokens are tracked by
    jti so each use rotates (old token revoked, new one issued) and
    reuse of a revoked token kills the whole family (theft response).
    Only sha256 hashes are stored, never the JWT itself.
    """

    __tablename__ = "refresh_tokens"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    jti: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    token_hash: Mapped[str] = mapped_column(String(128), unique=True)
    revoked: Mapped[bool] = mapped_column(Boolean, default=False)
    replaced_by: Mapped[str] = mapped_column(String(64), default="")
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=_utcnow
    )
    expires_at: Mapped[dt.datetime] = mapped_column(DateTime(timezone=True))
    last_used_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )


class SyncItem(Base):
    __tablename__ = "sync_items"
    __table_args__ = (
        UniqueConstraint("user_id", "collection", "item_id"),
        Index("ix_sync_user_coll_updated", "user_id", "collection", "updated_at"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    collection: Mapped[str] = mapped_column(String(64), index=True)
    item_id: Mapped[str] = mapped_column(String(256), index=True)
    data: Mapped[dict] = mapped_column(JSON, default=dict)
    deleted: Mapped[bool] = mapped_column(Boolean, default=False)
    rev: Mapped[int] = mapped_column(Integer, default=1)
    updated_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=_utcnow, index=True
    )


class OAuthConnection(Base):
    """Per-user Plaid / Google secrets. Replaces .plaid_users.json and the
    single-user global .google_users.json. Tokens encrypted via Fernet when
    TOKEN_FERNET_KEY is set, else plaintext (dev only)."""

    __tablename__ = "oauth_connections"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    provider: Mapped[str] = mapped_column(String(32))  # 'plaid' | 'google' | 'canvas'
    access_token: Mapped[str] = mapped_column(Text, default="")
    refresh_token: Mapped[str] = mapped_column(Text, default="")
    item_id: Mapped[str] = mapped_column(String(256), default="")
    scopes: Mapped[str] = mapped_column(Text, default="")
    expires_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    updated_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=_utcnow
    )

    __table_args__ = (UniqueConstraint("user_id", "provider"),)


class FeedSnapshot(Base):
    """Server-side iCal fetch cache (server-side fetching slice).

    The worker (POST /fetch/refresh-due, or the optional interval
    scheduler) fetches each enabled http(s) feed and stores the raw ICS
    here. Clients read snapshots instead of fetching URLs themselves, so
    web/mobile see identical feed data with no CORS issues and no
    duplicate upstream traffic. Parsing stays client-side (Dart owns the
    recurrence/task heuristics); the server is a dumb-but-fresh cache.
    """

    __tablename__ = "feed_snapshots"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    feed_id: Mapped[str] = mapped_column(String(256), index=True)
    url: Mapped[str] = mapped_column(Text, default="")
    ics: Mapped[str] = mapped_column(Text, default="")
    etag: Mapped[str] = mapped_column(String(256), default="")
    status: Mapped[str] = mapped_column(String(16), default="ok")
    error: Mapped[str] = mapped_column(Text, default="")
    fetched_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=_utcnow
    )

    __table_args__ = (UniqueConstraint("user_id", "feed_id"),)


class FeedbackReport(Base):
    """In-app bug/feature report. Reporters only need an app account —
    the server files the GitHub issue with its own token.

    Status flow: untrusted submitters land in 'pending' for admin
    review; trusted reporters (see TrustedReporter) file immediately.
    'filed' means a GitHub issue exists (github_issue_url set).
    """

    __tablename__ = "feedback_reports"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    email: Mapped[str] = mapped_column(String(320), default="", index=True)
    kind: Mapped[str] = mapped_column(String(16), default="bug")  # bug|feature
    title: Mapped[str] = mapped_column(String(200), default="")
    description: Mapped[str] = mapped_column(Text, default="")
    device: Mapped[str] = mapped_column(Text, default="")
    extra: Mapped[str] = mapped_column(Text, default="")  # logs | proposal
    app_platform: Mapped[str] = mapped_column(String(64), default="")
    app_version: Mapped[str] = mapped_column(String(64), default="")
    status: Mapped[str] = mapped_column(String(16), default="pending", index=True)
    github_issue_number: Mapped[int | None] = mapped_column(
        Integer, nullable=True
    )
    github_issue_url: Mapped[str] = mapped_column(Text, default="")
    github_error: Mapped[str] = mapped_column(Text, default="")
    deny_reason: Mapped[str] = mapped_column(Text, default="")
    reviewed_by: Mapped[str] = mapped_column(String(320), default="")
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=_utcnow, index=True
    )
    reviewed_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )


class TrustedReporter(Base):
    """Allowlist by app-account email. Trusted reporters skip the review
    queue: their submissions file GitHub issues immediately."""

    __tablename__ = "trusted_reporters"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    email: Mapped[str] = mapped_column(String(320), unique=True, index=True)
    added_by: Mapped[str] = mapped_column(String(320), default="")
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=_utcnow
    )


class ImportBatch(Base):
    """Staged third-party import awaiting in-app approval.

    Unapproved items NEVER touch sync_items, so no device can see
    not-yet-approved data. Approving writes each item through the same
    upsert path as a manual edit (last-write-wins, rev bump, no
    tombstones) — the mass-deletion guard is structurally untouched.
    New tables only: no sync_items change, no client model change.
    """

    __tablename__ = "import_batches"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    source: Mapped[str] = mapped_column(String(120), default="")
    status: Mapped[str] = mapped_column(
        String(16), default="pending", index=True
    )  # pending|approved|rejected
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=_utcnow, index=True
    )


class ImportItem(Base):
    """One staged row inside a batch. `status` tracks the per-item
    decision so batches can be approved one-by-one."""

    __tablename__ = "import_items"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    batch_id: Mapped[int] = mapped_column(
        ForeignKey("import_batches.id"), index=True
    )
    collection: Mapped[str] = mapped_column(String(64), index=True)
    item_id: Mapped[str] = mapped_column(String(256), index=True)
    data: Mapped[dict] = mapped_column(JSON, default=dict)
    status: Mapped[str] = mapped_column(
        String(16), default="pending"
    )  # pending|approved|rejected
    decided_at: Mapped[dt.datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )


class UsageEvent(Base):
    """Content-free interaction events from the app (see lib/common/usage).

    Deliberately separate from `sync_items`: telemetry is append-only,
    best-effort, and never restored into the client. A corrupt row can only
    lose an event, never user data. User-supplied strings are validated to
    a closed alphabet in schemas.py, and retention is bounded by the
    endpoint's prune pass.
    """

    __tablename__ = "usage_events"
    __table_args__ = (
        UniqueConstraint("user_id", "event_id"),
        Index("ix_usage_user_received", "user_id", "received_at"),
        Index("ix_usage_user_name_received", "user_id", "name", "received_at"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    event_id: Mapped[str] = mapped_column(String(64))
    session_id: Mapped[str] = mapped_column(String(64), default="")
    kind: Mapped[str] = mapped_column(String(16))
    name: Mapped[str] = mapped_column(String(64))
    screen: Mapped[str] = mapped_column(String(64), default="")
    duration_ms: Mapped[int | None] = mapped_column(Integer, nullable=True)
    meta: Mapped[dict] = mapped_column(JSON, default=dict)
    platform: Mapped[str] = mapped_column(String(32), default="")
    # Client wall clock (epoch ms) for dwell/session reconstruction; the
    # server clock below is authoritative for retention and trends.
    client_at_ms: Mapped[int] = mapped_column(BigInteger, index=True)
    received_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), default=_utcnow, index=True
    )
