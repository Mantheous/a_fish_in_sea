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

builder_running() {
  # Loop-owned opencode run sessions: builders (agent-<N>) and reworks
  # (rework-<N>). The user's own interactive sessions never match.
  [ "$(tmux ls -F '#{session_name}' 2>/dev/null | grep -cE '^(agent-[0-9]|rework-[0-9])' || true)" != "0" ]
}

COUNT="$(gh issue list --label agent-approved --state open --limit 20 --json number 2>/dev/null \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' || echo 0)"
echo "[build] agent-approved open: $COUNT"
[ "$COUNT" = "0" ] && exit 0

if builder_running; then
  echo "[build] a builder session is already running — serializing (one opencode run at a time; the next issue launches on a later poll)"
  exit 0
fi

gh issue list --label agent-approved --state open --limit 20 --json number,title 2>/dev/null \
  | python3 -c 'import json,sys; [print(i["number"]) for i in json.load(sys.stdin)]' \
  | while read -r N; do
  if tmux has-session -t "agent-$N" 2>/dev/null; then
    echo "[build] #$N tmux session agent-$N already running — skipping"
    continue
  fi
  if builder_running; then
    echo "[build] builder session for an earlier issue started this poll — serializing, #$N launches on a later poll"
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
      echo "[build] #$N branch pushed but EMPTY — the builder reuses it"
      continue
    fi
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
      echo "[build] #$N opened $PR_URL"
      "$DIR/tg.sh" "🔗 Dispatcher opened the PR for #$N (builder run ended before creating it): $TITLE
$PR_URL" || true
    else
      echo "[build] #$N dispatcher could not open the PR: $PR_URL — needs a human"
      "$DIR/tg.sh" "🧑 Branch for #$N has work but the dispatcher could not open its PR — needs a human:
$URL" || true
    fi
    continue
  fi
  echo "[build] #$N launching tmux session agent-$N"
  tmux new-session -d -s "agent-$N" "$DIR/builder-run.sh $N"
  # One builder per poll: the loop's model quota is serialized. The next
  # approved issue launches on the next poll (builder_running guard above).
  break
done || true
echo "[build] done"
