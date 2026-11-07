#!/usr/bin/env bash
# Rework run for ONE review-rejected PR. Runs inside a detached tmux session.
# Works in the PR's EXISTING worktree/branch, addresses the reviewer's fix
# list, re-runs the gates, pushes, and lifts the verdict label so review.sh
# re-reviews on the next poll. NEVER pushes to main.
# Usage: rework-run.sh <pr-number> <round>
set -euo pipefail
REPO="${AGENT_REPO:-$HOME/Repos/a_fish_in_sea}"
cd "$REPO"
DIR="$REPO/tools/agent"
LLM_RUN="${AGENT_LLM_RUN:-$DIR/llm-run.sh}"
N="$1"
ROUND="$2"
TIER="${3:-0}"
STATE="${AGENT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/a_fish_in_sea}"
mkdir -p "$STATE"
exec 8>"$STATE/rework-$N.lock"
flock -n 8 || exit 0
# A crash, contract failure or quota failure retries without burning a round.
# Even a terminal-tier run gets another chance, but never every 15 minutes.
printf '%s\n' "$(( $(date +%s) + 3600 ))" >"$STATE/rework-$N-retry"
BRANCH="$(gh pr view "$N" --json headRefName --jq .headRefName)"
WT="$(git worktree list --porcelain | awk -v b="$BRANCH" 'BEGIN{dir=""} /^worktree /{dir=$2} $0=="branch refs/heads/"b {print dir; exit}')"
if [ -z "${WT:-}" ] || [ ! -d "$WT" ]; then
  echo "[rework] #$N worktree for $BRANCH missing — aborting"
  exit 1
fi
if [ -n "$(git -C "$WT" status --porcelain --untracked-files=all | sed '/^?? \.agent-.*\.log$/d')" ]; then
  echo "[rework] $WT has uncommitted work — refusing to overwrite another writer"
  exit 1
fi
echo "[rework] #$N round $ROUND in $WT ($BRANCH)"

PROMPT="You are the rework builder. Work ONLY inside this worktree: $WT (branch $BRANCH).
PR: gh pr view $N --json number,title,body,comments (run it to get context).
Linked issue: find Closes #<n> in the PR body, then gh issue view <n> --json number,title,body,comments for the latest plan + tester follow-ups (newest tester comment wins on conflict).
Rules:
Escalation tier $TIER: independently address concrete failures, and explain evidence-backed disagreements. Do not expand scope for stylistic demands. Never merge or waive the separate guardians.
1. Read the LATEST <!-- agent-review --> verdict comment on the PR (changes-requested) and address EVERY item in its Fix list, nothing more. If you genuinely disagree with an item, leave the code and explain why in your rework comment instead. If a fix item points at a screenshot, download it (curl -sL \"<url>\" -o /tmp/opencode/rework-$N-<i>.png) and READ it with the read tool — never say an image could not be loaded.
2. Keep the diff small — fix, don't redesign. AGENTS.md persistence rules still apply exactly.
3. Gates (must both pass): ~/flutter/bin/flutter analyze (0 issues) and ~/flutter/bin/flutter test (all pass; extend tests where meaningful — widget, golden, or patrol_test as appropriate; reproduce any baseline failure on the base revision and report it separately).
4. Commit on $BRANCH, push origin $BRANCH. NEVER push to main, NEVER commit to main.
5. Do NOT change verdict labels or post an agent-rework marker. The wrapper owns that state. Include your fix-by-fix summary and gate evidence in your final output.
Report at the end: STATUS=<ready|failed>."
# Route through llm-run.sh so rework uses the same per-host backend choice
# as builders (FISH_LLM_REWORK_BACKEND=codex). Run from inside the worktree:
# codex's workspace-write sandbox anchors on cwd, and llm-run adds the
# worktree git dir as a writable root so commits work.
REWORK_LOG="$WT/.agent-rework-$ROUND.log"
REWORK_TRANSCRIPT="$WT/.agent-rework-$ROUND-transcript.log"
: >"$REWORK_TRANSCRIPT"
RESULT="$(mktemp)"
trap 'rm -f "$RESULT"' EXIT
if ( cd "$WT" && printf '%s' "$PROMPT" \
    | FISH_LLM_TRANSCRIPT="$REWORK_TRANSCRIPT" \
      "$LLM_RUN" --role rework --tier "$TIER" --title "rework-#$N-r$ROUND" \
        --expect '^STATUS=(ready|failed)[[:space:]]*$' ) >"$RESULT" 2>"$REWORK_LOG"; then
  cat "$RESULT" >>"$REWORK_LOG"
  # Fetch CURRENT remote SHA, since the worker may have pushed new commits.
  SHA="$(gh pr view "$N" --json headRefOid --jq .headRefOid)"
  BODY="$(mktemp)"
  { printf '<!-- agent-rework --> round=%s tier=%s sha=%s\n' "$ROUND" "$TIER" "$SHA"; cat "$RESULT"; } >"$BODY"
  if gh pr comment "$N" --body-file "$BODY" >/dev/null; then
    if grep -qx 'STATUS=ready' "$RESULT"; then
      "$DIR/label.sh" "$N" remove review:changes-requested
    fi
    echo "[rework] #$N round $ROUND completed at tier $TIER"
  fi
  rm -f "$BODY"
else
  echo "[rework] #$N infrastructure/contract failure — round not consumed (see $REWORK_LOG)"
fi
