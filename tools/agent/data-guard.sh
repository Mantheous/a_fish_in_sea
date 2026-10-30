#!/usr/bin/env bash
# Data guardian step of the agent loop (runs before deploy.sh in poll.sh).
#
# The developer uses their real data in this app while it is being changed.
# This step exists so a change that would break or lose that data cannot
# reach the deployed app, and so every agent PR gets an explicit
# persistence/migration audit before a human merges it.
#
# Two jobs:
#   1. PR audit — every open agent/* PR gets a data-guardian verdict
#      (comment + data:safe / data:blocked label), keyed to the head SHA so
#      new commits trigger a re-audit.
#   2. Preflight — for the revision deploy.sh is about to ship:
#        a. deterministic: flutter test test/persistence test/sync test/usage
#        b. data-guardian agent audit of the pending diff
#      A block writes build/web/.agent-data-blocked (deploy.sh refuses to
#      build that revision) and pings Telegram. Override a specific revision
#      with: touch .agent-data-override (one-shot; empty file).
#
# Read-only w.r.t. git history. Never commits. State under build/web/
# (gitignored) + GitHub labels/comments + Telegram.
set -euo pipefail
REPO="$HOME/Repos/a_fish_in_sea"
cd "$REPO"
DIR="$REPO/tools/agent"
FLUTTER="$HOME/flutter/bin/flutter"

# Serialized model quota: never stack a guardian LLM run on top of a live
# builder/rework session (same guard build.sh/review.sh already use).
loop_runs() {
  tmux ls -F '#{session_name}' 2>/dev/null | grep -cE '^(agent-[0-9]|rework-[0-9])' || true
}

# Returns 0 when the audit range touches the data/persistence surface the
# data-guardian exists to protect: models, cubits, sync, persistence, or
# server models. Changed files = uncommitted work vs HEAD plus incoming
# origin/main commits (what the next deploy ships).
touches_data_surface() {
  local changed
  changed="$(git diff --name-only HEAD 2>/dev/null)"
  if git rev-parse --verify origin/main >/dev/null 2>&1; then
    changed="$(printf '%s\n%s' "$changed" "$(git diff --name-only HEAD origin/main 2>/dev/null)")"
  fi
  printf '%s\n' "$changed" \
    | grep -qE '(^|/)model/|_cubit\.dart$|(^|/)sync/|(^|/)common/persistence/|server/api/app/models\.py|server/api/schemas\.py|^server/api/data/'
}

PASS_LABEL="data:safe"
FAIL_LABEL="data:blocked"
GUARD_MARKER='<!-- data-guard -->'
DESC_MARKER="build/web/.agent-data-desc"
BLOCK_MARKER="build/web/.agent-data-blocked"
REPORT="build/web/.agent-data-report.md"
OVERRIDE=".agent-data-override"

gh label create "$PASS_LABEL" --color "0E8A16" \
  --description "Data guardian: no persistence risk for existing data" >/dev/null 2>&1 || true
gh label create "$FAIL_LABEL" --color "B60205" \
  --description "Data guardian: may break existing data — see audit comment" >/dev/null 2>&1 || true

# ── 1) PR audits ─────────────────────────────────────────────────────────
PRS="$(gh pr list --state open --limit 20 \
  --json number,headRefName,headRefOid,url \
  --jq '.[] | "\(.number)|\(.headRefName)|\(.headRefOid)|\(.url // "")"' 2>/dev/null || true)"
echo "$PRS" | while IFS='|' read -r N BRANCH SHA URL; do
  [ -z "${N:-}" ] && continue
  case "$BRANCH" in agent/*|agent-*) ;; *) continue ;; esac
  # Skip when the latest data-guard comment already covers this head SHA.
  if gh pr view "$N" --comments --json comments --jq '.comments[].body' 2>/dev/null \
      | grep -qF "$GUARD_MARKER sha=$SHA"; then
    echo "[data-guard] PR #$N already audited at $SHA — skipping"
    continue
  fi
  # Don't stack a guardian LLM run on top of a live builder/rework session.
  RUNNING="$(loop_runs)"
  if [ "${RUNNING:-0}" -ge 1 ]; then
    echo "[data-guard] $RUNNING loop run(s) active — skipping PR #$N audit this poll"
    continue
  fi
  echo "[data-guard] PR #$N ($BRANCH) auditing $SHA..."
  PROMPT="MODE: pr
PR: $N
Audit this pull request for risks to the user's existing data before a human
merges it. Read-only. Follow your agent instructions exactly."
  OUT_FILE="$(mktemp)"
  if ! printf '%s' "$PROMPT" | "$DIR/llm-run.sh" --role data-guard --title "data-guard-pr-$N" --read-only \
      --expect '^Verdict:' >"$OUT_FILE" 2>"$OUT_FILE.err"; then
    echo "[data-guard] PR #$N audit run failed: $(tail -n 3 "$OUT_FILE.err")"
    rm -f "$OUT_FILE" "$OUT_FILE.err"
    continue
  fi
  rm -f "$OUT_FILE.err"
  AUDIT="$(cat "$OUT_FILE"; rm -f "$OUT_FILE")"
  VERDICT="$(echo "$AUDIT" | grep -m1 '^Verdict:' || true)"
  # An empty verdict, a template placeholder, or anything that is not an
  # explicit safe/block verdict means the audit run produced nothing usable
  # (a rate-limited model echoes the template back). That is a FAILED audit,
  # never a pass — observed for real on 2026-10-13 when a placeholder
  # verdict marked a revision "safe". The guardian template is
  # 'Verdict: safe | block', so any '<' or 'safe | block' text is a template
  # echo, not a real verdict.
  if [ -z "$VERDICT" ] || echo "$VERDICT" | grep -qF '<' || echo "$VERDICT" | grep -qF 'safe | block'; then
    echo "[data-guard] PR #$N audit produced no usable verdict — retried next poll, nothing labeled (no telegram: notify-quiet)"
    continue
  fi
  if ! gh pr comment "$N" --body "$AUDIT

$GUARD_MARKER sha=$SHA" >/dev/null; then
    echo "[data-guard] PR #$N audit comment failed (gh hiccup) — retried next poll (no telegram: notify-quiet)"
    continue
  fi
  "$DIR/label.sh" "$N" remove "$PASS_LABEL" "$FAIL_LABEL" || true
  if echo "$VERDICT" | grep -qi '^Verdict: block'; then
    "$DIR/label.sh" "$N" add "$FAIL_LABEL" || true
    echo "[data-guard] PR #$N BLOCKED — $VERDICT"
    "$DIR/tg.sh" "🛑 Data guardian blocked PR #$N: $VERDICT
$URL
Audit comment on the PR." || true
  elif echo "$VERDICT" | grep -qi '^Verdict: safe'; then
    "$DIR/label.sh" "$N" add "$PASS_LABEL" || true
    echo "[data-guard] PR #$N safe — $VERDICT"
  else
    echo "[data-guard] PR #$N unrecognized verdict ($VERDICT) — leaving unlabeled, retried next poll (no telegram: notify-quiet)"
  fi
done

# ── 2) Preflight for the revision deploy.sh will build ──────────────────
# NOTE: deploy.sh fast-forwards main to origin/main before building, so the
# revision it ships is origin/main — NOT necessarily local HEAD. Auditing
# local HEAD here used to silently skip newly merged commits (DESC matched
# the old marker, guardian saw an empty origin/main..HEAD diff, deploy then
# shipped the unaudited tip). DESC is therefore keyed on origin/main, and
# the guardian audits HEAD..origin/main (the incoming commits deploy will
# pick up) plus any uncommitted work.
git fetch origin --quiet 2>&1 | head -n 5 || true
if [ -n "$(git status --porcelain | head -n 20)" ]; then
  WT_HASH="$(git status --porcelain | sha256sum | cut -c1-16)"
  DESC="worktree-$(git rev-parse HEAD)-$WT_HASH"
  AUDIT_RANGE_DESC="uncommitted work (git diff HEAD) plus incoming commits $(git rev-parse HEAD)..$(git rev-parse origin/main 2>/dev/null || echo origin/main)"
else
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$BRANCH" != "main" ]; then
    echo "[data-guard] clean tree on $BRANCH — deploy would skip; nothing to audit"
    exit 0
  fi
  TARGET_SHA="$(git rev-parse origin/main 2>/dev/null || git rev-parse HEAD)"
  HEAD_SHA="$(git rev-parse HEAD)"
  DESC="main-$TARGET_SHA"
  if [ "$HEAD_SHA" = "$TARGET_SHA" ]; then
    AUDIT_RANGE_DESC="HEAD ($HEAD_SHA, already at origin/main tip)"
  else
    AUDIT_RANGE_DESC="incoming commits $HEAD_SHA..$TARGET_SHA (git log $HEAD_SHA..$TARGET_SHA plus git diff $HEAD_SHA...$TARGET_SHA)"
  fi
fi

if [ -f "$OVERRIDE" ] && { [ ! -s "$OVERRIDE" ] || [ "$(cat "$OVERRIDE")" = "$DESC" ]; }; then
  echo "[data-guard] override present for $DESC — skipping audit"
  exit 0
fi
if [ -f "$DESC_MARKER" ] && [ "$(cat "$DESC_MARKER")" = "$DESC" ]; then
  echo "[data-guard] $DESC already audited — skipping"
  exit 0
fi

echo "[data-guard] preflight for $DESC"
if ! "$FLUTTER" test test/persistence test/sync test/usage >/tmp/opencode/data-guard-tests.log 2>&1; then
  {
    echo "# Data guard preflight — deterministic tests FAILED"
    echo "Revision: $DESC"
    echo
    tail -n 40 /tmp/opencode/data-guard-tests.log
  } > "$REPORT"
  echo "$DESC" > "$BLOCK_MARKER"
  "$DIR/tg.sh" "🛑 Deploy held back: persistence/sync tests failed on $DESC
$(tail -n 5 /tmp/opencode/data-guard-tests.log)
Report: $REPORT" || true
  exit 0
fi

# Path filter: deterministic tests passed. If nothing in the data surface
# (model / cubit / sync / persistence / server-model files) changed, there
# is nothing for the data-guardian LLM to audit — skip it and mark the
# revision safe so deploy can proceed.
if ! touches_data_surface; then
  rm -f "$BLOCK_MARKER"
  echo "$DESC" > "$DESC_MARKER"
  echo "[data-guard] $DESC touches no model/cubit/sync/persistence/server-model files — deterministic tests passed, guardian LLM skipped"
  exit 0
fi
# Don't stack a guardian LLM run on top of a live builder/rework session.
RUNNING="$(loop_runs)"
if [ "${RUNNING:-0}" -ge 1 ]; then
  echo "[data-guard] $RUNNING loop run(s) active — skipping guardian LLM audit this poll"
  exit 0
fi

PROMPT="MODE: preflight
DESC: $DESC
RANGE: $AUDIT_RANGE_DESC
Audit the changes the next web deploy ships: $AUDIT_RANGE_DESC. On a clean
main this is the incoming origin/main commits deploy.sh is about to
fast-forward to (NOT an empty origin/main..HEAD — that range is backwards).
Uncommitted work in the worktree (git diff HEAD) ships too when present.
Read-only. Follow your agent instructions exactly."
AUDIT_LOG=/tmp/opencode/data-guard-audit.log
if ! printf '%s' "$PROMPT" | "$DIR/llm-run.sh" --role data-guard --title "data-guard-$DESC" --read-only \
    --expect '^Verdict:' >"$AUDIT_LOG" 2>"$AUDIT_LOG.err"; then
  echo "[data-guard] audit run failed (next poll retries); not blocking: $(tail -n 3 "$AUDIT_LOG.err" 2>/dev/null || true)"
  exit 0
fi
cp "$AUDIT_LOG" "$REPORT"
VERDICT="$(grep -m1 '^Verdict:' "$REPORT" || true)"
# No usable verdict = failed audit run (template echo). Not safe, not
# blocked: re-audited next poll. The template is 'Verdict: safe | block', so
# any '<' or 'safe | block' text is a template echo.
if [ -z "$VERDICT" ] || echo "$VERDICT" | grep -qF '<' || echo "$VERDICT" | grep -qF 'safe | block'; then
  echo "[data-guard] preflight audit for $DESC produced no usable verdict — not marking safe; retried next poll (no telegram: notify-quiet)"
  exit 0
fi
if echo "$VERDICT" | grep -qi '^Verdict: block'; then
  echo "$DESC" > "$BLOCK_MARKER"
  echo "[data-guard] BLOCKED $DESC — $VERDICT"
  "$DIR/tg.sh" "🛑 Data guardian blocked the next web deploy ($DESC): $VERDICT
Report: $REPORT
Override: touch .agent-data-override, or fix the findings." || true
elif echo "$VERDICT" | grep -qi '^Verdict: safe'; then
  rm -f "$BLOCK_MARKER"
  echo "$DESC" > "$DESC_MARKER"
  echo "[data-guard] safe $DESC — $VERDICT"
else
  echo "[data-guard] preflight audit for $DESC had an unrecognized verdict — not marking safe; retried next poll (no telegram: notify-quiet)"
fi
echo "[data-guard] done"
