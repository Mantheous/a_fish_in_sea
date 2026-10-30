#!/usr/bin/env bash
# Deterministic test for tools/agent/usage-digest.py: synthetic SQLite DB,
# no server, no network. Verifies account inference, zero-use features and
# that the digest is content-free.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIGEST="$HERE/../usage-digest.py"
FEATURES="$HERE/../usage-features.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DB="$TMP/usage.db"

python3 - "$DB" <<'PY'
import json, sqlite3, sys, time
con = sqlite3.connect(sys.argv[1])
con.executescript("""
CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT);
CREATE TABLE usage_events (
 id INTEGER PRIMARY KEY, user_id INTEGER, event_id TEXT, session_id TEXT,
 kind TEXT, name TEXT, screen TEXT, duration_ms INTEGER, meta TEXT,
 platform TEXT, client_at_ms INTEGER, received_at TEXT
);
""")
con.executemany(
    "INSERT INTO users VALUES (?,?)",
    [(1, "real@fish.test"), (2, "patrol-test@example.com"), (3, "perf-walk@example.com")],
)
now = int(time.time() * 1000)
rows = []
def add(user, kind, name, screen=None, dur=None, meta=None, days=0):
    at = now - days * 86_400_000
    rows.append((user, f"{user}-{len(rows)}", "s1", kind, name, screen or "",
                 dur, json.dumps(meta or {}), "web", at, "2026-10-29"))

# Real account: calendar used today and 15 days ago; tasks never.
for days in (0, 15):
    add(1, "screen", "calendar", "calendar", 60_000, {"to": "home"}, days)
    add(1, "action", "calendar.view.set", "calendar", None, {"view": "week"}, days)
add(1, "error", "flutter", "calendar", None, {"type": "typeerror"})
add(1, "action", "event.editor.open", "calendar", None, {"mode": "create"})
# Test accounts must be ignored even with more events.
for i in range(50):
    add(2, "action", "calendar.view.set", "calendar", None, {"view": "day"})
    add(3, "action", "calendar.view.set", "calendar", None, {"view": "day"})
con.executemany(
    "INSERT INTO usage_events (user_id,event_id,session_id,kind,name,screen,"
    "duration_ms,meta,platform,client_at_ms,received_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
    rows,
)
con.commit()
PY

python3 "$DIGEST" --db "$DB" --features "$FEATURES" --days 30 \
  --out-dir "$TMP/out" >"$TMP/log" 2>&1

python3 - "$TMP/out/facts.json" <<'PY'
import json, sys
facts = json.load(open(sys.argv[1]))
assert facts["ok"], facts
assert facts["account"]["id"] == 1, facts["account"]  # non-test account wins
assert facts["volume"]["events"] == 6, facts["volume"]
by_id = {f["id"]: f for f in facts["features"]}
assert by_id["screen.calendar"]["uses"] == 2, by_id["screen.calendar"]
assert by_id["screen.tasks"]["uses"] == 0, by_id["screen.tasks"]
assert by_id["screen.tasks"]["unused_candidate"], by_id["screen.tasks"]
assert by_id["calendar.week"]["uses"] == 2, by_id["calendar.week"]
assert by_id["calendar.day"]["uses"] == 0, by_id["calendar.day"]
assert facts["errors"] and facts["errors"][0]["type"] == "typeerror", facts["errors"]
# Content-free: no event titles/notes ever reach the digest.
blob = json.dumps(facts)
for forbidden in ("Quiz", "notes", "title", "location"):
    assert forbidden not in blob, forbidden
print("ok - digest infers the real account and computes unused features")
PY

# A missing table is a clean "no data yet", not a crash.
python3 - "$TMP/empty.db" <<'PY'
import sqlite3, sys
sqlite3.connect(sys.argv[1]).executescript("CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT);")
PY
if python3 "$DIGEST" --db "$TMP/empty.db" --features "$FEATURES" \
    --out-dir "$TMP/empty-out" >"$TMP/empty.log" 2>&1; then
  echo "expected the digest to exit non-zero without a usage_events table" >&2
  exit 1
fi
grep -q "usage_events table does not exist" "$TMP/empty-out/digest.md"

echo "passed: usage digest"
