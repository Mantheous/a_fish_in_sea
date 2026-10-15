#!/usr/bin/env bash
# Security guardian step of the agent loop (runs before deploy.sh in poll.sh).
#
# The agent loop can turn a GitHub issue into code running on the
# developer's machine (builder), and the app's feedback tab files GitHub
# issues with the server token — so a trust/allowlist regression is an
# RCE path, not just a bug. This step exists so a change that opens an
# untrusted-user → GitHub → builder path, leaks secrets, or weakens
# auth/SSRF/access-control cannot reach the deployed app, and so every
# agent PR gets an explicit security audit before a human merges it.
#
# Two jobs:
#   1. PR audit — every open agent/* PR gets a security-guardian verdict
#      (comment + sec:safe / sec:blocked label), keyed to the head SHA so
#      new commits trigger a re-audit.
#   2. Preflight — for the revision deploy.sh is about to ship:
#        a. deterministic: pytest test_security + test_feedback (+ auth/sync-guard)
#        b. security-guardian agent audit of the pending diff
#      A block writes build/web/.agent-sec-blocked (deploy.sh refuses to
#      build that revision) and pings Telegram. Override a specific revision
#      with: touch .agent-sec-override (one-shot; empty file).
#
# Read-only w.r.t. git history. Never commits. State under build/web/
# (gitignored) + GitHub labels/comments + Telegram.
set -euo pipefail
REPO="$HOME/Repos/a_fish_in_sea"
cd "$REPO"
DIR="$REPO/tools/agent"

PASS_LABEL="sec:safe"
FAIL_LABEL="sec:blocked"
GUARD_MARKER='<!-- sec-guard -->'
DESC_MARKER="build/web/.agent-sec-desc"
BLOCK_MARKER="build/web/.agent-sec-blocked"
REPORT="build/web/.agent-sec-report.md"
OVERRIDE=".agent-sec-override"

gh label create "$PASS_LABEL" --color "0E8A16" \
  --description "Security guardian: no untrusted-to-RCE path" >/dev/null 2>&1 || true
gh label create "$FAIL_LABEL" --color "B60205" \
  --description "Security guardian: blocks deploy — see audit comment" >/dev/null 2>&1 || true

# ── 1) PR audits ─────────────────────────────────────────────────────────
PRS="$(gh pr list --state open --limit 20 \
  --json number,headRefName,headRefOid \
  --jq '.[] | "\(.number)|\(.headRefName)|\(.headRefOid)"' 2>/dev/null || true)"
echo "$PRS" | while IFS='|' read -r N BRANCH SHA; do
  [ -z "${N:-}" ] && continue
  case "$BRANCH" in agent/*|agent-*) ;; *) continue ;; esac
  # Skip when the latest sec-guard comment already covers this head SHA.
  if gh pr view "$N" --comments --json comments --jq '.comments[].body' 2>/dev/null \
      | grep -qF "$GUARD_MARKER sha=$SHA"; then
    echo "[sec-guard] PR #$N already audited at $SHA — skipping"
    continue
  fi
  echo "[sec-guard] PR #$N ($BRANCH) auditing $SHA..."
  PROMPT="MODE: pr
PR: $N
Audit this pull request for security flaws before a human merges it.
Read-only. Follow your agent instructions exactly."
  OUT_FILE="$(mktemp)"
  if ! opencode run --agent security-guardian --title "sec-guard-pr-$N" \
      "$PROMPT" </dev/null >"$OUT_FILE" 2>"$OUT_FILE.err"; then
    echo "[sec-guard] PR #$N audit run failed: $(tail -n 3 "$OUT_FILE.err")"
    rm -f "$OUT_FILE" "$OUT_FILE.err"
    continue
  fi
  rm -f "$OUT_FILE.err"
  AUDIT="$(cat "$OUT_FILE"; rm -f "$OUT_FILE")"
  VERDICT="$(echo "$AUDIT" | grep -m1 '^Verdict:' || true)"
  # Empty/template-placeholder verdict = failed audit run, never a pass
  # (rate-limited models echo the prompt template back). The guardian
  # template is 'Verdict: safe | block', so any '<' or 'safe | block' text
  # is a template echo, not a real verdict.
  if [ -z "$VERDICT" ] || echo "$VERDICT" | grep -qF '<' || echo "$VERDICT" | grep -qF 'safe | block'; then
    echo "[sec-guard] PR #$N audit produced no usable verdict — retried next poll, nothing labeled"
    "$DIR/tg.sh" "⚠️ Security guardian audit for PR #$N produced no verdict (failed run) — retrying next poll:
$(gh pr view "$N" --json url --jq .url 2>/dev/null || true)" || true
    continue
  fi
  if ! gh pr comment "$N" --body "$AUDIT

$GUARD_MARKER sha=$SHA" >/dev/null; then
    echo "[sec-guard] PR #$N audit comment failed (gh hiccup) — retried next poll"
    "$DIR/tg.sh" "⚠️ Security guardian could not post the audit for PR #$N — retrying next poll:
$(gh pr view "$N" --json url --jq .url 2>/dev/null || true)" || true
    continue
  fi
  "$DIR/label.sh" "$N" remove "$PASS_LABEL" "$FAIL_LABEL" || true
  if echo "$VERDICT" | grep -qi '^Verdict: block'; then
    "$DIR/label.sh" "$N" add "$FAIL_LABEL" || true
    echo "[sec-guard] PR #$N BLOCKED — $VERDICT"
    "$DIR/tg.sh" "🛑 Security guardian blocked PR #$N: $VERDICT
$(gh pr view "$N" --json url --jq .url)
Audit comment on the PR." || true
  elif echo "$VERDICT" | grep -qi '^Verdict: safe'; then
    "$DIR/label.sh" "$N" add "$PASS_LABEL" || true
    echo "[sec-guard] PR #$N safe — $VERDICT"
  else
    echo "[sec-guard] PR #$N unrecognized verdict ($VERDICT) — leaving unlabeled, retried next poll"
    "$DIR/tg.sh" "⚠️ Security guardian audit for PR #$N had an unrecognized verdict — retrying next poll:
$(gh pr view "$N" --json url --jq .url 2>/dev/null || true)" || true
  fi
done

# ── 2) Preflight for the revision deploy.sh will build ──────────────────
# NOTE: deploy.sh fast-forwards main to origin/main before building, so the
# revision it ships is origin/main — NOT necessarily local HEAD (see
# data-guard.sh for the full explanation). DESC is keyed on origin/main.
git fetch origin --quiet 2>&1 | head -n 5 || true
if [ -n "$(git status --porcelain | head -n 20)" ]; then
  WT_HASH="$(git status --porcelain | sha256sum | cut -c1-16)"
  DESC="worktree-$(git rev-parse HEAD)-$WT_HASH"
  AUDIT_RANGE_DESC="uncommitted work (git diff HEAD) plus incoming commits $(git rev-parse HEAD)..$(git rev-parse origin/main 2>/dev/null || echo origin/main)"
else
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$BRANCH" != "main" ]; then
    echo "[sec-guard] clean tree on $BRANCH — deploy would skip; nothing to audit"
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
  echo "[sec-guard] override present for $DESC — skipping audit"
  exit 0
fi
if [ -f "$DESC_MARKER" ] && [ "$(cat "$DESC_MARKER")" = "$DESC" ]; then
  echo "[sec-guard] $DESC already audited — skipping"
  exit 0
fi

echo "[sec-guard] preflight for $DESC"
# Server deps (incl. pytest) live in server/api/.venv per server/api/README.md;
# system python3 has no pytest, so prefer the venv and fail with a clear
# infra message instead of a misleading security block.
PYTEST_PY="$REPO/server/api/.venv/bin/python"
[ -x "$PYTEST_PY" ] || PYTEST_PY="python3"
if ! "$PYTEST_PY" -m pytest server/api/tests/test_security.py server/api/tests/test_feedback.py server/api/tests/test_feedback_security.py server/api/tests/test_auth_sync.py server/api/tests/test_auth_refresh.py server/api/tests/test_sync_guard.py >/tmp/opencode/sec-guard-tests.log 2>&1; then
  {
    echo "# Security guard preflight — deterministic tests FAILED"
    echo "Revision: $DESC"
    echo
    tail -n 40 /tmp/opencode/sec-guard-tests.log
  } > "$REPORT"
  echo "$DESC" > "$BLOCK_MARKER"
  "$DIR/tg.sh" "🛑 Deploy held back: security tests failed on $DESC
$(tail -n 5 /tmp/opencode/sec-guard-tests.log)
Report: $REPORT" || true
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
if ! opencode run --agent security-guardian --title "sec-guard-$DESC" \
    "$PROMPT" >/tmp/opencode/sec-guard-audit.log 2>&1; then
  echo "[sec-guard] audit run failed (next poll retries); not blocking"
  exit 0
fi
cp /tmp/opencode/sec-guard-audit.log "$REPORT"
VERDICT="$(grep -m1 '^Verdict:' "$REPORT" || true)"
# No usable verdict = failed audit run (template echo). Not safe, not
# blocked: re-audited next poll. The template is 'Verdict: safe | block'.
if [ -z "$VERDICT" ] || echo "$VERDICT" | grep -qF '<' || echo "$VERDICT" | grep -qF 'safe | block'; then
  echo "[sec-guard] preflight audit for $DESC produced no usable verdict — not marking safe; retried next poll"
  "$DIR/tg.sh" "⚠️ Security guardian preflight for $DESC produced no verdict (failed run) — not marking safe; retrying next poll" || true
  exit 0
fi
if echo "$VERDICT" | grep -qi '^Verdict: block'; then
  echo "$DESC" > "$BLOCK_MARKER"
  echo "[sec-guard] BLOCKED $DESC — $VERDICT"
  "$DIR/tg.sh" "🛑 Security guardian blocked the next web deploy ($DESC): $VERDICT
Report: $REPORT
Override: touch .agent-sec-override, or fix the findings." || true
elif echo "$VERDICT" | grep -qi '^Verdict: safe'; then
  rm -f "$BLOCK_MARKER"
  echo "$DESC" > "$DESC_MARKER"
  echo "[sec-guard] safe $DESC — $VERDICT"
else
  echo "[sec-guard] preflight audit for $DESC had an unrecognized verdict — not marking safe; retried next poll"
  "$DIR/tg.sh" "⚠️ Security guardian preflight for $DESC had an unrecognized verdict — not marking safe; retrying next poll" || true
fi
echo "[sec-guard] done"
