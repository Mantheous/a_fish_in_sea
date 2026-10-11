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
"$REPO/tools/agent/triage.sh"
"$REPO/tools/agent/approve.sh"
"$REPO/tools/agent/build.sh"
echo "[agent-poll] done"
