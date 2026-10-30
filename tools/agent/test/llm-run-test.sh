#!/usr/bin/env bash
# Tests for tools/agent/llm-run.sh. Pure bash, no network, no model calls:
# fake `codex` / `opencode` binaries on PATH record argv + stdin and emit a
# canned final message. Run from anywhere:
#
#   tools/agent/test/llm-run-test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER="$HERE/../llm-run.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"

# These tests use fake codex/opencode binaries, so skip the real bwrap probe.
# The probe itself is exercised by test 10 with a deliberately broken bwrap.
export FISH_LLM_CODEX_SANDBOX_CHECK=0

cat >"$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"${FAKE_CODEX_ARGS:-/dev/null}"
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output-last-message) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat >"${FAKE_CODEX_STDIN:-/dev/null}"
[ "${FAKE_CODEX_MUTATE:-0}" = "1" ] && echo mutated >./llm-run-mutated.txt
[ "${FAKE_CODEX_SLEEP:-0}" != "0" ] && sleep "$FAKE_CODEX_SLEEP"
if [ "${FAKE_CODEX_EXIT:-0}" != "0" ]; then
  echo "fake codex failed" >&2
  exit "$FAKE_CODEX_EXIT"
fi
printf '%s' "${FAKE_CODEX_MESSAGE:-}" >"$out"
printf '%s' "${FAKE_CODEX_MESSAGE:-}"
FAKE

cat >"$BIN/opencode" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"${FAKE_OPENCODE_ARGS:-/dev/null}"
printf '%s' "${FAKE_OPENCODE_MESSAGE:-}"
FAKE
chmod +x "$BIN/codex" "$BIN/opencode"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
no() { FAIL=$((FAIL + 1)); echo "not ok - $1"; printf '  %s\n' "${2:-}"; }

assert_eq() { # expected actual name
  if [ "$1" = "$2" ]; then ok "$3"; else no "$3" "expected [$1] got [$2]"; fi
}
assert_contains() { # haystack needle name
  if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else no "$3" "missing [$2] in [$1]"; fi
}
assert_not_contains() {
  if printf '%s' "$1" | grep -qF -- "$2"; then no "$3" "unexpected [$2] in [$1]"; else ok "$3"; fi
}

# ── 1. codex default for review + contract match ────────────────────────
set +e
OUT="$(printf 'Review this PR.' | env PATH="$BIN:$PATH" \
  FAKE_CODEX_ARGS="$TMP/args1" FAKE_CODEX_STDIN="$TMP/stdin1" \
  FAKE_CODEX_MESSAGE='Verdict: pass' \
  "$ADAPTER" --role review --expect '^Verdict: (pass|changes-requested)$' 2>"$TMP/err1")"
ST=$?
set -e
assert_eq 0 "$ST" "review: codex default exits 0"
assert_eq "Verdict: pass" "$OUT" "review: final message is stdout"
ARGS1="$(cat "$TMP/args1")"
assert_contains "$ARGS1" "-m gpt-6.1-sol" "review: pins sol model"
assert_contains "$ARGS1" "-s read-only" "review: read-only sandbox"
assert_contains "$ARGS1" "model_reasoning_effort=high" "review: pins high effort"
assert_contains "$(cat "$TMP/stdin1")" "Review this PR." "review: prompt reaches stdin"

# ── 1b. binary resolution does not depend on the service PATH ───────────
set +e
OUT="$(printf 'x' | env PATH="/usr/bin:/bin" FISH_LLM_CODEX_BIN="$BIN/codex" \
  FAKE_CODEX_MESSAGE='Verdict: pass' \
  "$ADAPTER" --role review --expect '^Verdict: (pass|changes-requested)$' 2>"$TMP/err1b")"
ST=$?
set -e
assert_eq 0 "$ST" "binary override: codex missing from PATH still works"
assert_eq "Verdict: pass" "$OUT" "binary override: returns the verdict"

# ── 2. contract mismatch is fail-closed ─────────────────────────────────
set +e
OUT="$(printf 'x' | env PATH="$BIN:$PATH" FAKE_CODEX_MESSAGE='no verdict here' \
  "$ADAPTER" --role review --expect '^Verdict: (pass|changes-requested)$' 2>"$TMP/err2")"
ST=$?
set -e
assert_eq 3 "$ST" "contract mismatch exits 3"
assert_eq "" "$OUT" "contract mismatch prints nothing on stdout"

# ── 3. empty output is fail-closed ──────────────────────────────────────
set +e
OUT="$(printf 'x' | env PATH="$BIN:$PATH" FAKE_CODEX_MESSAGE='' \
  "$ADAPTER" --role review 2>"$TMP/err3")"
ST=$?
set -e
assert_eq 3 "$ST" "empty final message exits 3"
assert_eq "" "$OUT" "empty final message prints nothing"

# ── 4. child failure propagates ─────────────────────────────────────────
set +e
printf 'x' | env PATH="$BIN:$PATH" FAKE_CODEX_EXIT=7 "$ADAPTER" --role review 2>"$TMP/err4"
ST=$?
set -e
assert_eq 7 "$ST" "codex non-zero exit propagates"

# ── 5. hard timeout ─────────────────────────────────────────────────────
set +e
printf 'x' | env PATH="$BIN:$PATH" FAKE_CODEX_SLEEP=5 \
  "$ADAPTER" --role review --timeout 1 2>"$TMP/err5"
ST=$?
set -e
assert_eq 124 "$ST" "timeout exits 124"

# ── 6. per-role backend override → opencode fallback ────────────────────
set +e
OUT="$(printf 'x' | env PATH="$BIN:$PATH" FISH_LLM_REVIEW_BACKEND=opencode \
  FAKE_OPENCODE_ARGS="$TMP/args6" FAKE_OPENCODE_MESSAGE='Verdict: changes-requested' \
  "$ADAPTER" --role review --expect '^Verdict: (pass|changes-requested)$' 2>"$TMP/err6")"
ST=$?
set -e
assert_eq 0 "$ST" "override: opencode review exits 0"
ARGS6="$(cat "$TMP/args6")"
assert_contains "$ARGS6" "--model opencode-go/muse-spark-1.3-contributor#xhigh" "override: uses opencode model"
assert_not_contains "$ARGS6" "--auto" "override: review is not auto-approved"
assert_eq "Verdict: changes-requested" "$OUT" "override: parses changes-requested"

# ── 7. agent markdown is inlined for codex (frontmatter stripped) ───────
set +e
printf 'MODE: pr\nPR: 42' | env PATH="$BIN:$PATH" \
  FAKE_CODEX_STDIN="$TMP/stdin7" FAKE_CODEX_MESSAGE='Verdict: safe' \
  "$ADAPTER" --role security-guard --expect '^Verdict:' >/dev/null 2>"$TMP/err7"
ST=$?
set -e
STDIN7="$(cat "$TMP/stdin7")"
assert_eq 0 "$ST" "agent inline: exits 0"
assert_contains "$STDIN7" "security guardian" "agent inline: role instructions included"
assert_contains "$STDIN7" "MODE: pr" "agent inline: task prompt included"
assert_not_contains "$STDIN7" "description: Audits" "agent inline: frontmatter stripped"

# ── 8. read-only run that mutates the tree fails closed ─────────────────
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
echo base >"$REPO/tracked.txt"
git -C "$REPO" add tracked.txt
git -C "$REPO" -c user.name=test -c user.email=test@example.com commit -qm base

set +e
(
  cd "$REPO"
  printf 'x' | env PATH="$BIN:$PATH" FAKE_CODEX_MUTATE=1 FAKE_CODEX_MESSAGE='Verdict: pass' \
    "$ADAPTER" --role review --read-only 2>"$TMP/err8"
)
ST=$?
set -e
assert_eq 4 "$ST" "read-only mutation exits 4"

set +e
(
  cd "$REPO"
  printf 'x' | env PATH="$BIN:$PATH" FAKE_CODEX_MESSAGE='Verdict: pass' \
    "$ADAPTER" --role review --read-only >/dev/null 2>"$TMP/err9"
)
ST=$?
set -e
assert_eq 0 "$ST" "read-only clean tree exits 0"

echo
# ── 9. role models follow the backend ───────────────────────────────────
set +e
printf 'x' | env PATH="$BIN:$PATH" FAKE_OPENCODE_ARGS="$TMP/args10" \
  FAKE_OPENCODE_MESSAGE='Verdict: safe' \
  "$ADAPTER" --role data-guard --expect '^Verdict:' >/dev/null 2>"$TMP/err10"
ST=$?
set -e
ARGS10="$(cat "$TMP/args10")"
assert_eq 0 "$ST" "data-guard: opencode default exits 0"
assert_contains "$ARGS10" "--agent data-guardian" "data-guard: keeps guardian agent"
assert_contains "$ARGS10" "--model opencode-go/deepseek-v4.1-flash#high" "data-guard: keeps deepseek model"

echo
# ── 10. broken codex sandbox is fail-closed (no tool-less review) ───────
FAILBIN="$TMP/failbin"
mkdir -p "$FAILBIN"
cat >"$FAILBIN/bwrap" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
chmod +x "$FAILBIN/bwrap"
rm -f "$TMP/args-gate"
set +e
printf 'x' | env PATH="$FAILBIN:$BIN:$PATH" FISH_LLM_CODEX_SANDBOX_CHECK=1 \
  FAKE_CODEX_ARGS="$TMP/args-gate" FAKE_CODEX_MESSAGE='Verdict: pass' \
  "$ADAPTER" --role review --expect '^Verdict:' >"$TMP/out-gate" 2>"$TMP/err-gate"
ST=$?
set -e
assert_eq 2 "$ST" "sandbox gate: broken bwrap exits 2"
if [ -e "$TMP/args-gate" ]; then
  no "sandbox gate: codex was not invoked" "fake codex ran despite the broken sandbox"
else
  ok "sandbox gate: codex was not invoked"
fi
assert_contains "$(cat "$TMP/err-gate")" "apparmor_restrict_unprivileged_userns" \
  "sandbox gate: tells the operator how to fix it"

# ── 11. discover role defaults to codex/read-only ───────────────────────
set +e
OUT="$(printf 'audit' | env PATH="$BIN:$PATH" FAKE_CODEX_ARGS="$TMP/args-discover" \
  FAKE_CODEX_MESSAGE='DISCOVERY: 0' \
  "$ADAPTER" --role discover --expect '^DISCOVERY: [0-9]+$' 2>"$TMP/err-discover")"
ST=$?
set -e
ARGS_DISCOVER="$(cat "$TMP/args-discover")"
assert_eq 0 "$ST" "discover: codex default exits 0"
assert_eq "DISCOVERY: 0" "$OUT" "discover: final message is stdout"
assert_contains "$ARGS_DISCOVER" "-s read-only" "discover: read-only sandbox"
assert_contains "$ARGS_DISCOVER" "-m gpt-6.1-sol" "discover: pins sol model"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
