#!/usr/bin/env bash
# Merge step of the agent loop (auto-ship mode, 2026-10-17): merges agent PRs
# that are fully gated, without a human in the path. Runs in poll.sh after
# the guardians (review -> data-guard -> sec-guard -> merge -> deploy), so
# every merged PR has fresh verdicts from all three checkers.
#
# A PR is merged ONLY when ALL hold:
#   - head branch is a numeric loop branch (agent/<N>-* or agent-<N>-*;
#     ad-hoc/human branches are never touched),
#   - labels review:pass + data:safe + sec:safe are present, and NONE of
#     review:changes-requested / data:blocked / sec:blocked is present,
#   - the review verdict comment AND both guardian audit comments cover the
#     PR's CURRENT head SHA (stale passes from before the latest push do
#     not count — review.sh drops stale passes, guardians re-audit per SHA),
#   - GitHub reports the PR mergeable (MERGEABLE; UNKNOWN retries next poll,
#     CONFLICTING escalates to a human at most once/day).
#
# Merge is server-side (`gh pr merge --merge`): no local worktree, no
# CONVENTIONS.md rule-4 concerns (that rule governs local merges into main
# by writers; this step never checks out another writer's tree). Builders
# still MUST NOT merge anything themselves.
#
# Telegram: quiet by design — the deploy step announces what shipped.
# Only a conflicting PR (needs a human rebase decision) pings, throttled
# to once/day. Everything else is journal-only; the next poll retries.
set -euo pipefail
REPO="$HOME/Repos/a_fish_in_sea"
cd "$REPO"
DIR="$REPO/tools/agent"

PASS_LABEL="review:pass"
FAIL_LABEL="review:changes-requested"
DATA_PASS="data:safe"
DATA_FAIL="data:blocked"
SEC_PASS="sec:safe"
SEC_FAIL="sec:blocked"
REVIEW_MARKER='<!-- agent-review -->'
DATA_MARKER='<!-- data-guard -->'
SEC_MARKER='<!-- sec-guard -->'

PRS="$(gh pr list --state open --limit 20 \
  --json number,headRefName,headRefOid,mergeable,mergeStateStatus,title,url 2>/dev/null || echo '[]')"
COUNT="$(echo "$PRS" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
echo "[merge] open PRs: $COUNT"
[ "$COUNT" = "0" ] && exit 0

echo "$PRS" | python3 -c '
import json, sys
for p in json.load(sys.stdin):
    print("|".join([str(p["number"]), p.get("headRefName") or "", p.get("headRefOid") or "",
                    p.get("mergeable") or "", p.get("mergeStateStatus") or "",
                    (p.get("title") or "").replace("|", " "), p.get("url") or ""]))
' | while IFS='|' read -r N BRANCH SHA MERGEABLE MERGESTATE TITLE URL; do
  [ -z "${N:-}" ] && continue
  case "$BRANCH" in
    agent/[0-9]*|agent-[0-9]*) ;;
    *) echo "[merge] #$N ($BRANCH) not a numeric loop branch — skipping (never auto-merge ad-hoc/human branches)"; continue ;;
  esac

  LABELS="$(gh pr view "$N" --json labels --jq '.labels[].name' 2>/dev/null || true)"
  has() { echo "$LABELS" | grep -qx "$1"; }
  if has "$FAIL_LABEL" || has "$DATA_FAIL" || has "$SEC_FAIL"; then
    echo "[merge] #$N has a blocking label (changes-requested/data:blocked/sec:blocked) — skipping"
    continue
  fi
  if ! has "$PASS_LABEL" || ! has "$DATA_PASS" || ! has "$SEC_PASS"; then
    echo "[merge] #$N not fully gated (needs $PASS_LABEL + $DATA_PASS + $SEC_PASS) — skipping"
    continue
  fi

  if [ -z "${SHA:-}" ]; then
    echo "[merge] #$N no head SHA (gh hiccup) — retried next poll"
    continue
  fi
  BODIES="$(gh pr view "$N" --comments --json comments --jq '.comments[].body' 2>/dev/null || true)"
  if ! echo "$BODIES" | grep -qF "$REVIEW_MARKER sha=$SHA"; then
    echo "[merge] #$N review:pass does not cover head $SHA (stale pass) — leaving for review.sh to re-check"
    continue
  fi
  if ! echo "$BODIES" | grep -qF "$DATA_MARKER sha=$SHA"; then
    echo "[merge] #$N data-guard audit does not cover head $SHA — leaving for data-guard.sh to re-audit"
    continue
  fi
  if ! echo "$BODIES" | grep -qF "$SEC_MARKER sha=$SHA"; then
    echo "[merge] #$N sec-guard audit does not cover head $SHA — leaving for security-guard.sh to re-audit"
    continue
  fi

  if [ "$MERGEABLE" = "CONFLICTING" ]; then
    echo "[merge] #$N conflicts with main — needs a human (no auto-rebase)"
    KEY="/tmp/opencode/agent-loop-reported/merge-$N-conflict"
    mkdir -p "$(dirname "$KEY")"
    if [ ! -f "$KEY" ] || [ $(( $(date +%s) - $(stat -c %Y "$KEY") )) -ge 86400 ]; then
      "$DIR/tg.sh" "🧑 PR #$N needs a human: it passed all gates but conflicts with main, and the loop never rebases on its own:
$TITLE
$URL
Branch: $BRANCH
What to do: rebase $BRANCH onto main and push (gates re-run automatically), or merge by hand, or close the PR.
Loop behavior: skipped every poll; this ping repeats at most once/day. Nothing is force-merged." || true
      touch "$KEY"
    else
      echo "[merge] #$N conflict already pinged <24h ago — not repeating"
    fi
    continue
  fi
  if [ "$MERGEABLE" != "MERGEABLE" ]; then
    echo "[merge] #$N mergeable=$MERGEABLE (GitHub still computing or gh hiccup) — retried next poll"
    continue
  fi

  echo "[merge] #$N fully gated at $SHA — merging (--merge)"
  if gh pr merge "$N" --merge >/dev/null 2>&1; then
    echo "[merge] #$N merged (no telegram: the deploy step announces what shipped)"
    rm -f "/tmp/opencode/agent-loop-reported/merge-$N-conflict" 2>/dev/null || true
  else
    echo "[merge] #$N merge failed (gh hiccup or race) — retried next poll"
  fi
done
echo "[merge] done"
