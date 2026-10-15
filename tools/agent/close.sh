#!/usr/bin/env bash
# Closer step of the agent loop: close issues the loop already resolved and
# remove the debris they leave behind. Safe to re-run: every action checks
# live state first, nothing is forced, and branches/worktrees tied to OPEN
# issues are never touched (a builder or human may be working in them).
#
# An OPEN issue is closed when EITHER holds:
#   1. a PR merged into main carries `Closes|Fixes|Resolves #N` in its body, or
#   2. a PR from branch `agent/<N>-*` merged into main (the builder forgot the
#      keyword, so GitHub auto-close never fired).
# On close: comment with the merged-PR link, strip agent labels, ping Telegram.
#
# Debris removal — ONLY for branches whose work is provably landed or empty:
#   - remote agent/* branch whose head PR merged into main -> delete.
#   - local agent/* branch with no commits past origin/main, tied to a CLOSED
#     issue or a merged PR -> delete (its worktree is removed first, but only
#     when the tree has no uncommitted changes).
#   - local agent/* branch whose tip exactly matches its merged PR head ->
#     delete (squash/rebase merges leave the branch tip behind; the PR keeps
#     the history, and the tip-match proves nothing newer was added locally).
# Everything else (open-issue branches, ad-hoc branches, pushed branches with
# no PR, unique unmerged work) is reported, never deleted.
#
# Usage: close.sh [--dry-run]   (dry-run prints actions, changes nothing)
set -euo pipefail
REPO="$HOME/Repos/a_fish_in_sea"
cd "$REPO"
DIR="$REPO/tools/agent"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

run() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "[close] DRY-RUN: $*"
  else
    "$@"
  fi
}

git fetch origin --quiet 2>&1 | head -n 5 || true

ACTIONS=0
REPORT=""

note() {
  ACTIONS=$((ACTIONS + 1))
  REPORT="${REPORT}- $1
"
  echo "[close] $1"
}

issue_state() {
  gh issue view "$1" --json state --jq .state 2>/dev/null || echo UNKNOWN
}

worktree_for() {
  git worktree list --porcelain \
    | awk -v b="$1" 'BEGIN{dir=""} /^worktree /{dir=$2} $0=="branch refs/heads/"b {print dir; exit}'
}

tree_dirty() {
  [ -n "$(git -C "$1" status --porcelain 2>/dev/null | head -n 5)" ]
}

# --- 1. issues resolved by merged PRs -------------------------------------
MERGED_JSON="$(gh pr list --state merged --limit 50 \
  --json number,title,headRefName,baseRefName,body,url 2>/dev/null || echo '[]')"
CANDIDATES="$(echo "$MERGED_JSON" | python3 -c "
import json, re, sys
prs = json.load(sys.stdin)
out = {}
for p in prs:
    if p.get('baseRefName') != 'main':
        continue
    key = (p['number'], p['title'], p['url'])
    for m in re.finditer(r'(?:closes|fixes|resolves)\s+#(\d+)', p.get('body') or '', re.I):
        out.setdefault(int(m.group(1)), set()).add(key)
    m = re.match(r'agent/(\d+)-', p.get('headRefName') or '')
    if m:
        out.setdefault(int(m.group(1)), set()).add(key)
for n in sorted(out):
    for num, title, url in sorted(out[n]):
        print(f'{n}|{num}|{title}|{url}')
")"
if [ -n "$CANDIDATES" ]; then
  while IFS='|' read -r N PRNUM PRTITLE PRURL; do
    [ -z "$N" ] && continue
    if [ "$(issue_state "$N")" != "OPEN" ]; then
      continue
    fi
    LABELS="$(gh issue view "$N" --json labels --jq '[.labels[].name] | join(" ")' 2>/dev/null || true)"
    run gh issue comment "$N" --body "Closed by the agent loop: PR #$PRNUM ($PRTITLE) merged into main.
$PRURL" >/dev/null
    for L in agent-pending agent-approved review:pass review:changes-requested; do
      case " $LABELS " in *" $L "*) run gh issue edit "$N" --remove-label "$L" >/dev/null;; esac
    done
    run gh issue close "$N" >/dev/null
    note "closed #$N (merged PR #$PRNUM: $PRTITLE)"
  done <<< "$CANDIDATES"
else
  echo "[close] no merged PRs reference open issues"
fi

# --- 2a. remote agent branches --------------------------------------------
# NOTE: match both naming shapes. The loop's own glob 'agent/*' misses the
# no-slash names (agent-24-scheduled-assignment-disappears,
# agent-task-conflict-granularity, ...) — those branches were invisible to
# cleanup AND to the no-PR report, which is how a finished feature sat
# unmerged on origin for two days with zero pings.
REMOTE_BRANCHES="$(git ls-remote --heads origin 'agent/*' 'agent-*' 2>/dev/null \
  | awk '{print $2}' | sed 's|refs/heads/||' | sort -u)"
if [ -n "$REMOTE_BRANCHES" ]; then
  while read -r RB; do
    [ -z "$RB" ] && continue
    MERGED_PR="$(gh pr list --head "$RB" --state merged --limit 5 \
      --json number,baseRefName \
      --jq '.[] | select(.baseRefName=="main") | .number' 2>/dev/null | head -n 1 || true)"
    if [ -n "${MERGED_PR:-}" ]; then
      run git push origin --delete "$RB" --quiet
      note "deleted remote branch $RB (PR #$MERGED_PR merged into main)"
      continue
    fi
    OPEN_PR="$(gh pr list --head "$RB" --state open --limit 1 --json number \
      --jq '.[0].number // empty' 2>/dev/null || true)"
    if [ -z "${OPEN_PR:-}" ]; then
      if [ -z "$(git log --oneline "origin/main..origin/$RB" 2>/dev/null | head -n 3)" ]; then
        echo "[close] remote branch $RB is empty with no PR — leaving it (its issue may still be open; the builder reuses it)"
      else
        # Report ONCE per branch per day. Re-pinging every 15 minutes read
        # as "the loop expects me to open the PRs myself" and trained the
        # human to ignore the channel — the opposite of what an escalation
        # is for. build.sh now auto-opens the PR for approved issues; this
        # only fires for branches the dispatcher can't handle.
        REPORTED_DIR="/tmp/opencode/agent-loop-reported"
        mkdir -p "$REPORTED_DIR"
        KEY="$REPORTED_DIR/$(echo "$RB" | tr '/' '_').no-pr"
        if [ -f "$KEY" ] && [ $(( $(date +%s) - $(stat -c %Y "$KEY") )) -lt 86400 ]; then
          echo "[close] remote branch $RB still needs a PR (last ping <24h ago) — not repeating"
        else
          note "remote branch $RB has NO PR and unmerged work — needs a human (open a PR or delete it)"
          touch "$KEY"
        fi
      fi
    fi
  done <<< "$REMOTE_BRANCHES"
fi

# --- 2b. local agent branches ---------------------------------------------
# Delete only when the linked issue is CLOSED or the head PR merged into
# main; never touch ad-hoc branches or branches of open issues.
# NOTE: match both naming shapes like the remote cleanup above (agent/* and
# agent-*); non-numeric names only delete when their PR merged and the tip
# matches the merged head.
LOCAL_BRANCHES="$(git branch --list 'agent/*' 'agent-*' 2>/dev/null | sed 's/^[*+ ]*//' | sort -u)"
if [ -n "$LOCAL_BRANCHES" ]; then
  while read -r LB; do
    [ -z "$LB" ] && continue
    case "$LB" in agent/adhoc-*|agent-adhoc-*) continue;; esac
    MERGED_HEAD="$(gh pr list --head "$LB" --state merged --limit 5 \
      --json headRefOid,baseRefName \
      --jq '.[] | select(.baseRefName=="main") | .headRefOid' 2>/dev/null | head -n 1 || true)"
    NUM="$(echo "$LB" | sed -n -e 's|^agent/\([0-9]\+\)-.*|\1|p' -e 's|^agent-\([0-9]\+\)-.*|\1|p')"
    ISSUE_CLOSED=0
    if [ -n "$NUM" ] && [ "$(issue_state "$NUM")" = "CLOSED" ]; then
      ISSUE_CLOSED=1
    fi
    if [ -z "${MERGED_HEAD:-}" ] && [ "$ISSUE_CLOSED" = "0" ]; then
      continue  # open issue (or untracked branch) — a builder/human may own it
    fi
    UNIQUE="$(git log --oneline "origin/main..$LB" 2>/dev/null | head -n 3)"
    if [ -n "$UNIQUE" ]; then
      if [ -z "${MERGED_HEAD:-}" ]; then
        continue  # closed issue but unmerged local work — human decides
      fi
      if [ "$(git rev-parse "$LB" 2>/dev/null)" != "$MERGED_HEAD" ]; then
        note "kept local branch $LB: tip differs from its merged PR head — needs a human"
        continue
      fi
      # Tip matches the merge: squash/rebase leftovers, PR keeps the history.
    fi
    WT="$(worktree_for "$LB")"
    if [ -n "${WT:-}" ]; then
      if [ ! -d "$WT" ]; then
        run git worktree prune
        note "pruned stale worktree metadata for $LB"
      elif tree_dirty "$WT"; then
        note "kept worktree $WT ($LB): uncommitted changes — needs a human"
        continue
      else
        run git worktree remove "$WT" --force
        note "removed worktree $WT (branch $LB done)"
      fi
    fi
    if git show-ref --verify --quiet "refs/heads/$LB"; then
      run git branch -D "$LB"
      note "deleted local branch $LB (done)"
    fi
  done <<< "$LOCAL_BRANCHES"
fi

if [ "$ACTIONS" = "0" ]; then
  echo "[close] done — nothing to close or clean"
else
  echo "[close] done — $ACTIONS action(s)"
  if [ "$DRY_RUN" = "0" ]; then
    "$DIR/tg.sh" "🧹 Agent loop closed/cleaned $ACTIONS item(s):
$REPORT" || echo "[close] telegram ping failed (actions still applied)"
  fi
fi
