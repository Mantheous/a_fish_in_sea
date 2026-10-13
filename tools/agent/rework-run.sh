#!/usr/bin/env bash
# Rework run for ONE review-rejected PR. Runs inside a detached tmux session.
# Works in the PR's EXISTING worktree/branch, addresses the reviewer's fix
# list, re-runs the gates, pushes, and lifts the verdict label so review.sh
# re-reviews on the next poll. NEVER pushes to main.
# Usage: rework-run.sh <pr-number> <round>
set -euo pipefail
REPO="$HOME/Repos/a_fish_in_sea"
cd "$REPO"
DIR="$REPO/tools/agent"
N="$1"
ROUND="$2"
BRANCH="$(gh pr view "$N" --json headRefName --jq .headRefName)"
WT="$(git worktree list --porcelain | awk -v b="$BRANCH" 'BEGIN{dir=""} /^worktree /{dir=$2} $0=="branch refs/heads/"b {print dir; exit}')"
if [ -z "${WT:-}" ] || [ ! -d "$WT" ]; then
  echo "[rework] #$N worktree for $BRANCH missing — aborting"
  exit 1
fi
echo "[rework] #$N round $ROUND in $WT ($BRANCH)"

PROMPT="You are the rework builder. Work ONLY inside this worktree: $WT (branch $BRANCH).
PR: gh pr view $N --json number,title,body,comments (run it to get context).
Linked issue: find Closes #<n> in the PR body, then gh issue view <n> --json number,title,body,comments for the latest plan + tester follow-ups (newest tester comment wins on conflict).
Rules:
1. Read the LATEST <!-- agent-review --> verdict comment on the PR (changes-requested) and address EVERY item in its Fix list, nothing more. If you genuinely disagree with an item, leave the code and explain why in your rework comment instead. If a fix item points at a screenshot, download it (curl -sL \"<url>\" -o /tmp/opencode/rework-$N-<i>.png) and READ it with the read tool — never say an image could not be loaded.
2. Keep the diff small — fix, don't redesign. AGENTS.md persistence rules still apply exactly.
3. Gates (must both pass): ~/flutter/bin/flutter analyze (0 issues) and ~/flutter/bin/flutter test (all pass; extend tests for the fix — widget, golden, or patrol_test as appropriate).
4. Commit on $BRANCH, push origin $BRANCH. NEVER push to main, NEVER commit to main.
5. Remove the review:changes-requested label (gh pr edit $N --remove-label review:changes-requested) so the reviewer re-checks, and post a comment starting with <!-- agent-rework --> summarizing round $ROUND: what changed per fix item, gate results.
Report at the end: STATUS=<ready|failed>."
if opencode run --auto --title "rework-#$N-r$ROUND" "$PROMPT" >"$WT/.agent-rework-$ROUND.log" 2>&1; then
  echo "[rework] #$N round $ROUND finished"
else
  echo "[rework] #$N round $ROUND exited non-zero (see $WT/.agent-rework-$ROUND.log)"
fi
"$DIR/tg.sh" "🔧 Rework round $ROUND done for PR #$N
$(gh pr view "$N" --json url --jq .url)" || true
echo "[rework] #$N done"
