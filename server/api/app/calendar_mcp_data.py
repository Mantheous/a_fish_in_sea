"""Calendar-only operations over existing sync rows; no schema changes."""

from __future__ import annotations

import datetime as dt
import uuid
from zoneinfo import ZoneInfo

from pydantic import BaseModel, ConfigDict, Field, model_validator
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from .deps import check_token_scope
from .models import SyncItem, User


class EventFields(BaseModel):
    """Only calendar fields, never links, timer history, or imported identity."""

    model_config = ConfigDict(extra="forbid", strict=True)
    subject: str | None = Field(default=None, min_length=1, max_length=1000)
    start: str | None = None
    end: str | None = None
    allDay: bool = False
    notes: str | None = Field(default=None, max_length=50000)
    location: str | None = Field(default=None, max_length=2000)
    reminderMinutesBefore: int | None = Field(default=None, ge=1, le=525600)

    @model_validator(mode="after")
    def validate_values(self):
        for key in ("subject", "start", "end", "allDay"):
            if key in self.model_fields_set and getattr(self, key) is None:
                raise ValueError(f"{key} cannot be null")
        if self.subject is not None and not self.subject.strip():
            raise ValueError("subject must not be blank")
        for key in ("start", "end"):
            value = getattr(self, key)
            if value is not None and dt.datetime.fromisoformat(value).tzinfo is None:
                raise ValueError(f"{key} must include a UTC offset, e.g. -07:00")
        return self


def instant(value: str, timezone: str) -> dt.datetime:
    value_dt = dt.datetime.fromisoformat(value)
    if value_dt.tzinfo is None:
        # Older Flutter records contain device-local ISO strings.
        value_dt = value_dt.replace(tzinfo=ZoneInfo(timezone))
    return value_dt.astimezone(dt.timezone.utc)


def record(row: SyncItem, timezone: str) -> dict:
    data = dict(row.data)
    for key in ("start", "end"):
        data[key] = instant(data[key], timezone).astimezone(ZoneInfo(timezone)).isoformat()
    return {"event_id": row.item_id, "revision": row.rev, "event": data}


async def event_row(session: AsyncSession, user: User, event_id: str) -> SyncItem:
    row = (await session.execute(select(SyncItem).where(
        SyncItem.user_id == user.id, SyncItem.collection == "events",
        SyncItem.item_id == event_id, SyncItem.deleted.is_(False),
    ))).scalar_one_or_none()
    if row is None:
        raise ValueError("Event not found")
    return row


async def list_events(session: AsyncSession, user: User, start: str, end: str,
                      timezone: str, cursor: int, limit: int) -> dict:
    check_token_scope(user, "calendar:read", "calendar:write", "events:read", "events:write")
    ZoneInfo(timezone)
    lo, hi = instant(start, timezone), instant(end, timezone)
    if hi <= lo or hi - lo > dt.timedelta(days=366):
        raise ValueError("Choose a positive date range of at most 366 days")
    # Scan bounded pages with a continuation even when no dates match.
    # Row ids give stable pagination without truncating large calendars.
    rows = list((await session.execute(select(SyncItem).where(
        SyncItem.user_id == user.id, SyncItem.collection == "events",
        SyncItem.deleted.is_(False), SyncItem.id > cursor,
    ).order_by(SyncItem.id).limit(501))).scalars())
    events, skipped, scanned = [], 0, cursor
    for row in rows[:500]:
        scanned = row.id
        try:
            data = row.data
            begins, ends = instant(data["start"], timezone), instant(data["end"], timezone)
            if data.get("allDay"):
                # Flutter treats an all-day end date as inclusive.
                local_end = ends.astimezone(ZoneInfo(timezone))
                next_day = local_end.date() + dt.timedelta(days=1)
                ends = dt.datetime.combine(next_day, dt.time(), ZoneInfo(timezone)).astimezone(dt.timezone.utc)
            if (begins < hi and ends > lo) or (lo <= begins < hi and ends == begins):
                events.append(record(row, timezone))
        except (ValueError, TypeError, KeyError):
            skipped += 1
        if len(events) >= limit:
            break
    more = any(row.id > scanned for row in rows)
    return {"events": events, "next_cursor": scanned if more else None,
            "skipped_invalid": skipped, "timezone": timezone,
            "note": "Synced event records only. Recurrence rules are not expanded; "
                    "follow next_cursor until null to finish the range. "
                    "Unsynced device changes and upstream feed changes may be absent."}


async def list_calendars(session: AsyncSession, user: User, cursor: int) -> dict:
    check_token_scope(user, "calendar:read", "calendar:write", "feeds:read", "feeds:write")
    rows = list((await session.execute(select(SyncItem).where(
        SyncItem.user_id == user.id, SyncItem.collection == "feeds",
        SyncItem.deleted.is_(False), SyncItem.id > cursor,
    ).order_by(SyncItem.id).limit(101))).scalars())
    # Feed URLs often contain private access tokens: never expose them.
    calendars = [{"id": "personal", "name": "Personal", "writable": True}] if cursor == 0 else []
    for row in rows[:100]:
        data = row.data if isinstance(row.data, dict) else {}
        calendars.append({"id": row.item_id, "name": data.get("name", ""),
                          "kind": data.get("kind", "other"), "writable": False,
                          "enabled": data.get("enabled", True)})
    return {"calendars": calendars, "next_cursor": rows[99].id if len(rows) > 100 else None}


def validate_span(data: dict, timezone: str):
    start, end = instant(data["start"], timezone), instant(data["end"], timezone)
    if end < start or (end == start and not data.get("allDay", False)):
        raise ValueError("Event end must be after start (all-day events may end on the same day)")


def require_editable(row: SyncItem):
    data = row.data
    if any(data.get(k) for k in ("feedId", "sourceUid", "seriesId", "recurrenceRule", "taskId", "isTask")):
        raise ValueError("Imported, recurring, and goal-linked events must be edited in the app or source calendar")


async def create_event(session: AsyncSession, user: User, fields: EventFields,
                       timezone: str) -> dict:
    check_token_scope(user, "calendar:write", "events:write")
    data = fields.model_dump()
    if any(data[k] is None for k in ("subject", "start", "end")):
        raise ValueError("subject, start, and end are required")
    ZoneInfo(timezone)
    validate_span(data, timezone)
    data["id"] = str(uuid.uuid4())
    row = SyncItem(user_id=user.id, collection="events", item_id=data["id"],
                   data=data, rev=1, updated_at=dt.datetime.now(dt.timezone.utc))
    session.add(row)
    await session.commit()
    return record(row, timezone)


async def change_event(session: AsyncSession, user: User, event_id: str,
                       revision: int, timezone: str, fields: EventFields | None) -> dict:
    check_token_scope(user, "calendar:write", "events:write")
    ZoneInfo(timezone)
    row = await event_row(session, user, event_id)
    require_editable(row)
    data = dict(row.data)
    if fields is not None:
        patch = fields.model_dump(exclude_unset=True)
        if not patch:
            raise ValueError("Provide at least one field to update")
        data.update(patch)
        validate_span(data, timezone)
    # Compare-and-swap prevents stale tools from overwriting a newer sync.
    result = await session.execute(update(SyncItem).where(
        SyncItem.id == row.id, SyncItem.rev == revision, SyncItem.deleted.is_(False),
    ).values(data=data, deleted=fields is None, rev=revision + 1,
             updated_at=dt.datetime.now(dt.timezone.utc)),
        execution_options={"synchronize_session": False})
    if result.rowcount != 1:
        await session.rollback()
        raise ValueError("Revision conflict: fetch the event again before changing it")
    await session.commit()
    await session.refresh(row)
    if fields is None:
        return {"event_id": event_id, "revision": row.rev, "deleted": True}
    return record(row, timezone)
