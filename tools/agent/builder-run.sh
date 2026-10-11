#!/usr/bin/env bash
# Builder run for ONE approved issue. Runs inside a detached tmux session
# (long builds). Creates worktree + branch, implements via headless opencode,
# gates on analyze+tests, opens PR. NEVER pushes to main.
# Usage: builder-run.sh <issue-number>
set -euo pipefail
REPO="$HOME/Repos/a_fish_in_sea"
cd "$REPO"
DIR="$REPO/tools/agent"
N="$1"
TITLE="$(gh issue view "$N" --json title --jq .title)"
URL="$(gh issue view "$N" --json url --jq .url)"
SLUG="$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\+/-/g' | cut -c1-40 | sed 's/-$//')"
BRANCH="agent/$N-$SLUG"
WT="$HOME/Repos/worktrees/agent-$N-$SLUG"

git fetch origin --quiet
if git ls-remote --heads origin "$BRANCH" | grep -q .; then
  echo "[builder] #$N branch $BRANCH already exists — skipping"
  exit 0
fi
git worktree add "$WT" -b "$BRANCH" origin/main
echo "[builder] #$N worktree $WT branch $BRANCH"

PROMPT="You are the builder agent. Work ONLY inside this worktree: $WT (branch $BRANCH, based on origin/main).
Issue: gh issue view $N --json number,title,body,comments (run it to get the spec).
Rules:
1. The triage plan lives in the <!-- agent-plan --> comment on the issue — that scope is the contract. Implement the plan, nothing more. If the plan is wrong, say so in the PR body instead of freelancing.
2. Keep the diff SMALL and focused: the issue and nothing else. No drive-by refactors, no unrelated cleanups, no formatting churn. If the change naturally exceeds ~300 lines, stop and explain why in the PR body instead of ballooning it.
3. Follow AGENTS.md persistence rules exactly (additive-only models, orElse enum fallback, gated migrations with Migration.removeAfter, extend tolerance tests).
4. NEVER push to main, NEVER commit to main.
5. Gates (must both pass): ~/flutter/bin/flutter analyze (0 issues) and ~/flutter/bin/flutter test (all pass, add/update tests for the change, including goldens under test/goldens/ if you touched a screen).
6. If you touched a user flow (auth, navigation, create/edit/delete, sync), add or extend a patrol_test and run it headless against the dev API server: export PATH="$HOME/.local/bin:$HOME/.pub-cache/bin:$PATH" PATROL_ANALYTICS_ENABLED=false; patrol test --device chrome --web-headless --target patrol_test/<file>.dart --dart-define=SERVER_URL=http://127.0.0.1:8000 (needs the API server on :8000; uses a unique test account per run).
7. UX check (AGENTS.md rule): do NOT run the ux-walker yourself — the agent loop walks each deploy exactly once (tools/agent/ux-walk.sh via poll.sh), and per-branch walks duplicate that work while contending for the same browser. If the triage plan says UX check: needed OR you touched lib/*/view, navigation, dialogs/sheets, or user-facing copy: run gh issue edit $N --add-label ux-walk and record the scope (screens/flows touched + how to reach them, 1-2 lines) in the PR body under a 'UX scope:' heading. The post-deploy walk covers it and files findings as new issues. Never gate your PR on a walk verdict.
8. Commit on $BRANCH, push origin $BRANCH, open PR with: gh pr create --base main --head $BRANCH --title \"[agent #$N] <title>\" --body \"Closes #$N. Scope: <one line, matches the triage plan>. UX scope: <screens/flows touched + how to reach them, or 'none — no user-visible change'>. Test log: <paste tail of flutter test>. Risk notes: <...>. Screenshots: <host paths under /tmp/opencode/ you verified against, for UX-filed issues>\"
9. If the gates fail and you cannot fix within reason, push the branch anyway and report FAIL status in the PR body.
A separate reviewer agent will read your diff against the plan — write the PR body for a skeptical reader.
Report at the end: PR_URL=<url or NONE> STATUS=<ready|failed>."
if opencode run --auto --title "builder-#$N" "$PROMPT" >"$WT/.agent-build.log" 2>&1; then
  echo "[builder] #$N opencode run finished"
else
  echo "[builder] #$N opencode run exited non-zero (see $WT/.agent-build.log)"
fi
PR_URL="$(grep -m1 -o 'https://github.com/[^ ]*/pull/[0-9]*' "$WT/.agent-build.log" || true)"
[ -z "$PR_URL" ] && PR_URL="$(gh pr list --head "$BRANCH" --json url --jq '.[0].url // empty' || true)"
[ -z "$PR_URL" ] && PR_URL="NONE (check $WT/.agent-build.log)"
"$DIR/tg.sh" "🔨 Builder finished #$N: $TITLE
PR: $PR_URL
$URL" || true
echo "[builder] #$N done PR=$PR_URL"
