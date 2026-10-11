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
Issue: gh issue view $N --json number,title,body (run it to get the spec).
Rules:
1. Follow AGENTS.md persistence rules exactly (additive-only models, orElse enum fallback, gated migrations with Migration.removeAfter, extend tolerance tests).
2. Implement the issue, nothing more. NEVER push to main, NEVER commit to main.
3. Gates (must both pass): ~/flutter/bin/flutter analyze (0 issues) and ~/flutter/bin/flutter test (all pass, add/update tests for the change).
4. Commit on $BRANCH, push origin $BRANCH, open PR with: gh pr create --base main --head $BRANCH --title \"[agent #$N] <title>\" --body \"Closes #$N. Test log: <paste tail of flutter test>. Risk notes: <...>\"
5. If the gates fail and you cannot fix within reason, push the branch anyway and report FAIL status in the PR body.
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
