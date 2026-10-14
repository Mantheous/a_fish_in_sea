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
#        a. deterministic: flutter test test/persistence test/sync
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
  --json number,headRefName,headRefOid \
  --jq '.[] | "\(.number)|\(.headRefName)|\(.headRefOid)"' 2>/dev/null || true)"
echo "$PRS" | while IFS='|' read -r N BRANCH SHA; do
  [ -z "${N:-}" ] && continue
  case "$BRANCH" in agent/*) ;; *) continue ;; esac
  # Skip when the latest data-guard comment already covers this head SHA.
  if gh pr view "$N" --comments --json comments --jq '.comments[].body' 2>/dev/null \
      | grep -qF "$GUARD_MARKER sha=$SHA"; then
    echo "[data-guard] PR #$N already audited at $SHA — skipping"
    continue
  fi
  echo "[data-guard] PR #$N ($BRANCH) auditing $SHA..."
  PROMPT="MODE: pr
PR: $N
Audit this pull request for risks to the user's existing data before a human
merges it. Read-only. Follow your agent instructions exactly."
  OUT_FILE="$(mktemp)"
  if ! opencode run --agent data-guardian --title "data-guard-pr-$N" \
      "$PROMPT" </dev/null >"$OUT_FILE" 2>"$OUT_FILE.err"; then
    echo "[data-guard] PR #$N audit run failed: $(tail -n 3 "$OUT_FILE.err")"
    rm -f "$OUT_FILE" "$OUT_FILE.err"
    continue
  fi
  rm -f "$OUT_FILE.err"
  AUDIT="$(cat "$OUT_FILE"; rm -f "$OUT_FILE")"
  VERDICT="$(echo "$AUDIT" | grep -m1 '^Verdict:' || true)"
  # An empty verdict, or one that is the prompt's own template placeholder,
  # means the audit run produced nothing usable (a rate-limited model echoes
  # the template back). That is a FAILED audit, never a pass — observed for
  # real on 2026-10-13 when a placeholder verdict marked a revision "safe".
  if [ -z "$VERDICT" ] || echo "$VERDICT" | grep -qF '<pass | changes-requested>'; then
    echo "[data-guard] PR #$N audit produced no usable verdict — retried next poll, nothing labeled"
    "$DIR/tg.sh" "⚠️ Data guardian audit for PR #$N produced no verdict (failed run) — retrying next poll:
$(gh pr view "$N" --json url --jq .url 2>/dev/null || true)" || true
    continue
  fi
  if ! gh pr comment "$N" --body "$AUDIT

$GUARD_MARKER sha=$SHA" >/dev/null; then
    echo "[data-guard] PR #$N audit comment failed (gh hiccup) — retried next poll"
    "$DIR/tg.sh" "⚠️ Data guardian could not post the audit for PR #$N — retrying next poll:
$(gh pr view "$N" --json url --jq .url 2>/dev/null || true)" || true
    continue
  fi
  "$DIR/label.sh" "$N" remove "$PASS_LABEL" "$FAIL_LABEL" || true
  if echo "$VERDICT" | grep -qi '^Verdict: block'; then
    "$DIR/label.sh" "$N" add "$FAIL_LABEL" || true
    echo "[data-guard] PR #$N BLOCKED — $VERDICT"
    "$DIR/tg.sh" "🛑 Data guardian blocked PR #$N: $VERDICT
$(gh pr view "$N" --json url --jq .url)
Audit comment on the PR." || true
  else
    "$DIR/label.sh" "$N" add "$PASS_LABEL" || true
    echo "[data-guard] PR #$N safe — $VERDICT"
  fi
done

# ── 2) Preflight for the revision deploy.sh will build ──────────────────
git fetch origin --quiet 2>&1 | head -n 5 || true
if [ -n "$(git status --porcelain | head -n 20)" ]; then
  WT_HASH="$(git status --porcelain | sha256sum | cut -c1-16)"
  DESC="worktree-$(git rev-parse HEAD)-$WT_HASH"
else
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$BRANCH" != "main" ]; then
    echo "[data-guard] clean tree on $BRANCH — deploy would skip; nothing to audit"
    exit 0
  fi
  DESC="main-$(git rev-parse HEAD)"
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
if ! "$FLUTTER" test test/persistence test/sync >/tmp/opencode/data-guard-tests.log 2>&1; then
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

PROMPT="MODE: preflight
DESC: $DESC
Audit the pending changes (uncommitted work in the worktree plus anything on
this branch beyond origin/main) for risks to the user's existing data. This
is the revision the next web deploy ships. Read-only. Follow your agent
instructions exactly."
if ! opencode run --agent data-guardian --title "data-guard-$DESC" \
    "$PROMPT" >/tmp/opencode/data-guard-audit.log 2>&1; then
  echo "[data-guard] audit run failed (next poll retries); not blocking"
  exit 0
fi
cp /tmp/opencode/data-guard-audit.log "$REPORT"
VERDICT="$(grep -m1 '^Verdict:' "$REPORT" || true)"
# No usable verdict = failed audit (rate-limited run echoing the template).
# Do not write the safe marker: the next poll re-audits. Do not block the
# deploy either — a transient model failure must not hold shipping hostage.
if [ -z "$VERDICT" ] || echo "$VERDICT" | grep -qF '<pass | changes-requested>'; then
  echo "[data-guard] preflight audit for $DESC produced no usable verdict — not marking safe; retried next poll"
  "$DIR/tg.sh" "⚠️ Data guardian preflight for $DESC produced no verdict (failed run) — not marking safe; retrying next poll" || true
  exit 0
fi
if echo "$VERDICT" | grep -qi '^Verdict: block'; then
  echo "$DESC" > "$BLOCK_MARKER"
  echo "[data-guard] BLOCKED $DESC — $VERDICT"
  "$DIR/tg.sh" "🛑 Data guardian blocked the next web deploy ($DESC): $VERDICT
Report: $REPORT
Override: touch .agent-data-override, or fix the findings." || true
else
  rm -f "$BLOCK_MARKER"
  echo "$DESC" > "$DESC_MARKER"
  echo "[data-guard] safe $DESC — $VERDICT"
fi
echo "[data-guard] done"
