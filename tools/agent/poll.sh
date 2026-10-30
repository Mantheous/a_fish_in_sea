#!/usr/bin/env bash
# Agent dev-loop orchestrator, run by agent-poll.timer every 15 min.
# Logs to journal via systemd. Long builds run in tmux (see build.sh).
#
# Step wrapper: each step is wrapped so a failure in one (a flaky gh call
# under `set -e` inside the step used to kill the WHOLE poll — that skipped
# deploy/ux-walk/perf-walk for the cycle, repeatedly) no longer takes the
# rest of the cycle down with it. Every step is idempotent and safe to
# re-run, so the next poll retries whatever failed.
set -euo pipefail
REPO="$HOME/Repos/a_fish_in_sea"
cd "$REPO"
exec 9>/tmp/agent-loop.lock
if ! flock -n 9; then
  echo "[agent-poll] previous run still active — skipping"
  exit 0
fi
git fetch origin --quiet 2>&1 | head -n 5 || true
echo "[agent-poll] HEAD=$(git rev-parse --short main)"
# Kill switch: touch .agent-loop-paused at the repo root, or open an issue
# titled exactly "AGENT LOOPS: PAUSED", and every poll run becomes a no-op
# on its next run. Running builds in tmux are left alone (they finish).
if [ -f "$REPO/.agent-loop-paused" ]; then
  echo "[agent-poll] paused via .agent-loop-paused — skipping"
  exit 0
fi
if gh issue list --state open --search "AGENT LOOPS: PAUSED in:title" --limit 5 \
  --json title | python3 -c 'import json,sys; sys.exit(0 if any(t["title"].strip() == "AGENT LOOPS: PAUSED" for t in json.load(sys.stdin)) else 1)'; then
  echo "[agent-poll] paused via AGENT LOOPS: PAUSED issue — skipping"
  exit 0
fi

step() {
  local name="$1"; shift
  local st=0
  echo "[agent-poll] step $name"
  "$@" || st=$?
  if [ "$st" -ne 0 ]; then
    # Notify-quiet: step failures are transient (next poll retries) — journal only, no text.
    echo "[agent-poll] step $name failed (exit $st) — continuing the cycle (no telegram: notify-quiet)"
  fi
}

step close       "$REPO/tools/agent/close.sh"
step approve     "$REPO/tools/agent/approve.sh"
step build       "$REPO/tools/agent/build.sh"
step discover    "$REPO/tools/agent/discover.sh"
step triage      "$REPO/tools/agent/triage.sh"
step tg-callbacks "$REPO/tools/agent/tg-callbacks.sh"
step review      "$REPO/tools/agent/review.sh"
step data-guard  "$REPO/tools/agent/data-guard.sh"
step sec-guard   "$REPO/tools/agent/security-guard.sh"
step merge       "$REPO/tools/agent/merge.sh"
step deploy      "$REPO/tools/agent/deploy.sh"
step ux-walk     "$REPO/tools/agent/ux-walk.sh"
step perf-walk   "$REPO/tools/agent/perf-walk.sh"
echo "[agent-poll] done"
