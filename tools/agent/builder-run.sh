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
# Retry-stamp helper: any run that ends without a PR (or exits before
# starting) writes a "not before" epoch for the dispatcher (build.sh), so
# the issue is retried ~RETRY_BASE_S later instead of every 15 minutes.
# The delay is rolled ONCE here — never per poll — so retries spread out
# without re-rolling into a relaunch storm that starves the model quota.
# Jitter is +/-25% of the base, capped at +/-15min. Override the base with
# AGENT_BUILDER_COOLDOWN_S (seconds, default 3600).
# NOTE: defined up here (not next to its main use at the end) so the
# pre-opencode guards below can stamp a backoff instead of dying silently.
RETRY_BASE_S="${AGENT_BUILDER_COOLDOWN_S:-3600}"
write_retry_stamp() {
  local maxj=$(( RETRY_BASE_S / 4 ))
  [ "$maxj" -gt 900 ] && maxj=900
  local jit=0
  [ "$maxj" -gt 0 ] && jit=$(( RANDOM % (2 * maxj + 1) - maxj ))
  mkdir -p /tmp/opencode/agent-loop-cd
  date +%s -d "@$(( $(date +%s) + RETRY_BASE_S + jit ))" >"/tmp/opencode/agent-loop-cd/$N"
}

TITLE="$(gh issue view "$N" --json title --jq .title)" \
  || { echo "[builder] #$N gh issue view failed — backing off"; write_retry_stamp; exit 1; }
URL="$(gh issue view "$N" --json url --jq .url)" \
  || { echo "[builder] #$N gh issue view failed — backing off"; write_retry_stamp; exit 1; }
SLUG="$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\+/-/g' | cut -c1-40 | sed 's/-$//')"
BRANCH="agent/$N-$SLUG"
WT="$HOME/Repos/worktrees/agent-$N-$SLUG"

git fetch origin --quiet \
  || { echo "[builder] #$N git fetch failed — backing off"; write_retry_stamp; exit 1; }
if git ls-remote --heads origin "$BRANCH" | grep -q .; then
  echo "[builder] #$N branch $BRANCH already exists — skipping"
  exit 0
fi
# --- recover or create the worktree ---------------------------------------
# A previous run may have left a worktree + branch behind (its opencode run
# died on the model rate limit). Recovery order matters: the
# worktree-already-exists check used to bail out with exit 1 BEFORE this
# resume logic, so every relaunch died without ever starting opencode —
# that is how the approved issues #8/#9/#14-#19/#30 sat for two days while
# the poll relaunched them every 15 minutes.
RESUME_IN_PLACE=0
if [ -e "$WT" ]; then
  # Worktree present: resume in it when our branch is checked out there AND
  # the tree is provably loop-owned (it holds its build log), keeping any
  # uncommitted WIP. Anything else is left for a human.
  IN_USE="$(git worktree list --porcelain | awk -v b="$BRANCH" 'BEGIN{dir=""} /^worktree /{dir=$2} $0=="branch refs/heads/"b {print dir; exit}')"
  if [ "${IN_USE:-}" = "$WT" ] && { [ -f "$WT/.agent-build.log" ] || [ -f "$WT/.agent-build-prev.log" ]; }; then
    echo "[builder] #$N resuming previous builder work in $WT (WIP uncommitted changes are kept)"
    RESUME_IN_PLACE=1
  else
    REPORTED_DIR="/tmp/opencode/agent-loop-reported"
    mkdir -p "$REPORTED_DIR"
    KEY="$REPORTED_DIR/builder-$N-conflict.no-pr"
    # Auto-reclaim when provably lossless: our branch is checked out at
    # exactly this path, it holds zero commits past origin/main, and the
    # tree is clean (porcelain empty covers staged, unstaged, AND
    # untracked files). Removing such a leftover destroys nothing — no
    # commits, no uncommitted work — so start fresh instead of paging a
    # human. Anything else (unique commits, dirty tree, branch checked out
    # elsewhere, path that is not a repo checkout) stays on the human path
    # below. Journal-only on reclaim: no Telegram ping for a self-healed
    # stall; the normal "Builder finished" ping still fires at the end.
    if [ "${IN_USE:-}" = "$WT" ] \
      && [ -z "$(git log --oneline "origin/main..$BRANCH" 2>/dev/null || true)" ] \
      && [ -d "$WT" ] \
      && [ -z "$(git -C "$WT" status --porcelain 2>/dev/null || echo NOT-A-REPO)" ]; then
      echo "[builder] #$N reclaiming empty leftover worktree $WT (branch $BRANCH identical to origin/main, tree clean) — no human action needed"
      if git worktree remove "$WT" --force \
        && { git branch -D "$BRANCH" 2>/dev/null || true; } \
        && git worktree add "$WT" -b "$BRANCH" origin/main; then
        rm -f "/tmp/opencode/agent-loop-cd/$N" "$KEY" 2>/dev/null || true
      else
        echo "[builder] #$N reclaim failed mid-way — backing off for a human to inspect"
        write_retry_stamp
        exit 1
      fi
    else
    echo "[builder] #$N worktree path $WT already exists (branch checked out there: ${IN_USE:-none}) — skipping, needs a human (remove it to retry)"
    write_retry_stamp
    # This path dies inside a detached tmux session, so without a ping the
    # stall is invisible until someone reads the journal — ping at most
    # once a day (same pattern as close.sh's no-PR report).
    if [ ! -f "$KEY" ] || [ $(( $(date +%s) - $(stat -c %Y "$KEY") )) -ge 86400 ]; then
      # Descriptive escalation: the leftover was NOT auto-reclaimable (it
      # holds unique commits, uncommitted changes, or the branch is
      # checked out somewhere unexpected), so the loop refuses to delete it
      # — it may hold a human's work. Show the actual state so the human
      # can decide at a glance.
      COMMITS="$(git log --oneline "origin/main..$BRANCH" 2>/dev/null | head -n 5 || true)"
      [ -n "${COMMITS:-}" ] || COMMITS="(none — branch is identical to origin/main)"
      if [ -d "$WT" ]; then
        DIRTY="$(git -C "$WT" status --porcelain 2>/dev/null | head -n 10 || true)"
        [ -n "${DIRTY:-}" ] || DIRTY="(none — worktree is clean)"
      else
        DIRTY="(path exists but is not a usable worktree checkout)"
      fi
      "$DIR/tg.sh" "🧑 Builder for #$N cannot start — worktree blocked, human check needed:
Issue: $TITLE
$URL
Expected branch: $BRANCH | worktree: $WT | branch checked out there: ${IN_USE:-none}
Why the loop stopped itself: the path exists but carries no loop marker (.agent-build.log), so the loop cannot prove it owns the tree and refuses to delete it (CONVENTIONS.md: never touch another writer's tree — it may hold uncommitted work).
Branch state (commits past origin/main):
$COMMITS
Uncommitted changes in $WT:
$DIRTY
What to do: if the state above is empty/expected, reclaim it with:
  git worktree remove \"$WT\" --force
  git branch -D \"$BRANCH\"  # only if Branch state shows (none) above
  rm -f /tmp/opencode/agent-loop-cd/$N  # clear backoff so the next poll retries immediately
Loop behavior while blocked: issue backs off ~1h between retries; this ping repeats at most once/day. Nothing is deleted automatically." || true
      touch "$KEY"
    fi
    exit 1
    fi
  fi
elif git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  # Local branch exists without its worktree. `worktree add -b` refuses an
  # existing branch name, so reuse a branch that holds unique work and
  # recreate one that is empty.
  if [ -z "$(git log --oneline "origin/main..$BRANCH" 2>/dev/null)" ]; then
    echo "[builder] #$N local branch $BRANCH is empty (nothing past origin/main) — recreating from origin/main"
    git branch -D "$BRANCH"
    git worktree add "$WT" -b "$BRANCH" origin/main
  else
    echo "[builder] #$N resuming local branch $BRANCH with unpushed work"
    git worktree add "$WT" "$BRANCH"
  fi
else
  git worktree add "$WT" -b "$BRANCH" origin/main
fi
if [ ! -d "$WT" ]; then
  echo "[builder] #$N worktree $WT missing after add — aborting"
  write_retry_stamp
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
5. NEVER push to main, NEVER commit to main. You are a LOOP BUILDER, not an ad-hoc agent: AGENTS.md's \"Ad-hoc: YOU ship it\" clause and CONVENTIONS.md rule 4 (merge from a throwaway worktree) do NOT apply to you — they are for human/ad-hoc sessions. Do NOT merge your branch into main yourself (no merge worktree, no fast-forward push), do NOT run tools/agent/deploy.sh or flutter build web, and do NOT verify or touch build/web. Shipping for you means: the PR is open. The loop's merge step auto-merges fully-gated PRs (review:pass + data:safe + sec:safe at your head SHA) and the loop deploys — no human merge stands in the path. A builder that merges or deploys itself has bypassed the review gate and is a bug.
6. Gates (must both pass): ~/flutter/bin/flutter analyze (0 issues) and ~/flutter/bin/flutter test (all pass, add/update tests for the change, including goldens under test/goldens/ if you touched a screen).
7. If you touched a user flow (auth, navigation, create/edit/delete, sync), add or extend a patrol_test and run it headless against the dev API server: export PATH=\"$HOME/.local/bin:$HOME/.pub-cache/bin:$PATH\" PATROL_ANALYTICS_ENABLED=false; patrol test --device chrome --web-headless --target patrol_test/<file>.dart --dart-define=SERVER_URL=http://127.0.0.1:8000 (needs the API server on :8000; uses a unique test account per run).
8. UX check (AGENTS.md rule): do NOT run the ux-walker yourself — the agent loop walks each deploy exactly once (tools/agent/ux-walk.sh via poll.sh), and per-branch walks duplicate that work while contending for the same browser. If the triage plan says UX check: needed OR you touched lib/*/view, navigation, dialogs/sheets, or user-facing copy: run gh issue edit $N --add-label ux-walk and record the scope (screens/flows touched + how to reach them, 1-2 lines) in the PR body under a 'UX scope:' heading. The post-deploy walk covers it and files findings as new issues. Never gate your PR on a walk verdict.
9. Commit on $BRANCH, push origin $BRANCH, open PR with: gh pr create --base main --head $BRANCH --title \"[agent #$N] <title>\" --body \"Closes #$N. In plain words: <2-4 sentences saying what the user will notice and why, written for a maintainer who has NOT read the code — name screens and behavior, no jargon, no class/function names>. Scope: <one line, matches the latest triage plan + tester follow-ups>. UX scope: <screens/flows touched + how to reach them, or 'none — no user-visible change'>. Test log: <paste tail of flutter test>. Risk notes: <one line, plain words first, then technical detail if needed>. Screenshots: <host paths under /tmp/opencode/ you verified against, for UX-filed issues>\". If gh pr create fails with \"No commits between main and <branch>\" (your branch's commits are already in main), do NOT merge, push, or deploy anything to fix it — report PR_URL=NONE with that exact reason and stop; a human will sort out how it landed.
10. If the gates fail and you cannot fix within reason, push the branch anyway and report FAIL status in the PR body.
11. Commit messages on $BRANCH must NOT contain fix/fixes/fixed/close/closes/resolves #$N — if such a commit ever lands on main (e.g. through a merge), GitHub auto-closes the issue before the review/guardian gates have run. Use \"refs #$N\" in commit messages; the PR body is where \"Closes #$N\" belongs.
A separate reviewer agent will read your diff against the plan — write the PR body for a busy maintainer who has not read the code: plain words first, technical detail after.
Report at the end: PR_URL=<url or NONE> STATUS=<ready|failed>."

# Tripwire for a silent-killer quoting bug: PROMPT is one huge
# double-quoted string, so a single unescaped inner " truncates it mid-way
# and the run dies here with no log and no retry stamp (Oct 2026: the
# rule-5 "Ad-hoc: ..." quotes did exactly this — every builder launch died
# pre-opencode for days while the dispatcher relaunched it each poll).
# Refuse loudly instead of vanishing.
[[ "$PROMPT" == *"STATUS=<ready|failed>"* ]] \
  || { echo "[builder] #$N PROMPT failed its integrity check — backing off"; write_retry_stamp; exit 1; }

# NOTE (2026-10-15): the PR body is the maintainer's primary reading
# material, and model prose skews too technical to parse without deep
# codebase context — hence the "In plain words" lead section required
# above. If readability is still poor, route the commentary through
# longcat (clear explanations, weak code): e.g. a second pass that
# rewrites the PR body in plain words before `gh pr create`.
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
# Outcome stamp for the dispatcher (build.sh): a run that produced no PR
# writes a retry time (~1h + jitter via write_retry_stamp) instead of going
# back into the every-15-minutes pool, so a model-rate-limited death cannot
# become a relaunch storm. A rate-limited run is retried the same way —
# the quota just needs time to recover.
mkdir -p /tmp/opencode/agent-loop-cd
RATE_NOTE=""
if [[ "$PR_URL" == NONE* ]]; then
  write_retry_stamp
  RETRY_AT="$(cat "/tmp/opencode/agent-loop-cd/$N" 2>/dev/null || echo 0)"
  if grep -qiE 'rate limit exceeded|rate_limit|http 429|too many requests' "$WT/.agent-build.log" 2>/dev/null; then
    RATE_NOTE="hit the model rate limit — "
  fi
  RATE_NOTE="${RATE_NOTE}retrying after ~$(date -d "@$RETRY_AT" '+%H:%M' 2>/dev/null || echo '1h'): "
else
  rm -f "/tmp/opencode/agent-loop-cd/$N"
fi
echo "[builder] #$N done PR=$PR_URL (no telegram: notify-quiet)"
