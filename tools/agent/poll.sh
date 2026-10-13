#!/usr/bin/env bash
# Agent dev-loop orchestrator, run by agent-poll.timer every 15 min.
# Logs to journal via systemd. Long builds run in tmux (see build.sh).
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
"$REPO/tools/agent/close.sh"
"$REPO/tools/agent/triage.sh"
"$REPO/tools/agent/approve.sh"
"$REPO/tools/agent/build.sh"
"$REPO/tools/agent/review.sh"
"$REPO/tools/agent/data-guard.sh"
"$REPO/tools/agent/security-guard.sh"
"$REPO/tools/agent/deploy.sh"
"$REPO/tools/agent/ux-walk.sh"
"$REPO/tools/agent/perf-walk.sh"
echo "[agent-poll] done"
