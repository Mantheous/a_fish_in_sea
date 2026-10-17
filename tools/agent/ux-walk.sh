#!/usr/bin/env bash
# UX walker step of the agent loop: drive the freshly deployed web bundle
# with a code-blind vision agent (grandma persona) and file what it finds.
# Runs after deploy.sh in poll.sh. Safe to re-run: self-gates on triggers.
#
# Triggers (walk if ANY holds):
#   1. --force flag or tools/agent/.ux-walk-force exists (manual "walk now")
#   2. an open issue carries the `ux-walk` label (feature author wants eyes)
#   3. the web bundle was rebuilt since the last walk (deploy-after-feature)
#   4. the last walk is older than 7 days (regular heartbeat)
# Never touches code. Read-only w.r.t. git except: GitHub issues/labels +
# Telegram sends + state markers under build/web/ (gitignored).
set -euo pipefail
REPO="$HOME/Repos/a_fish_in_sea"
cd "$REPO"
DIR="$REPO/tools/agent"
APP_URL="${UX_APP_URL:-http://127.0.0.1:8000/fish/}"
BUILD_MARKER="build/web/.agent-build-desc"
WALK_MARKER="build/web/.agent-ux-last"
FORCE_FILE="$DIR/.ux-walk-force"
HEARTBEAT_DAYS=7

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1
[ -f "$FORCE_FILE" ] && FORCE=1

should_walk() {
  [ "$FORCE" = "1" ] && { echo "forced"; return 0; }
  if gh issue list --label ux-walk --state open --limit 5 --json number \
    | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin) else 1)'; then
    echo "ux-walk label requested"
    return 0
  fi
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

REASON="$(should_walk || true)"
if [ -z "$REASON" ]; then
  echo "[ux-walk] no trigger — skipping"
  exit 0
fi
echo "[ux-walk] trigger: $REASON"

STAMP="$(date +%F-%H%M)"
OUT="/tmp/opencode/ux-$STAMP"
mkdir -p "$OUT"
REPORT="$OUT/report.md"
BUILD_DESC="unknown"
[ -f "$BUILD_MARKER" ] && BUILD_DESC="$(cat "$BUILD_MARKER")"

# Scope: feature authors add the ux-walk label (AGENTS.md UX rule) instead
# of running per-branch walks. Collect their scopes so this single queued
# walk covers them; fall back to the full tour when nobody asked.
SCOPE="$(gh issue list --label ux-walk --state open --limit 10 \
  --json number,title --jq '.[] | "#\(.number): \(.title)"' 2>/dev/null || true)"
[ -z "$SCOPE" ] && SCOPE="full app tour (no specific requests this run)"

if ! curl -s -o /dev/null --max-time 10 "$APP_URL"; then
  echo "[ux-walk] app not reachable at $APP_URL — skipping (deploy first)"
  exit 1
fi

PROMPT="Walk the planner app like a first-time user and report UX findings.
APP_URL: $APP_URL
SHOT_DIR: $OUT
REPORT: $REPORT
Build: $BUILD_DESC
UX_EMAIL: ux-walker@example.com
UX_PASSWORD: ux-walker-dev-pass-1
CONTEXT: ux-$STAMP
SCOPE:
$SCOPE
Save every screenshot under SHOT_DIR, write the report to REPORT, then stop."

if ! opencode run --agent ux-walker --title "ux-walk-$STAMP" "$PROMPT" >"$OUT/run.log" 2>&1; then
  echo "[ux-walk] walker run failed (see $OUT/run.log)"
  tail -n 5 "$OUT/run.log" || true
fi
date -u +%FT%TZ >"$WALK_MARKER"
rm -f "$FORCE_FILE"

# Consume ux-walk labels: point requesters at the report.
gh issue list --label ux-walk --state open --limit 10 --json number \
  | python3 -c 'import json,sys; [print(i["number"]) for i in json.load(sys.stdin)]' \
  | while read -r N; do
  [ -z "$N" ] && continue
  if ! gh issue comment "$N" --body "UX walk $STAMP done (trigger: $REASON). Report: \`$REPORT\`, screenshots in \`$OUT/\` on the loop host." >/dev/null \
      || ! gh issue edit "$N" --remove-label ux-walk >/dev/null; then
    echo "[ux-walk] #$N could not consume the label (gh hiccup) — retried next walk"
    continue
  fi
  echo "[ux-walk] #$N labelled walk consumed"
done

BLOCKERS=0; FINDINGS=0
if [ -f "$REPORT" ]; then
  BLOCKERS="$(grep -ci 'severity: blocker' "$REPORT" || true)"
  FINDINGS="$(grep -ci '^## Finding' "$REPORT" || true)"
fi
VERDICT="$(grep -m1 '^Verdict:' "$REPORT" 2>/dev/null || echo "Verdict: (no report written)")"
echo "[ux-walk] $STAMP findings=$FINDINGS blockers=$BLOCKERS (no telegram: notify-quiet — blockers re-enter as triage plans, which do text)"

# Blockers re-enter the normal loop as one triageable issue (screenshots
# live on the loop host, readable by the triage/builder agents).
if [ "$BLOCKERS" -gt 0 ] && [ -f "$REPORT" ]; then
  TITLE="[ux-walk $STAMP] $BLOCKERS blocker(s), $FINDINGS finding(s)"
  BODY="$(cat "$REPORT")
---
Walk: $STAMP, trigger: $REASON, build: $BUILD_DESC
Screenshots: $OUT/ (loop host)"
  gh issue create --title "$TITLE" --body "$BODY" --label agent-pending >/dev/null
  echo "[ux-walk] blocker issue filed"
fi
echo "[ux-walk] done"
