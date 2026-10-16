#!/usr/bin/env bash
# Perf walk step of the agent loop: deterministic post-deploy regression
# check for the two surfaces that hurt most — server/API latency and web
# load cost (bundle size). Runs after ux-walk.sh in poll.sh. Safe to
# re-run: self-gates on triggers, never files twice for one regression.
#
# Design (deliberate): measurement is a deterministic script, NOT an LLM.
# An LLM is a bad stopwatch — vibes and flaky findings. The numbers below
# are medians over repeated runs against throwaway accounts; the triage +
# builder agents do the interpreting when a breach is filed as agent-pending.
#
# Lanes:
#   api — register a unique throwaway account, seed 120 items, then time
#         sync/pull, items/nodes list, and a small sync/push (5 runs each,
#         median). Same junk-account pattern as patrol/ux-walk runs.
#   web — total build/web bytes + main.dart.js bytes vs baseline. (TTFB is
#         loopback-local and meaningless here; bundle bytes are what the
#         Tailnet funnel actually ships to the browser.)
#
# Triggers (walk if ANY holds):
#   1. --force flag or tools/agent/.perf-walk-force exists (manual "walk now")
#   2. the web bundle was rebuilt since the last walk (deploy-after-feature)
#   3. the last walk is older than 14 days (regular heartbeat)
#
# Noise control:
#   - medians over 5 runs, never singletons;
#   - a breach must re-trip on an immediate second pass before filing;
#   - absolute floors (100ms API, 1MB bundle) so small-base noise never files;
#   - at most ONE open perf-regression issue: repeat breaches comment on
#     the existing issue instead of spawning new ones.
#
# Baselines are NEVER auto-updated (that would silently erase regressions).
# Refresh deliberately after a perf fix ships (or the loop host changes):
#   tools/agent/perf-walk.sh --update
#
# Never touches code. Read-only w.r.t. git except: GitHub issues/labels +
# Telegram sends + state markers under build/web/ (gitignored). --update
# rewrites tools/agent/perf-baseline.json (committed) — run it by hand,
# never from the loop.
#
# Testing hooks (env, unset in the loop): REPO, PERF_API_BASE, PERF_BUILD_DIR.
set -euo pipefail
REPO="${REPO:-$HOME/Repos/a_fish_in_sea}"
cd "$REPO"
DIR="$REPO/tools/agent"
API_BASE="${PERF_API_BASE:-http://127.0.0.1:8000}"
BUILD_DIR="${PERF_BUILD_DIR:-$REPO/build/web}"
BUILD_MARKER="build/web/.agent-build-desc"
WALK_MARKER="build/web/.agent-perf-last"
FORCE_FILE="$DIR/.perf-walk-force"
BASELINE="$DIR/perf-baseline.json"
HEARTBEAT_DAYS=14

# Regression thresholds: relative factor AND absolute floor must both trip.
API_FACTOR=1.5
API_MIN_DELTA_MS=100
WEB_FACTOR=1.10
WEB_MIN_DELTA_BYTES=1000000

if [ "${1:-}" = "--update" ]; then
  MODE="update"
else
  MODE="walk"
  FORCE=0
  [ "${1:-}" = "--force" ] && FORCE=1
  [ -f "$FORCE_FILE" ] && FORCE=1
fi

should_walk() {
  [ "${FORCE:-0}" = "1" ] && { echo "forced"; return 0; }
  if [ ! -f "$WALK_MARKER" ]; then
    echo "never walked"
    return 0
  fi
  if [ -f "$BUILD_MARKER" ] && [ "$BUILD_MARKER" -nt "$WALK_MARKER" ]; then
    echo "bundle rebuilt since last walk"
    return 0
  fi
  if find "$WALK_MARKER" -mtime "+$HEARTBEAT_DAYS" -print -quit 2>/dev/null | grep -q .; then
    echo "heartbeat (> $HEARTBEAT_DAYS days)"
    return 0
  fi
  return 1
}

# measure_api <out-json>: register throwaway account, seed, time lanes.
measure_api() {
  PERF_API_BASE="$API_BASE" python3 - "$1" <<'EOF'
import json, os, statistics, sys, time, urllib.request
api = os.environ["PERF_API_BASE"]
out_path = sys.argv[1]
def req(method, path, token=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(api + path, data=data, method=method,
        headers={"Content-Type": "application/json",
                 **({"Authorization": f"Bearer {token}"} if token else {})})
    t0 = time.perf_counter()
    with urllib.request.urlopen(r, timeout=30) as res:
        payload = json.load(res)
    return (time.perf_counter() - t0) * 1000.0, payload
stamp = int(time.time() * 1000)
email = f"perf-walk-{stamp}@example.com"
_, tok = req("POST", "/api/v1/auth/register",
             body={"email": email, "password": "perf-walk-pass-1"})
access = tok["access_token"]
seed = [{"collection": "nodes", "item_id": f"perf-n-{stamp}-{i}",
         "data": {"id": f"perf-n-{stamp}-{i}", "title": f"perf seed item {i}"}}
        for i in range(100)]
seed += [{"collection": "events", "item_id": f"perf-e-{stamp}-{i}",
          "data": {"id": f"perf-e-{stamp}-{i}", "subject": "standup",
                   "start": "2026-09-14T09:00:00Z", "end": "2026-09-14T09:30:00Z"}}
         for i in range(20)]
_, pushed = req("POST", "/api/v1/sync/push", token=access, body={"changes": seed})
assert len(pushed["applied"]) == 120, f"seed failed: {pushed}"
def med(fn, n=5):
    return statistics.median(sorted(fn() for _ in range(n)))
pull_ms = med(lambda: req("GET", "/api/v1/sync/pull", token=access)[0])
items_ms = med(lambda: req("GET", "/api/v1/items/nodes", token=access)[0])
def push_once():
    uid = time.time_ns()
    ch = [{"collection": "nodes", "item_id": f"perf-w-{stamp}-{uid}-{i}",
           "data": {"id": f"perf-w-{stamp}-{uid}-{i}", "title": "w"}}
          for i in range(5)]
    ms, _ = req("POST", "/api/v1/sync/push", token=access, body={"changes": ch})
    return ms
push_ms = med(push_once)
with open(out_path, "w") as f:
    json.dump({"sync_pull_ms": round(pull_ms, 1),
               "items_nodes_ms": round(items_ms, 1),
               "sync_push_ms": round(push_ms, 1),
               "seed_account": email}, f)
EOF
}

# compare <measured-json> <breaches-out>: vs baseline, thresholds from env.
compare() {
  API_FACTOR="$API_FACTOR" API_MIN_DELTA_MS="$API_MIN_DELTA_MS" \
  WEB_FACTOR="$WEB_FACTOR" WEB_MIN_DELTA_BYTES="$WEB_MIN_DELTA_BYTES" \
  python3 - "$BASELINE" "$1" "$2" <<'EOF'
import json, os, sys
base_path, measured_path, breaches_path = sys.argv[1], sys.argv[2], sys.argv[3]
base = json.load(open(base_path))
measured = json.load(open(measured_path))
api_f = float(os.environ["API_FACTOR"]); api_d = float(os.environ["API_MIN_DELTA_MS"])
web_f = float(os.environ["WEB_FACTOR"]); web_d = float(os.environ["WEB_MIN_DELTA_BYTES"])
breaches = []
for metric in ("sync_pull_ms", "items_nodes_ms", "sync_push_ms"):
    b, m = base["api"][metric], measured["api"][metric]
    if m > b * api_f and (m - b) >= api_d:
        breaches.append(f"api|{metric}|{b}|{m}")
for metric in ("bundle_bytes", "main_dart_js_bytes"):
    if measured["web"] is None:
        break
    b, m = base["web"][metric], measured["web"][metric]
    if m > b * web_f and (m - b) >= web_d:
        breaches.append(f"web|{metric}|{b}|{m}")
with open(breaches_path, "w") as f:
    f.write("\n".join(breaches) + ("\n" if breaches else ""))
EOF
}

if [ "$MODE" = "update" ]; then
  STAMP="$(date +%F-%H%M)"
  OUT="/tmp/opencode/perf-$STAMP-update"
  mkdir -p "$OUT"
  echo "[perf-walk] measuring for baseline refresh..."
  if ! measure_api "$OUT/api.json"; then
    echo "[perf-walk] API measurement failed — server on :8000 up?"
    exit 1
  fi
  BUNDLE_BYTES="$(du -sb "$BUILD_DIR" 2>/dev/null | cut -f1 || true)"
  MAIN_BYTES="$(stat -c %s "$BUILD_DIR/main.dart.js" 2>/dev/null || true)"
  python3 - "$OUT/api.json" "$BASELINE" "$BUNDLE_BYTES" "$MAIN_BYTES" <<'EOF'
import json, sys
from datetime import datetime, timezone
api = json.load(open(sys.argv[1]))
baseline_path, bundle_bytes, main_bytes = sys.argv[2], sys.argv[3], sys.argv[4]
doc = {
    "_note": "Loop-host perf baselines for tools/agent/perf-walk.sh. "
             "Refresh DELIBERATELY via perf-walk.sh --update after a perf fix "
             "ships (or the loop host changes). The walk NEVER rewrites this.",
    "measured_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "api": {"sync_pull_ms": api["sync_pull_ms"],
            "items_nodes_ms": api["items_nodes_ms"],
            "sync_push_ms": api["sync_push_ms"]},
    "web": {"bundle_bytes": int(bundle_bytes or 0),
            "main_dart_js_bytes": int(main_bytes or 0)},
}
json.dump(doc, open(baseline_path, "w"), indent=2)
open(baseline_path, "a").write("\n")
print(json.dumps(doc, indent=2))
EOF
  echo "[perf-walk] baseline written to $BASELINE — review the diff, then commit"
  exit 0
fi

REASON="$(should_walk || true)"
if [ -z "$REASON" ]; then
  echo "[perf-walk] no trigger — skipping"
  exit 0
fi
echo "[perf-walk] trigger: $REASON"

if [ ! -f "$BASELINE" ]; then
  echo "[perf-walk] no baseline at $BASELINE — run tools/agent/perf-walk.sh --update first"
  mkdir -p "$(dirname "$WALK_MARKER")"
  date -u +%FT%TZ >"$WALK_MARKER"
  rm -f "$FORCE_FILE"
  exit 0
fi

STAMP="$(date +%F-%H%M)"
OUT="/tmp/opencode/perf-$STAMP"
mkdir -p "$OUT"
REPORT="$OUT/report.md"
BUILD_DESC="unknown"
[ -f "$BUILD_MARKER" ] && BUILD_DESC="$(cat "$BUILD_MARKER")"

if ! curl -s -o /dev/null --max-time 10 "$API_BASE/api/health"; then
  echo "[perf-walk] API not reachable at $API_BASE — skipping (server first)"
  exit 1
fi
if ! measure_api "$OUT/api.json"; then
  echo "[perf-walk] API measurement failed — skipping"
  exit 1
fi

BUNDLE_BYTES="$(du -sb "$BUILD_DIR" 2>/dev/null | cut -f1 || true)"
MAIN_BYTES="$(stat -c %s "$BUILD_DIR/main.dart.js" 2>/dev/null || true)"
python3 - "$OUT/api.json" "$BUNDLE_BYTES" "$MAIN_BYTES" "$OUT/measured.json" <<'EOF'
import json, sys
api = json.load(open(sys.argv[1]))
bundle_bytes, main_bytes = sys.argv[2], sys.argv[3]
def num(s):
    try:
        return int(s)
    except (TypeError, ValueError):
        return None
web = None
b, m = num(bundle_bytes), num(main_bytes)
if b and m:
    web = {"bundle_bytes": b, "main_dart_js_bytes": m}
json.dump({"api": api, "web": web}, open(sys.argv[4], "w"), indent=2)
EOF

compare "$OUT/measured.json" "$OUT/breaches.txt"

# Confirm pass: a breach must re-trip on an immediate second measurement.
if [ -s "$OUT/breaches.txt" ]; then
  echo "[perf-walk] breach on first pass — confirming..."
  sleep 5
  if measure_api "$OUT/api2.json"; then
    python3 - "$OUT/api2.json" "$OUT/measured.json" <<'EOF'
import json, sys
api2 = json.load(open(sys.argv[1]))
measured = json.load(open(sys.argv[2]))
measured["api"] = api2
json.dump(measured, open(sys.argv[2], "w"), indent=2)
EOF
    compare "$OUT/measured.json" "$OUT/breaches.txt"
  else
    echo "[perf-walk] confirm pass failed to measure — keeping first-pass result"
  fi
fi

PULL="$(python3 -c 'import json; print(json.load(open("'"$OUT/measured.json"'"))["api"]["sync_pull_ms"])')"
PUSH="$(python3 -c 'import json; print(json.load(open("'"$OUT/measured.json"'"))["api"]["sync_push_ms"])')"
BUNDLE_MB="n/a"
if [ -n "${BUNDLE_BYTES:-}" ]; then
  BUNDLE_MB="$((BUNDLE_BYTES / 1024 / 1024))MB"
fi

{
  echo "# Perf walk $STAMP"
  echo "Build: $BUILD_DESC"
  echo "Trigger: $REASON"
  echo
  echo "Measured (median of 5) vs baseline ($BASELINE):"
  echo
  python3 - "$BASELINE" "$OUT/measured.json" <<'EOF'
import json, sys
base = json.load(open(sys.argv[1]))
measured = json.load(open(sys.argv[2]))
for metric in ("sync_pull_ms", "items_nodes_ms", "sync_push_ms"):
    print(f"- api/{metric}: {measured['api'][metric]}ms (baseline {base['api'][metric]}ms)")
if measured["web"] is None:
    print("- web: skipped (no bundle at PERF_BUILD_DIR)")
else:
    for metric in ("bundle_bytes", "main_dart_js_bytes"):
        print(f"- web/{metric}: {measured['web'][metric]} (baseline {base['web'][metric]})")
EOF
  echo
  if [ -s "$OUT/breaches.txt" ]; then
    echo "Breaches (confirmed on second pass):"
    while IFS='|' read -r lane metric old new; do
      [ -z "${lane:-}" ] && continue
      echo "- $lane/$metric: $old -> $new"
    done <"$OUT/breaches.txt"
  else
    echo "No regressions."
  fi
  echo
  echo "Raw: $OUT/ (loop host)"
} >"$REPORT"

mkdir -p "$(dirname "$WALK_MARKER")"
date -u +%FT%TZ >"$WALK_MARKER"
rm -f "$FORCE_FILE"

if [ ! -s "$OUT/breaches.txt" ]; then
  echo "[perf-walk] $STAMP no regression (pull=${PULL}ms push=${PUSH}ms bundle=$BUNDLE_MB)"
  "$DIR/tg.sh" "⚡ Perf walk $STAMP ($REASON): no regression — pull ${PULL}ms / push ${PUSH}ms, bundle $BUNDLE_MB
Report: $REPORT" || echo "[perf-walk] telegram ping failed"
  echo "[perf-walk] done"
  exit 0
fi

BREACH_SUM="$(awk -F'|' '{print $1"/"$2" "$3"->"$4}' "$OUT/breaches.txt" | paste -sd' ' -)"
echo "[perf-walk] $STAMP REGRESSION: $BREACH_SUM"

gh label create "perf-regression" --color "D93F0B" \
  --description "Perf walk: confirmed latency/size regression vs baseline" >/dev/null 2>&1 || true
EXISTING="$(gh issue list --label perf-regression --state open --limit 5 \
  --json number --jq '.[0].number // empty' 2>/dev/null || true)"
BODY="$(cat "$REPORT")
---
Walk: $STAMP, trigger: $REASON, build: $BUILD_DESC
Raw numbers: $OUT/ (loop host)
Repro: tools/agent/perf-walk.sh --force
Scope note for triage: keep the fix to one hot spot per issue; re-run
perf-walk.sh --force after the fix and refresh the baseline with
perf-walk.sh --update once it ships."

if [ -n "${EXISTING:-}" ]; then
  gh issue comment "$EXISTING" --body "Perf walk $STAMP re-tripped ($REASON):

$BODY" >/dev/null
  echo "[perf-walk] #$EXISTING already open — breach appended"
  "$DIR/tg.sh" "🐌 Perf walk $STAMP ($REASON): regression persists — $BREACH_SUM
Updated #$EXISTING (no new issue; one open perf issue at a time)
Report: $REPORT" || echo "[perf-walk] telegram ping failed"
else
  TITLE="[perf $STAMP] regression: $BREACH_SUM"
  NEW_URL="$(gh issue create --title "$TITLE" --body "$BODY" \
    --label agent-pending --label perf-regression 2>/dev/null || true)"
  echo "[perf-walk] regression issue filed: $NEW_URL"
  "$DIR/tg.sh" "🐌 Perf walk $STAMP ($REASON): REGRESSION — $BREACH_SUM
Issue: $NEW_URL
Report: $REPORT" || echo "[perf-walk] telegram ping failed"
fi
echo "[perf-walk] done"
