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
if [ -e "$WT" ]; then
  echo "[builder] #$N worktree path $WT already exists — skipping (remove it to retry)"
  exit 1
fi
# A previous run may have created the local branch but lost its worktree
# (then every relaunch died in `worktree add -b`, which refuses an existing
# branch name). Recover instead of crashing: resume a branch that holds
# unique work, recreate one that is empty. A branch already checked out in
# another worktree is resumed in place — but only when that worktree is
# provably loop-owned (it holds .agent-build.log); a foreign tree is left
# alone for a human instead of being contaminated.
RESUME_IN_PLACE=0
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  IN_USE="$(git worktree list --porcelain | awk -v b="$BRANCH" 'BEGIN{dir=""} /^worktree /{dir=$2} $0=="branch refs/heads/"b {print dir; exit}')"
  if [ -n "${IN_USE:-}" ]; then
    if [ -f "$IN_USE/.agent-build.log" ]; then
      echo "[builder] #$N resuming previous builder work in $IN_USE"
      WT="$IN_USE"
      RESUME_IN_PLACE=1
    else
      echo "[builder] #$N branch $BRANCH is checked out in $IN_USE (not a loop worktree) — leaving it alone, needs a human"
      exit 1
    fi
  elif [ -z "$(git log --oneline "origin/main..$BRANCH" 2>/dev/null)" ]; then
    echo "[builder] #$N local branch $BRANCH is empty (nothing past origin/main) — recreating from origin/main"
    if [ -e "$WT" ]; then
      echo "[builder] #$N worktree path $WT already exists — skipping (remove it to retry)"
      exit 1
    fi
    git branch -D "$BRANCH"
    git worktree add "$WT" -b "$BRANCH" origin/main
  else
    echo "[builder] #$N resuming local branch $BRANCH with unpushed work"
    if [ -e "$WT" ]; then
      echo "[builder] #$N worktree path $WT already exists — skipping (remove it to retry)"
      exit 1
    fi
    git worktree add "$WT" "$BRANCH"
  fi
else
  if [ -e "$WT" ]; then
    echo "[builder] #$N worktree path $WT already exists — skipping (remove it to retry)"
    exit 1
  fi
  git worktree add "$WT" -b "$BRANCH" origin/main
fi
if [ ! -d "$WT" ]; then
  echo "[builder] #$N worktree $WT missing after add — aborting"
  exit 1
fi
echo "[builder] #$N worktree $WT branch $BRANCH"

# Pre-download issue screenshots so the builder can VIEW them (same reason
# as triage: headless agents read local images, not remote URLs).
IMGDIR="/tmp/opencode/issue-$N-imgs"
"$DIR/fetch-issue-images.sh" "$N" "$IMGDIR" >/dev/null 2>&1 || true
IMGS="$(ls "$IMGDIR"/img*.* 2>/dev/null | tr '\n' ' ' || true)"
[ -z "${IMGS// /}" ] && IMGS="(none — no image attachments found)"

PROMPT="You are the builder agent. Work ONLY inside this worktree: $WT (branch $BRANCH, based on origin/main).
Spec: gh issue view $N --json number,title,body,comments (run it to get the FULL thread — body plus every comment).
Rules:
1. The contract is the LATEST <!-- agent-plan --> comment PLUS any tester clarifications posted after it. Read the whole thread newest-to-oldest: follow-up tester comments override or narrow the plan. If plan + follow-ups conflict, follow the newest tester comment. Do NOT freelance beyond plan + follow-ups. If both together are still wrong or unimplementable, say so in the PR body instead of inventing scope.
2. Screenshots are part of the spec — never say an image could not be loaded: pre-downloaded issue images (if any) are in $IMGDIR (found: $IMGS) — list that dir and READ each image with the read tool to VIEW it. If the thread mentions /tmp/opencode/... paths (ux-walk screenshots/reports on this loop host), read those directly. Any other image URL you have not viewed: curl -sL \"<url>\" -o /tmp/opencode/issue-$N-build-<i>.png then READ it, and use what you see to locate the exact screen/widget.
3. Keep the diff SMALL and focused: the issue and nothing else. No drive-by refactors, no unrelated cleanups, no formatting churn. If the change naturally exceeds ~300 lines, stop and explain why in the PR body instead of ballooning it.
4. Follow AGENTS.md persistence rules exactly (additive-only models, orElse enum fallback, gated migrations with Migration.removeAfter, extend tolerance tests).
5. NEVER push to main, NEVER commit to main.
6. Gates (must both pass): ~/flutter/bin/flutter analyze (0 issues) and ~/flutter/bin/flutter test (all pass, add/update tests for the change, including goldens under test/goldens/ if you touched a screen).
7. If you touched a user flow (auth, navigation, create/edit/delete, sync), add or extend a patrol_test and run it headless against the dev API server: export PATH="$HOME/.local/bin:$HOME/.pub-cache/bin:$PATH" PATROL_ANALYTICS_ENABLED=false; patrol test --device chrome --web-headless --target patrol_test/<file>.dart --dart-define=SERVER_URL=http://127.0.0.1:8000 (needs the API server on :8000; uses a unique test account per run).
8. UX check (AGENTS.md rule): do NOT run the ux-walker yourself — the agent loop walks each deploy exactly once (tools/agent/ux-walk.sh via poll.sh), and per-branch walks duplicate that work while contending for the same browser. If the triage plan says UX check: needed OR you touched lib/*/view, navigation, dialogs/sheets, or user-facing copy: run gh issue edit $N --add-label ux-walk and record the scope (screens/flows touched + how to reach them, 1-2 lines) in the PR body under a 'UX scope:' heading. The post-deploy walk covers it and files findings as new issues. Never gate your PR on a walk verdict.
9. Commit on $BRANCH, push origin $BRANCH, open PR with: gh pr create --base main --head $BRANCH --title \"[agent #$N] <title>\" --body \"Closes #$N. Scope: <one line, matches the latest triage plan + tester follow-ups>. UX scope: <screens/flows touched + how to reach them, or 'none — no user-visible change'>. Test log: <paste tail of flutter test>. Risk notes: <...>. Screenshots: <host paths under /tmp/opencode/ you verified against, for UX-filed issues>\"
10. If the gates fail and you cannot fix within reason, push the branch anyway and report FAIL status in the PR body.
A separate reviewer agent will read your diff against the plan — write the PR body for a skeptical reader.
Report at the end: PR_URL=<url or NONE> STATUS=<ready|failed>."
if [ "$RESUME_IN_PLACE" = "1" ] && [ -f "$WT/.agent-build.log" ]; then
  mv "$WT/.agent-build.log" "$WT/.agent-build-prev.log"
fi
if opencode run --auto --title "builder-#$N" "$PROMPT" >"$WT/.agent-build.log" 2>&1; then
  echo "[builder] #$N opencode run finished"
else
  echo "[builder] #$N opencode run exited non-zero (see $WT/.agent-build.log)"
fi
PR_URL="$(grep -m1 -o 'https://github.com/[^ ]*/pull/[0-9]*' "$WT/.agent-build.log" || true)"
[ -z "$PR_URL" ] && PR_URL="$(gh pr list --head "$BRANCH" --json url --jq '.[0].url // empty' || true)"
[ -z "$PR_URL" ] && PR_URL="NONE (check $WT/.agent-build.log)"
# Outcome stamp for the dispatcher (build.sh): a run that produced no PR is
# re-launched only after AGENT_BUILDER_COOLDOWN_S, so a single model-rate-
# limited death cannot become a 15-minute relaunch storm.
mkdir -p /tmp/opencode/agent-loop-cd
if [[ "$PR_URL" == NONE* ]]; then
  date +%s > "/tmp/opencode/agent-loop-cd/$N"
else
  rm -f "/tmp/opencode/agent-loop-cd/$N"
fi
"$DIR/tg.sh" "🔨 Builder finished #$N: $TITLE
PR: $PR_URL
$URL" || true
echo "[builder] #$N done PR=$PR_URL"
