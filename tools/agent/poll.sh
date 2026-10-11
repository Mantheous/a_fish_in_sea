#!/usr/bin/env bash
# Agent poll (step 1 stub): read-only check, logs to journal via systemd.
# Step 3 (triage agent) will extend this to dedupe/plan/ping Telegram.
# Long builds run in tmux, never here.
set -euo pipefail
REPO="$HOME/Repos/a_fish_in_sea"
cd "$REPO"
git fetch origin --quiet 2>&1 | head -n 5 || true
HEAD="$(git rev-parse --short main)"
PENDING="$(gh issue list --label agent-pending --limit 20 --json number,title,author 2>/dev/null || echo '[]')"
COUNT="$(echo "$PENDING" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo '?')"
echo "[agent-poll] HEAD=$HEAD agent-pending=$COUNT"
echo "$PENDING" | python3 -c "
import json,sys
try:
    issues = json.load(sys.stdin)
    for i in issues:
        author = (i.get('author') or {}).get('login', '?')
        print(f\"[agent-poll] #{i.get('number')} {i.get('title','')[:80]} (@{author})\")
except Exception as e:
    print(f'[agent-poll] parse error: {e}')
"
