#!/usr/bin/env python3
"""Deterministic usage digest for the proactive usage review.

Reads the loop host's SQLite DB READ-ONLY and turns content-free app events
into facts an LLM can interpret. It does not judge, file issues, or modify
anything: thresholds live in usage-walk.sh / the usage role prompt so this
script stays a stable stopwatch + counter (same design as perf-walk.sh).

Privacy: events contain only closed-set names and primitives. The account
email is printed to stderr (journal) for the operator and never written to
the digest the model sees.

Usage:
  tools/agent/usage-digest.py --out-dir /tmp/opencode/usage-20261029
Env:
  USAGE_DB           default server/api/data/app.db
  USAGE_USER_EMAIL   account to analyze (else inferred)
  USAGE_USER_ID      explicit user id override
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import statistics
import sys
import time
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

DAY_MS = 86_400_000
SESSION_GAP_MS = 30 * 60 * 1000
TEST_EMAIL_MARKERS = (
    "@example.com",
    "patrol-",
    "perf-",
    "perf-walk-",
    "ux-walker",
    "uxtest-",
    "probe",
    "smoke",
    "canvas-smoke",
    "diag-probe",
    "webprobe",
    "verify",
)


def _connect(db: Path) -> sqlite3.Connection:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5.0)
    con.row_factory = sqlite3.Row
    return con


def _parse_meta(raw: str | None) -> dict:
    if not raw:
        return {}
    try:
        value = json.loads(raw)
        return value if isinstance(value, dict) else {}
    except (TypeError, ValueError):
        return {}


def _pick_user(con: sqlite3.Connection, days: int) -> sqlite3.Row | None:
    email = os.getenv("USAGE_USER_EMAIL", "").strip()
    if email:
        row = con.execute("SELECT id, email FROM users WHERE email = ?", (email,)).fetchone()
        if row is None:
            raise SystemExit(f"usage-digest: no user with email {email!r}")
        return row
    uid = os.getenv("USAGE_USER_ID", "").strip()
    if uid:
        row = con.execute("SELECT id, email FROM users WHERE id = ?", (int(uid),)).fetchone()
        if row is None:
            raise SystemExit(f"usage-digest: no user with id {uid}")
        return row

    since_ms = int(time.time() * 1000) - days * DAY_MS
    rows = con.execute(
        """
        SELECT u.id, u.email, COUNT(e.id) AS n
        FROM users u
        LEFT JOIN usage_events e
          ON e.user_id = u.id AND e.client_at_ms >= ?
        GROUP BY u.id
        HAVING n > 0
        ORDER BY n DESC
        """,
        (since_ms,),
    ).fetchall()
    for row in rows:
        email = (row["email"] or "").lower()
        if not any(marker in email for marker in TEST_EMAIL_MARKERS):
            return row
    # No real usage yet: fall back to the busiest non-test sync account so
    # the first run can still report "instrumented, no events".
    rows = con.execute(
        """
        SELECT u.id, u.email, COUNT(s.id) AS n
        FROM users u
        LEFT JOIN sync_items s ON s.user_id = u.id
        GROUP BY u.id
        ORDER BY n DESC
        """
    ).fetchall()
    for row in rows:
        email = (row["email"] or "").lower()
        if not any(marker in email for marker in TEST_EMAIL_MARKERS):
            return row
    return None


def _pct(values: list[int], p: int) -> int:
    if not values:
        return 0
    ordered = sorted(values)
    idx = min(len(ordered) - 1, int(round((p / 100) * (len(ordered) - 1))))
    return int(ordered[idx])


def _feature_uses(
    feature: dict, events: list[sqlite3.Row]
) -> int:
    where = feature.get("where") or {}
    kind = feature.get("kind")
    name = feature.get("event")
    count = 0
    for event in events:
        if event["kind"] != kind or event["name"] != name:
            continue
        if where:
            meta = _parse_meta(event["meta"])
            if any(meta.get(k) != v for k, v in where.items()):
                continue
        count += 1
    return count


def build_digest(db: Path, days: int, features_path: Path) -> dict:
    now_ms = int(time.time() * 1000)
    since_ms = now_ms - days * DAY_MS
    con = _connect(db)
    try:
        tables = {
            row[0]
            for row in con.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table'"
            ).fetchall()
        }
        if "usage_events" not in tables:
            return {
                "ok": False,
                "reason": "usage_events table does not exist yet (deploy the endpoint first)",
                "generated_at": datetime.now(timezone.utc).isoformat(),
            }
        user = _pick_user(con, days)
        if user is None:
            return {
                "ok": False,
                "reason": "no non-test account found",
                "generated_at": datetime.now(timezone.utc).isoformat(),
            }
        user_id = int(user["id"])
        print(f"usage-digest: analyzing user {user_id} ({user['email']})", file=sys.stderr)

        events = con.execute(
            """
            SELECT event_id, kind, name, screen, duration_ms, meta, platform,
                   session_id, client_at_ms, received_at
            FROM usage_events
            WHERE user_id = ? AND client_at_ms >= ? AND client_at_ms IS NOT NULL
            ORDER BY client_at_ms ASC
            """,
            (user_id, since_ms),
        ).fetchall()
        all_events = con.execute(
            """
            SELECT kind, name, meta, MAX(client_at_ms) AS last_ms
            FROM usage_events
            WHERE user_id = ?
            GROUP BY kind, name, meta
            """,
            (user_id,),
        ).fetchall()
        first = con.execute(
            "SELECT MIN(client_at_ms) AS first_ms FROM usage_events WHERE user_id = ?",
            (user_id,),
        ).fetchone()
        total_events = con.execute(
            "SELECT COUNT(*) AS n FROM usage_events WHERE user_id = ?",
            (user_id,),
        ).fetchone()["n"]
    finally:
        con.close()

    history_days = 0.0
    if first and first["first_ms"]:
        history_days = max(0.0, (now_ms - int(first["first_ms"])) / DAY_MS)

    # Sessions: gaps over 30 min start a new sitting. Also track the most
    # often repeated single action within one sitting (a cheap rage/repeat
    # signal); grouping by session needs the ordered walk, not a global
    # count.
    sessions = 0
    prev = None
    session_actions: Counter[str] = Counter()
    session_action_max = 0
    active_days = set()
    for event in events:
        ts = int(event["client_at_ms"])
        active_days.add(datetime.fromtimestamp(ts / 1000, timezone.utc).date().isoformat())
        if prev is None or ts - prev > SESSION_GAP_MS:
            session_action_max = max(
                session_action_max, max(session_actions.values(), default=0)
            )
            session_actions = Counter()
            sessions += 1
        prev = ts
        if event["kind"] == "action":
            session_actions[event["name"]] += 1
    session_action_max = max(
        session_action_max, max(session_actions.values(), default=0)
    )

    screens: dict[str, dict] = defaultdict(
        lambda: {"visits": 0, "durations": [], "quick_backs": 0, "last_ms": 0}
    )
    actions: dict[str, dict] = defaultdict(
        lambda: {"count": 0, "last_ms": 0, "meta": Counter()}
    )
    errors: Counter[tuple] = Counter()
    slow: dict[str, list[int]] = defaultdict(list)
    sync_failures = 0
    platform_counts: Counter[str] = Counter()

    for event in events:
        kind = event["kind"]
        name = event["name"] or "unknown"
        ts = int(event["client_at_ms"])
        platform_counts[event["platform"] or "unknown"] += 1
        if kind == "screen":
            entry = screens[name]
            entry["visits"] += 1
            entry["last_ms"] = max(entry["last_ms"], ts)
            duration = event["duration_ms"]
            if duration is not None:
                entry["durations"].append(int(duration))
                if int(duration) < 3000:
                    entry["quick_backs"] += 1
        elif kind == "action":
            entry = actions[name]
            entry["count"] += 1
            entry["last_ms"] = max(entry["last_ms"], ts)
            for key, value in _parse_meta(event["meta"]).items():
                entry["meta"][f"{key}={value}"] += 1
        elif kind == "error":
            meta = _parse_meta(event["meta"])
            errors[(name, str(meta.get("type", "")), event["screen"] or "")] += 1
        elif kind == "slow":
            slow[name].append(int(event["duration_ms"] or 0))
        elif kind == "sync":
            sync_failures += 1

    last_by_name: dict[tuple[str, str], int] = {}
    for row in all_events:
        key = (row["kind"], row["name"])
        last_by_name[key] = max(last_by_name.get(key, 0), int(row["last_ms"] or 0))

    features = json.loads(features_path.read_text())["features"]
    feature_out = []
    for feature in features:
        uses = _feature_uses(feature, events)
        last_ms = last_by_name.get((feature.get("kind"), feature.get("event")), 0)
        where = feature.get("where") or ""
        if where:
            # A manifest entry is a slice of an event: last-seen for the
            # whole event name would overstate this specific slice. Keep
            # the exact window count authoritative; an unused slice is
            # reported as never seen rather than "used today" via a
            # sibling slice.
            last_note = "event_name" if uses else "window"
            if not uses:
                last_ms = 0
        else:
            last_note = "exact"
        last_days = None
        if last_ms:
            last_days = round(max(0.0, (now_ms - last_ms) / DAY_MS), 1)
        feature_out.append(
            {
                "id": feature["id"],
                "label": feature["label"],
                "kind": feature["kind"],
                "event": feature["event"],
                "where": where or None,
                "how_to_reach": feature.get("how_to_reach", ""),
                "uses": uses,
                "last_used_ms": last_ms or None,
                "last_used_days": last_days,
                "last_used_basis": last_note,
                "unused_candidate": uses == 0 and history_days >= 14,
            }
        )

    measured_names = {(f["kind"], f["event"]) for f in features}
    unmapped = Counter()
    for event in events:
        key = (event["kind"], event["name"])
        if event["kind"] in ("screen", "action") and key not in measured_names:
            unmapped[key] += 1

    screen_out = []
    for name, entry in sorted(screens.items(), key=lambda kv: -kv[1]["visits"]):
        durations = entry["durations"]
        screen_out.append(
            {
                "name": name,
                "visits": entry["visits"],
                "median_dwell_ms": int(statistics.median(durations)) if durations else 0,
                "p90_dwell_ms": _pct(durations, 90),
                "quick_backs": entry["quick_backs"],
                "quick_back_rate": round(entry["quick_backs"] / max(1, len(durations)), 2),
            }
        )

    action_out = []
    for name, entry in sorted(actions.items(), key=lambda kv: -kv[1]["count"]):
        action_out.append(
            {
                "name": name,
                "count": entry["count"],
                "meta": dict(entry["meta"].most_common(6)),
            }
        )

    anomalies = []
    for screen in screen_out:
        if screen["visits"] >= 5 and screen["quick_back_rate"] >= 0.4:
            anomalies.append(
                f"screen.{screen['name']}: {int(screen['quick_back_rate'] * 100)}% of visits leave in <3s"
            )
    for name, count in errors.items():
        anomalies.append(f"error.{name[0]}/{name[1] or 'unknown'} on {name[2] or '?'}: {count}")
    for name, values in slow.items():
        if values:
            anomalies.append(
                f"slow.{name}: {len(values)} events, p90={_pct(values, 90)}ms, max={max(values)}ms"
            )
    if sync_failures:
        anomalies.append(f"sync failures: {sync_failures}")
    if session_action_max >= 15:
        anomalies.append(f"one session repeated a single action {session_action_max} times")
    unused = [f["label"] for f in feature_out if f["unused_candidate"]]
    if unused:
        anomalies.append(f"{len(unused)} instrumented features unused this window")

    return {
        "ok": True,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "window": {
            "days": days,
            "since": datetime.fromtimestamp(since_ms / 1000, timezone.utc).isoformat(),
            "until": datetime.fromtimestamp(now_ms / 1000, timezone.utc).isoformat(),
        },
        "account": {"id": user_id, "history_days": round(history_days, 1)},
        "volume": {
            "events": len(events),
            "events_all_time": int(total_events),
            "sessions": sessions,
            "active_days": len(active_days),
            "platforms": dict(platform_counts),
        },
        "screens": screen_out,
        "actions": action_out,
        "errors": [
            {"name": name, "type": typ, "screen": screen, "count": count}
            for (name, typ, screen), count in errors.most_common()
        ],
        "slow": [
            {"name": name, "count": len(values), "p90_ms": _pct(values, 90), "max_ms": max(values)}
            for name, values in sorted(slow.items())
        ],
        "sync_failures": sync_failures,
        "features": feature_out,
        "unmapped": [
            {"kind": kind, "name": name, "count": count}
            for (kind, name), count in unmapped.most_common()
        ],
        "anomalies": anomalies,
    }


def render_markdown(digest: dict) -> str:
    if not digest.get("ok"):
        return f"# Usage digest\n\nNo usable account/events: {digest.get('reason')}\n"
    lines = []
    lines.append("# Usage digest")
    lines.append("")
    lines.append(
        f"Window: last {digest['window']['days']} days · "
        f"{digest['volume']['events']} events · "
        f"{digest['volume']['sessions']} sessions · "
        f"{digest['volume']['active_days']} active days · "
        f"history {digest['account']['history_days']} days"
    )
    lines.append("")
    lines.append("## Screens")
    lines.append("| screen | visits | median dwell | p90 dwell | quick-back rate |")
    lines.append("|---|---:|---:|---:|---:|")
    for screen in digest["screens"]:
        lines.append(
            f"| {screen['name']} | {screen['visits']} | "
            f"{screen['median_dwell_ms'] // 1000}s | {screen['p90_dwell_ms'] // 1000}s | "
            f"{int(screen['quick_back_rate'] * 100)}% |"
        )
    lines.append("")
    lines.append("## Actions")
    lines.append("| action | count | meta |")
    lines.append("|---|---:|---|")
    for action in digest["actions"]:
        meta = ", ".join(f"{k} ({v})" for k, v in action["meta"].items())
        lines.append(f"| {action['name']} | {action['count']} | {meta} |")
    lines.append("")
    lines.append("## Features")
    lines.append("| id | label | uses | last used (days) |")
    lines.append("|---|---|---:|---:|")
    for feature in digest["features"]:
        last = feature["last_used_days"]
        lines.append(
            f"| {feature['id']} | {feature['label']} | {feature['uses']} | "
            f"{last if last is not None else 'never'} |"
        )
    lines.append("")
    if digest["anomalies"]:
        lines.append("## Deterministic anomalies")
        for item in digest["anomalies"]:
            lines.append(f"- {item}")
        lines.append("")
    if digest["unmapped"]:
        lines.append("## Unmapped events (not in the feature manifest)")
        for item in digest["unmapped"]:
            lines.append(f"- {item['kind']}.{item['name']}: {item['count']}")
        lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--db",
        default=os.getenv("USAGE_DB", "server/api/data/app.db"),
        help="SQLite DB path (read-only)",
    )
    parser.add_argument("--days", type=int, default=int(os.getenv("USAGE_DAYS", "30")))
    parser.add_argument(
        "--features",
        default=str(Path(__file__).with_name("usage-features.json")),
    )
    parser.add_argument("--out-dir", required=True)
    args = parser.parse_args()

    db = Path(args.db)
    if not db.is_file():
        raise SystemExit(f"usage-digest: DB not found: {db}")
    digest = build_digest(db, args.days, Path(args.features))
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "facts.json").write_text(json.dumps(digest, indent=2) + "\n")
    (out / "digest.md").write_text(render_markdown(digest) + "\n")
    print(f"usage-digest: wrote {out / 'digest.md'}")
    if not digest.get("ok"):
        return 3
    if digest["volume"]["events"] == 0:
        print("usage-digest: no events in window", file=sys.stderr)
        return 4
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
