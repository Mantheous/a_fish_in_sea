"""Anki add-on ingest and review-history reads.

The Anki add-on (anki_addon/a_fish_in_sea) runs inside desktop Anki,
recomputes absolute per-day/per-deck review totals from `revlog`, and
posts them here. The app then reads the same rows on every platform —
no AnkiConnect, no server→laptop reachability, no localhost/CORS
constraints, and no card or note content ever leaving the collection.

Write side is scoped to `anki:write` tokens (minted in Settings → Anki);
read side needs `sync` scope, which the signed-in app already has.
Ingest is state-based and idempotent: each report is a rolling snapshot,
and the per-key maximum wins, so retries, restarts, and multi-device
collections converge instead of double-counting.
"""

from __future__ import annotations

import datetime as dt
import io
import json
import zipfile
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import dialect_insert, get_session
from ..deps import is_api_token, require_scope
from ..models import AnkiReportState, AnkiReviewDay, User
from ..ratelimit import limit
from ..schemas import (
    ANKI_MAX_RANGE_DAYS,
    AnkiDayOut,
    AnkiDeckOut,
    AnkiReportIn,
    AnkiReviewsOut,
    AnkiSummaryOut,
)

router = APIRouter(prefix="/anki", tags=["anki"])

# Packaged add-on source. The zip is built on demand so the download can
# never drift from the code in this repository.
_ADDON_SOURCE = (
    Path(__file__).resolve().parents[4] / "anki_addon" / "a_fish_in_sea"
)

# Old reports cannot grow the table without bound. 800 days comfortably
# covers a two-year goal window plus clock skew; the add-on itself sends
# at most ~2 years.
_MAX_AGE_DAYS = 800
_MAX_FUTURE_DAYS = 2
# Per-user row budget: 400 days x many decks is legitimate, but a leaked
# write token must not be able to grow the table without bound.
_MAX_USER_ROWS = 200_000

# SQLite and Postgres spell the two-argument maximum differently.
_MAX_FN = {"sqlite": func.max, "postgresql": func.greatest}


def _utcnow() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def _as_utc(value: dt.datetime | None) -> dt.datetime | None:
    """SQLite drops tzinfo on round-trip; the write path always stores UTC.
    Stamp it back so clients do not read a UTC instant as local time."""
    if value is None:
        return None
    if value.tzinfo is None:
        return value.replace(tzinfo=dt.timezone.utc)
    return value


def _max_expr(dialect: str, column, incoming):
    fn = _MAX_FN.get(dialect, func.greatest)
    return fn(column, incoming)


@router.get("/addon")
async def download_addon(
    _rl: None = Depends(limit("anki:addon", 10, 60)),
):
    """The installable add-on archive, built from the repository source.

    Public on purpose: it contains no secrets (config.json ships blank),
    and a signed-out browser still needs to be able to fetch it.
    """
    if not _ADDON_SOURCE.is_dir():
        raise HTTPException(status_code=404, detail="Add-on source not packaged")
    blank_config = json.dumps(
        {
            "server_url": "",
            "api_token": "",
            "enabled": True,
            "report_days": 400,
            "rollover_hour": 0,
        },
        indent=2,
    )
    allowed_suffixes = {".py", ".md"}
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(_ADDON_SOURCE.rglob("*")):
            if not path.is_file() or path.is_symlink():
                continue
            if "__pycache__" in path.parts or path.suffix == ".pyc":
                continue
            if path.name == "config.json":
                # Never ship a populated config from a developer's tree:
                # generate a blank one even if the source has a token.
                archive.writestr("config.json", blank_config)
                continue
            if path.name != "manifest.json" and path.suffix not in allowed_suffixes:
                continue
            archive.write(path, path.relative_to(_ADDON_SOURCE).as_posix())
    return Response(
        content=buffer.getvalue(),
        media_type="application/octet-stream",
        headers={
            "Content-Disposition": (
                'attachment; filename="a_fish_in_sea.ankiaddon"'
            ),
            "Cache-Control": "no-store",
        },
    )


@router.post("/report")
async def report(
    body: AnkiReportIn,
    user: User = Depends(require_scope("anki:write")),
    session: AsyncSession = Depends(get_session),
    _rl: None = Depends(limit("anki:report", 30, 60, by_user=True)),
):
    """Store the add-on's rolling per-day/per-deck totals."""
    now = _utcnow()
    today = now.date()
    earliest = today - dt.timedelta(days=_MAX_AGE_DAYS)
    latest = today + dt.timedelta(days=_MAX_FUTURE_DAYS)

    # One row per (day, deck) per report, keeping the larger count. A
    # buggy client repeating a key must not be able to inflate anything.
    merged: dict[tuple[dt.date, str], tuple[int, int]] = {}
    for item in body.days:
        if item.day < earliest or item.day > latest:
            raise HTTPException(
                status_code=400,
                detail=(
                    f"Report day {item.day.isoformat()} is outside the "
                    f"{_MAX_AGE_DAYS}-day window ending {latest.isoformat()}."
                ),
            )
        key = (item.day, item.deck)
        prev = merged.get(key)
        if prev is None:
            merged[key] = (item.cards, item.reviews)
        else:
            merged[key] = (max(prev[0], item.cards), max(prev[1], item.reviews))

    rows = [
        {
            "user_id": user.id,
            "day": day,
            "deck": deck,
            "cards": cards,
            "reviews": reviews,
            "updated_at": now,
        }
        for (day, deck), (cards, reviews) in merged.items()
    ]

    total_rows = (
        await session.execute(
            select(func.count())
            .select_from(AnkiReviewDay)
            .where(AnkiReviewDay.user_id == user.id)
        )
    ).scalar_one()
    if int(total_rows) + len(rows) > _MAX_USER_ROWS:
        raise HTTPException(
            status_code=429,
            detail=(
                "Anki history cap reached; prune old history before "
                "reporting more days."
            ),
        )

    dialect = session.get_bind().dialect.name
    # Stay under SQLite's historical 999-variable limit (6 columns/row).
    for offset in range(0, len(rows), 100):
        chunk = rows[offset : offset + 100]
        stmt = dialect_insert(AnkiReviewDay).values(chunk)
        stmt = stmt.on_conflict_do_update(
            index_elements=["user_id", "day", "deck"],
            set_={
                "cards": _max_expr(
                    dialect,
                    AnkiReviewDay.__table__.c.cards,
                    stmt.excluded.cards,
                ),
                "reviews": _max_expr(
                    dialect,
                    AnkiReviewDay.__table__.c.reviews,
                    stmt.excluded.reviews,
                ),
                "updated_at": now,
            },
            # A repeat report over an unchanged window must not rewrite
            # hundreds of rows every few minutes.
            where=(
                (stmt.excluded.cards > AnkiReviewDay.__table__.c.cards)
                | (stmt.excluded.reviews > AnkiReviewDay.__table__.c.reviews)
            ),
        )
        await session.execute(stmt)

    state = dialect_insert(AnkiReportState).values(
        user_id=user.id,
        last_report_at=now,
        last_rows=len(rows),
        client=body.client,
    )
    state = state.on_conflict_do_update(
        index_elements=["user_id"],
        set_={
            "last_report_at": now,
            "last_rows": len(rows),
            "client": body.client,
        },
    )
    await session.execute(state)
    await session.commit()
    return {
        "ok": True,
        "accepted": len(rows),
        "last_report_at": now.isoformat(),
    }


@router.get("/summary", response_model=AnkiSummaryOut)
async def summary(
    user: User = Depends(require_scope("anki:write")),
    session: AsyncSession = Depends(get_session),
    _rl: None = Depends(limit("anki:summary", 60, 60, by_user=True)),
):
    """Connection test for the add-on: proves the token works and reports
    the last accepted upload. Contains no card content."""
    today = dt.date.today()
    week_ago = today - dt.timedelta(days=6)
    recent = (
        await session.execute(
            select(
                func.coalesce(func.sum(AnkiReviewDay.cards), 0),
                func.coalesce(func.sum(AnkiReviewDay.reviews), 0),
            ).where(
                AnkiReviewDay.user_id == user.id,
                AnkiReviewDay.day >= week_ago,
            )
        )
    ).one()
    decks = (
        await session.execute(
            select(func.count(func.distinct(AnkiReviewDay.deck))).where(
                AnkiReviewDay.user_id == user.id,
                AnkiReviewDay.day >= today - dt.timedelta(days=90),
            )
        )
    ).scalar_one()
    days = (
        await session.execute(
            select(func.count(func.distinct(AnkiReviewDay.day))).where(
                AnkiReviewDay.user_id == user.id,
                AnkiReviewDay.day >= today - dt.timedelta(days=400),
            )
        )
    ).scalar_one()
    state = (
        await session.execute(
            select(AnkiReportState).where(AnkiReportState.user_id == user.id)
        )
    ).scalar_one_or_none()
    return AnkiSummaryOut(
        # A write-only token should not disclose the account email; the
        # signed-in app (JWT) still gets it.
        email="" if is_api_token(user) else user.email,
        last_report_at=_as_utc(state.last_report_at) if state else None,
        last_client=state.client if state else "",
        decks=int(decks or 0),
        days=int(days or 0),
        cards_7d=int(recent[0] or 0),
        reviews_7d=int(recent[1] or 0),
    )


@router.get("/reviews", response_model=AnkiReviewsOut)
async def reviews(
    start: dt.date | None = Query(default=None),
    end: dt.date | None = Query(default=None),
    user: User = Depends(require_scope("sync")),
    session: AsyncSession = Depends(get_session),
    _rl: None = Depends(limit("anki:reviews", 60, 60, by_user=True)),
):
    """Daily per-deck totals for the app's memorization goals."""
    end_day = end or dt.date.today()
    start_day = start or (end_day - dt.timedelta(days=ANKI_MAX_RANGE_DAYS - 1))
    if start_day > end_day:
        raise HTTPException(status_code=400, detail="start must be before end")
    if (end_day - start_day).days >= ANKI_MAX_RANGE_DAYS:
        raise HTTPException(
            status_code=400,
            detail=f"range must be under {ANKI_MAX_RANGE_DAYS} days",
        )

    rows = (
        await session.execute(
            select(
                AnkiReviewDay.day,
                AnkiReviewDay.deck,
                AnkiReviewDay.cards,
                AnkiReviewDay.reviews,
            )
            .where(
                AnkiReviewDay.user_id == user.id,
                AnkiReviewDay.day >= start_day,
                AnkiReviewDay.day <= end_day,
            )
            .order_by(AnkiReviewDay.day, AnkiReviewDay.deck)
        )
    ).all()

    days: list[AnkiDayOut] = []
    by_deck: dict[str, dict] = {}
    for day, deck, cards, revs in rows:
        days.append(
            AnkiDayOut(day=day, deck=deck, cards=int(cards), reviews=int(revs))
        )
        entry = by_deck.setdefault(
            deck,
            {"cards": 0, "reviews": 0, "last_day": None},
        )
        entry["cards"] += int(cards)
        entry["reviews"] += int(revs)
        if entry["last_day"] is None or day > entry["last_day"]:
            entry["last_day"] = day

    decks = [
        AnkiDeckOut(
            name=name,
            cards=item["cards"],
            reviews=item["reviews"],
            last_day=item["last_day"],
        )
        for name, item in sorted(by_deck.items())
    ]

    state = (
        await session.execute(
            select(AnkiReportState).where(AnkiReportState.user_id == user.id)
        )
    ).scalar_one_or_none()
    return AnkiReviewsOut(
        days=days,
        decks=decks,
        last_report_at=_as_utc(state.last_report_at) if state else None,
        last_client=state.client if state else "",
    )
