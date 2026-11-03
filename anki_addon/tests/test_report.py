"""Unit tests for the add-on's pure aggregation rules.

Runs without Anki: `python -m unittest discover anki_addon/tests`.
"""

from __future__ import annotations

import datetime as dt
import sqlite3
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "a_fish_in_sea"))

import report  # noqa: E402


def fixed_local(ms: float) -> dt.datetime:
    """Deterministic local time for tests: UTC-7, no DST."""
    return dt.datetime.fromtimestamp(ms, dt.timezone(dt.timedelta(hours=-7)))


def at(day: int, hour: int = 12) -> int:
    moment = dt.datetime(2026, 11, day, hour, tzinfo=dt.timezone(dt.timedelta(hours=-7)))
    return int(moment.timestamp() * 1000)


NAMES = {1: "Japanese", 2: "Japanese::Vocab", 3: "Math"}


class AggregateTest(unittest.TestCase):
    def test_counts_distinct_cards_and_answers(self):
        rows = [
            (at(2), 1, 100),
            (at(2), 1, 100),  # same card again: one card, two answers
            (at(2), 1, 101),
            (at(2), 2, 200),
            (at(3), 1, 100),
        ]
        out = report.aggregate(
            rows, NAMES, local_fromtimestamp=fixed_local
        )
        by_key = {(d["day"], d["deck"]): d for d in out}
        self.assertEqual(by_key[("2026-11-02", "Japanese")]["cards"], 2)
        self.assertEqual(by_key[("2026-11-02", "Japanese")]["reviews"], 3)
        self.assertEqual(by_key[("2026-11-02", "Japanese::Vocab")]["cards"], 1)
        self.assertEqual(by_key[("2026-11-03", "Japanese")]["cards"], 1)

    def test_skips_deleted_cards_and_unknown_decks(self):
        rows = [
            (at(2), None, 100),  # card deleted since the review
            (at(2), 99, 101),  # deck no longer resolvable
            (at(2), 1, 102),
        ]
        out = report.aggregate(rows, NAMES, local_fromtimestamp=fixed_local)
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["deck"], "Japanese")

    def test_rollover_hour_shifts_late_reviews_to_previous_day(self):
        rows = [(at(3, hour=2), 1, 100)]
        midnight = report.aggregate(
            rows, NAMES, rollover_hour=0, local_fromtimestamp=fixed_local
        )
        anki_day = report.aggregate(
            rows, NAMES, rollover_hour=4, local_fromtimestamp=fixed_local
        )
        self.assertEqual(midnight[0]["day"], "2026-11-03")
        self.assertEqual(anki_day[0]["day"], "2026-11-02")

    def test_payload_shape(self):
        payload = report.build_payload(
            [(at(2), 1, 100)],
            NAMES,
            local_fromtimestamp=fixed_local,
        )
        self.assertEqual(payload["version"], 1)
        self.assertEqual(payload["client"], report.CLIENT)
        self.assertEqual(
            payload["days"],
            [
                {
                    "day": "2026-11-02",
                    "deck": "Japanese",
                    "cards": 1,
                    "reviews": 1,
                }
            ],
        )

    def test_payload_trims_to_the_newest_rows(self):
        original = report.MAX_REPORT_ROWS
        report.MAX_REPORT_ROWS = 2
        try:
            rows = [
                (at(1), 1, 100),
                (at(2), 1, 100),
                (at(3), 1, 100),
            ]
            payload = report.build_payload(
                rows, NAMES, local_fromtimestamp=fixed_local
            )
            self.assertEqual(
                [d["day"] for d in payload["days"]],
                ["2026-11-02", "2026-11-03"],
            )
        finally:
            report.MAX_REPORT_ROWS = original

    def test_cutoff_is_epoch_ms(self):
        now = dt.datetime(2026, 11, 10, 12, tzinfo=dt.timezone.utc)
        self.assertEqual(
            report.cutoff_ms(7, now=now),
            int(dt.datetime(2026, 11, 3, 12, tzinfo=dt.timezone.utc).timestamp() * 1000),
        )


class _AnkiDb:
    """Minimal stand-in for Anki's `col.db` wrapper."""

    def __init__(self, conn: sqlite3.Connection) -> None:
        self.conn = conn

    def all(self, sql: str, *args):
        return self.conn.execute(sql, args).fetchall()


class QueryTest(unittest.TestCase):
    def test_query_reads_revlog_with_deck_ids(self):
        db = sqlite3.connect(":memory:")
        db.execute("CREATE TABLE cards (id INTEGER PRIMARY KEY, did INTEGER)")
        db.execute(
            "CREATE TABLE revlog (id INTEGER PRIMARY KEY, cid INTEGER, "
            "type INTEGER NOT NULL DEFAULT 1)"
        )
        db.execute("INSERT INTO cards VALUES (100, 1), (101, 2)")
        db.execute(
            "INSERT INTO revlog VALUES (1000, 100, 1), (2000, 101, 1), "
            "(3000, 999, 1), (1500, 100, 4)"
        )
        rows = report.query_reviews(_AnkiDb(db), 0)
        self.assertEqual(
            sorted(rows),
            [(1000, 1, 100), (2000, 2, 101), (3000, None, 999)],
        )
        self.assertEqual(
            report.query_reviews(_AnkiDb(db), 1500),
            [(2000, 2, 101), (3000, None, 999)],
        )


if __name__ == "__main__":
    unittest.main()
