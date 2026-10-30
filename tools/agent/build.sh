#!/usr/bin/env bash
# Builder dispatcher: for each open agent-approved issue without a branch/PR,
# launch a detached tmux session running builder-run.sh. Safe to re-run.
#
# Rate-limit hardening (2026-10-13, revised 2026-10-15): the loop's opencode
# model quota cannot feed a dozen concurrent builder + reviewer runs. Nine
# builders launched in one poll all died on "Rate limit exceeded" BEFORE
# reaching the commit / push / PR gates, so approved issues sat for days
# with no PR anywhere and the debris pings made it look like a human had
# to open the PRs himself. The dispatcher now:
#   1. serializes builders (at most one agent-<N> session at a time),
#   2. backs off an issue whose last run ended without a PR: the stamp at
#      /tmp/opencode/agent-loop-cd/<N> holds a retry-after ("not before")
#      epoch written by builder-run.sh (~1h + jitter, rolled once at
#      failure time; override the base with AGENT_BUILDER_COOLDOWN_S).
#      Backing off (instead of relaunching every 15 min) is also what stops
#      one poisoned issue from head-of-line blocking the whole queue — the
#      loop moves on to the next issue in the same poll. Legacy stamps
#      holding plain failure epochs (pre-2026-10-15 scheme) read as past
#      times and simply mean "eligible now", and
#   3. if a builder PUSHED its branch but died before `gh pr create`,
#      opens the PR itself instead of stranding the branch.
set -euo pipefail
REPO="$HOME/Repos/a_fish_in_sea"
cd "$REPO"
DIR="$REPO/tools/agent"
CD_DIR="/tmp/opencode/agent-loop-cd"
mkdir -p "$CD_DIR"

BUILDER_SLOTS="${AGENT_BUILDER_SLOTS:-1}"
[[ "$BUILDER_SLOTS" =~ ^[1-9][0-9]*$ ]] \
  || { echo "[build] AGENT_BUILDER_SLOTS must be a positive integer (got '$BUILDER_SLOTS')" >&2; exit 2; }
BUILDER_BACKEND="${FISH_LLM_BUILDER_BACKEND:-opencode}"
REWORK_BACKEND="${FISH_LLM_REWORK_BACKEND:-opencode}"

builder_count() {
  # Loop-owned builder sessions only. Ad-hoc names (agent-adhoc-*) and
  # review-spawned reworks (rework-*) do not consume a builder slot.
  tmux ls -F '#{session_name}' 2>/dev/null | grep -cE '^agent-[0-9]+$' || true
}

rework_count() {
  tmux ls -F '#{session_name}' 2>/dev/null | grep -cE '^rework-[0-9]+$' || true
}

if [ "$(builder_count)" -ge "$BUILDER_SLOTS" ]; then
  echo "[build] $(builder_count)/$BUILDER_SLOTS builder slot(s) in use — next issue launches on a later poll"
  exit 0
fi
# Preserve the old single-opencode-run safety: when both builders and rework
# use opencode, a rework and a builder must not stack on that quota.
if [ "$BUILDER_BACKEND" = "opencode" ] && [ "$REWORK_BACKEND" = "opencode" ] \
  && [ "$(rework_count)" -gt 0 ]; then
  echo "[build] rework session active on opencode — serializing (no builder launch this poll)"
  exit 0
fi

COUNT="$(gh issue list --label agent-approved --state open --limit 20 --json number 2>/dev/null \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' || echo 0)"
echo "[build] agent-approved open: $COUNT (slots: $(builder_count)/$BUILDER_SLOTS, backend: $BUILDER_BACKEND)"
[ "$COUNT" = "0" ] && exit 0

gh issue list --label agent-approved --state open --limit 20 --json number,title 2>/dev/null \
  | python3 -c 'import json,sys; [print(i["number"]) for i in json.load(sys.stdin)]' \
  | while read -r N; do
  if tmux has-session -t "agent-$N" 2>/dev/null; then
    echo "[build] #$N tmux session agent-$N already running — skipping"
    continue
  fi
  if [ "$(builder_count)" -ge "$BUILDER_SLOTS" ]; then
    echo "[build] $BUILDER_SLOTS builder slot(s) filled — remaining issues launch on a later poll"
    break
  fi

  # Backoff: a builder run that ended without a PR (model rate limit at the
  # finish line, instant-exit worktree conflict, ...) waits until the
  # retry-after epoch builder-run.sh wrote — ~1h + jitter. While backed
  # off, the loop moves on to the next issue (continue, not break).
  CD="$CD_DIR/$N"
  if [ -f "$CD" ]; then
    NOTBEFORE="$(tr -cd '0-9' <"$CD" 2>/dev/null)"
    NOW="$(date +%s)"
    if [ -n "${NOTBEFORE:-}" ] && [ "$NOTBEFORE" -gt "$NOW" ]; then
      echo "[build] #$N backing off $(((NOTBEFORE - NOW) / 60))m (retry after $(date -d "@$NOTBEFORE" '+%H:%M'))"
      continue
    fi
  fi

  TITLE="$(gh issue view "$N" --json title --jq .title 2>/dev/null || echo "issue $N")"
  URL="$(gh issue view "$N" --json url --jq .url 2>/dev/null || true)"
  SLUG="$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\+/-/g' | cut -c1-40 | sed 's/-$//')"
  BRANCH="agent/$N-$SLUG"
  WT="$HOME/Repos/worktrees/agent-$N-$SLUG"
  if git ls-remote --heads origin "$BRANCH" | grep -q .; then
    EXISTING_PR="$(gh pr list --head "$BRANCH" --state all --limit 1 \
      --json state,url --jq '.[] | "\(.state) \(.url)"' 2>/dev/null | head -n 1 || true)"
    if [ -n "${EXISTING_PR:-}" ]; then
      echo "[build] #$N branch already pushed — PR on record ($EXISTING_PR) — skipping"
      continue
    fi
    if [ -z "$(git log --oneline "origin/main..origin/$BRANCH" 2>/dev/null | head -n 1)" ]; then
      # Empty remote branch (no commits past origin/main): it deadlocks the
      # loop if kept — close.sh leaves it, build.sh skips it, builder-run.sh
      # exits on it. It is byte-identical to main, so delete it and fall
      # through to launch a fresh builder below.
      echo "[build] #$N branch pushed but EMPTY — deleting it and launching a fresh builder"
      if git push origin --delete "$BRANCH" --quiet 2>/dev/null; then
        echo "[build] #$N deleted empty remote branch $BRANCH"
      else
        echo "[build] #$N could not delete empty remote branch $BRANCH — skipping this poll"
        continue
      fi
    else
      # The builder pushed its branch but died before `gh pr create` (its
      # opencode run hit the model rate limit at the finish line). Don't
      # strand the work on a branch waiting for a human — open the PR from
      # here so the reviewer gates it like any other.
      echo "[build] #$N branch pushed but NO PR — opening it from the dispatcher"
      LOGLINE=""
      [ -f "$WT/.agent-build.log" ] && LOGLINE="
Builder run log (loop host): \`$WT/.agent-build.log\` — read it to verify the gates before relying on the diff."
      BODY="Closes #$N. Scope: $TITLE — per the latest <!-- agent-plan --> triage comment on the issue.

This PR was opened by the loop dispatcher: the builder pushed its branch but its run ended before it created the PR itself (model rate limit at the finish line). The reviewer agent re-checks the diff against the plan and gates before any merge; treat anything unverified in the diff as review:changes-requested material, reworkable from \`$WT\`.$LOGLINE"
      if PR_URL="$(gh pr create --base main --head "$BRANCH" \
          --title "[agent #$N] $TITLE" --body "$BODY" 2>&1)"; then
        echo "[build] #$N opened $PR_URL (no telegram: notify-quiet)"
        rm -f "/tmp/opencode/agent-loop-reported/dispatcher-$N-no-pr" 2>/dev/null || true
      else
        echo "[build] #$N dispatcher could not open the PR: $PR_URL — needs a human"
        # A persistent `gh pr create` failure would otherwise re-ping every
        # 15-min poll — throttle to once/day like the other escalations.
        DKEY="/tmp/opencode/agent-loop-reported/dispatcher-$N-no-pr"
        mkdir -p "$(dirname "$DKEY")"
        if [ ! -f "$DKEY" ] || [ $(( $(date +%s) - $(stat -c %Y "$DKEY") )) -ge 86400 ]; then
          COMMITS="$(git log --oneline "origin/main..origin/$BRANCH" 2>/dev/null | head -n 5 || true)"
          [ -n "${COMMITS:-}" ] || COMMITS="(could not list — see the loop host)"
          "$DIR/tg.sh" "🧑 Dispatcher for #$N needs a human to open the PR (auto-PR failed):
Issue: $TITLE
$URL
Branch: $BRANCH (pushed, no PR on record)
Commits past origin/main:
$COMMITS
gh pr create failed with:
$PR_URL
What to do: open the PR by hand, or drop the branch if the work is unwanted:
  gh pr create --base main --head \"$BRANCH\" --title \"[agent #$N] $TITLE\" --body \"Closes #$N. ...\"
  # or: git push origin --delete \"$BRANCH\"
Loop behavior: retries the auto-PR each poll; this ping repeats at most once/day. Nothing is merged automatically." || true
          touch "$DKEY"
        else
          echo "[build] #$N dispatcher PR failure already pinged <24h ago — not repeating"
        fi
      fi
      continue
    fi
  fi
  echo "[build] #$N launching tmux session agent-$N (slot $(( $(builder_count) + 1 ))/$BUILDER_SLOTS)"
  tmux new-session -d -s "agent-$N" "$DIR/builder-run.sh $N"
  # Launch verification: a builder that dies seconds after launch leaves
  # no log and (for some early exits) no retry stamp, so the dispatcher
  # relaunches it every poll into the same wall. If the session is already
  # gone, back the issue off loudly and move on to the next issue in this
  # poll. A healthy builder runs for many minutes, so 10s is safe.
  sleep 10
  if ! tmux has-session -t "agent-$N" 2>/dev/null; then
    echo "[build] #$N session agent-$N died within 10s of launch — backing off (retry in ~1h) and trying the next issue"
    date +%s -d "@$(( $(date +%s) + 3600 ))" >"$CD_DIR/$N"
    continue
  fi
  # Keep filling slots. The guard at the top of the next iteration stops
  # when BUILDER_SLOTS is reached; with the default 1 this is the old
  # one-builder-per-poll behavior.
done || true
echo "[build] done"
