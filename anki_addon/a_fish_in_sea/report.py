"""Pure review-history aggregation for the A Fish in Sea Anki add-on.

This module deliberately imports only the standard library and does not
touch `aqt`, so its rules can be unit-tested without an Anki install.
The add-on's `__init__.py` supplies the collection database and deck
names; everything here is a deterministic function of (rows, names).

Why absolute rolling totals instead of an increment queue:
- A report can be lost, retried, or interrupted without double counting.
- Manual reschedules (revlog.type 4/5, rating 0) are excluded so setting a
  due date is not mistaken for studying.
- Anki restarts and multiple profiles converge on the same values.
- The server keeps the per-day/per-deck maximum, so a stale report can
  never shrink history.
"""

from __future__ import annotations

import datetime as dt
from typing import Any, Callable, Iterable

CLIENT = "a-fish-in-sea-anki/1.0"
MAX_REPORT_ROWS = 12_000

# One indexed scan of the review log. The LEFT JOIN keeps the query cheap
# and is deliberate: reviews of cards deleted since then have no deck row
# and are skipped by the aggregator (they cannot belong to a goal).
REVIEWS_SQL = """
SELECT r.id, c.did, r.cid
FROM revlog r
LEFT JOIN cards c ON c.id = r.cid
WHERE r.id >= ? AND r.type IN (0, 1, 2, 3)
"""


def query_reviews(db: Any, cutoff_ms: int) -> list[tuple[int, int | None, int]]:
    """Read raw review rows from an Anki collection DB wrapper."""
    return [tuple(row) for row in db.all(REVIEWS_SQL, int(cutoff_ms))]


def _default_local(ms: float) -> dt.datetime:
    # fromtimestamp (not utcfromtimestamp) applies the OS timezone for
    # *that* instant, so historical DST changes are handled correctly.
    return dt.datetime.fromtimestamp(ms)


def aggregate(
    rows: Iterable[tuple[int, int | None, int]],
    deck_names: dict[int, str],
    *,
    rollover_hour: int = 0,
    local_fromtimestamp: Callable[[float], dt.datetime] | None = None,
) -> list[dict]:
    """Bucket review rows into per-day, per-deck absolute totals.

    `rows` are `(review_ms, deck_id, card_id)`. A card answered twice in
    the same day/deck counts once in `cards` but twice in `reviews` — the
    app's goals use `cards`, mirroring Anki's "cards studied" stat.
    """
    to_local = local_fromtimestamp or _default_local
    rollover = dt.timedelta(hours=max(0, min(23, int(rollover_hour))))
    buckets: dict[tuple[dt.date, str], dict] = {}

    for ms, did, cid in rows:
        if did is None:
            continue
        name = deck_names.get(int(did))
        if not name:
            continue
        moment = to_local(int(ms) / 1000.0)
        if rollover:
            moment -= rollover
        day = moment.date()
        key = (day, name)
        bucket = buckets.get(key)
        if bucket is None:
            bucket = {"cards": set(), "reviews": 0}
            buckets[key] = bucket
        bucket["cards"].add(int(cid))
        bucket["reviews"] += 1

    out = []
    for (day, name), bucket in sorted(buckets.items()):
        out.append(
            {
                "day": day.isoformat(),
                "deck": name,
                "cards": len(bucket["cards"]),
                "reviews": bucket["reviews"],
            }
        )
    return out


def build_payload(
    rows: Iterable[tuple[int, int | None, int]],
    deck_names: dict[int, str],
    *,
    rollover_hour: int = 0,
    local_fromtimestamp: Callable[[float], dt.datetime] | None = None,
) -> dict:
    """The exact JSON body accepted by POST /api/v1/anki/report."""
    days = aggregate(
        rows,
        deck_names,
        rollover_hour=rollover_hour,
        local_fromtimestamp=local_fromtimestamp,
    )
    if len(days) > MAX_REPORT_ROWS:
        # Keep the newest days; the server's per-key max means dropping
        # older rows only trims history, never corrupts recent totals.
        days = sorted(days, key=lambda d: d["day"])[-MAX_REPORT_ROWS:]
    return {"version": 1, "client": CLIENT, "days": days}


def cutoff_ms(days: int, now: dt.datetime | None = None) -> int:
    """Epoch-ms lower bound for a report covering [now - days, now]."""
    moment = now or dt.datetime.now()
    start = moment - dt.timedelta(days=max(1, int(days)))
    return int(start.timestamp() * 1000)
