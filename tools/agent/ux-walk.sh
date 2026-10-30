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

# Serialized model quota for the opencode case only: a ux-walk (opencode +
# Playwright) must not stack on an opencode builder. Codex builders run on a
# separate allowance, so the post-deploy walk still runs while they work.
loop_runs() {
  tmux ls -F '#{session_name}' 2>/dev/null | grep -cE '^(agent-[0-9]|rework-[0-9])' || true
}
UX_BACKEND="${FISH_LLM_UX_WALK_BACKEND:-opencode}"
BUILDER_BACKEND="${FISH_LLM_BUILDER_BACKEND:-opencode}"

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

# Don't stack an opencode walk on top of an opencode builder/rework.
if [ "$UX_BACKEND" = "opencode" ] && [ "$BUILDER_BACKEND" = "opencode" ]; then
  RUNNING="$(loop_runs)"
  if [ "${RUNNING:-0}" -ge 1 ]; then
    echo "[ux-walk] $RUNNING opencode loop run(s) active — skipping ux walk this poll"
    exit 0
  fi
fi

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

# NOTE: `opencode run --agent` does NOT apply any frontmatter model (a
# primary-agent session keeps the configured default, which resolves to a
# free-tier model). Pin --model explicitly so the walk stays on opencode-go.
if ! opencode run --agent ux-walker --model opencode-go/gpt-6-luna#xhigh --title "ux-walk-$STAMP" "$PROMPT" >"$OUT/run.log" 2>&1; then
  echo "[ux-walk] walker run failed (see $OUT/run.log) — no report was written, so ux-walk labels stay on their issues and $WALK_MARKER is not refreshed; the request retries on the next trigger"
  tail -n 5 "$OUT/run.log" || true
else
  # A zero exit is not proof of a walk. On 2026-10-29 the walker exited 0
  # without writing report.md, and the loop still consumed the ux-walk labels
  # from #235/#240 — those scopes were never actually walked. Require a
  # non-empty report before refreshing the marker or clearing labels.
  if [ ! -s "$REPORT" ]; then
    echo "[ux-walk] walker exited 0 but wrote no report — keeping ux-walk labels for the next attempt"
    tail -n 5 "$OUT/run.log" || true
    exit 1
  fi
  echo "[ux-walk] walker run finished — report: $REPORT"
  date -u +%FT%TZ >"$WALK_MARKER"
  rm -f "$FORCE_FILE"

  # Consume ux-walk labels only when a real report exists to point requesters at.
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
fi

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
  # Dedupe: comment on an already-open ux-walk blocker issue instead of
  # filing a fresh agent-pending issue every walk (same one-open-issue
  # pattern perf-walk.sh uses for perf-regression).
  EXISTING="$(gh issue list --label agent-pending --state open --limit 10 \
    --json number,title 2>/dev/null \
    | python3 -c 'import json,sys; issues=json.load(sys.stdin); print(next((str(i["number"]) for i in issues if i.get("title","").startswith("[ux-walk ")), ""))' || true)"
  if [ -n "${EXISTING:-}" ]; then
    gh issue comment "$EXISTING" --body "Walk $STAMP re-tripped ($REASON):

$BODY" >/dev/null
    echo "[ux-walk] #$EXISTING already open — new blockers appended to existing blocker issue"
  else
    gh issue create --title "$TITLE" --body "$BODY" --label agent-pending >/dev/null
    echo "[ux-walk] blocker issue filed"
  fi
fi
echo "[ux-walk] done"
