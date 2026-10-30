#!/usr/bin/env bash
# Tests for the proactive discovery step. Pure bash + a fake gh + a fake
# llm-run; no network and no model calls. Run from anywhere:
#
#   tools/agent/test/discover-test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISCOVER="$HERE/../discover.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"

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

# ── fixtures ────────────────────────────────────────────────────────────
REPO="$TMP/repo"
mkdir -p "$REPO/lib" "$REPO/test"
printf 'void main() {}\n' >"$REPO/lib/main.dart"
printf 'void main() {}\n' >"$REPO/test/main_test.dart"
(
  cd "$REPO"
  git init -q
  git config user.email test@example.com
  git config user.name test
  git add -A
  git commit -qm init
)

OPEN="$TMP/open.json"
CLOSED="$TMP/closed.json"
PRS="$TMP/prs.json"
printf '%s' '[{"number":10,"title":"Existing open bug","body":"<!-- discovered: existing-fp -->","labels":[{"name":"bug"}]}]' >"$OPEN"
printf '%s' '[{"number":9,"title":"Old fixed behavior","body":"","closedAt":"2026-10-01T00:00:00Z"}]' >"$CLOSED"
printf '%s' '[{"number":20,"title":"Existing agent PR","body":"","headRefName":"agent/20-existing"}]' >"$PRS"

cat >"$BIN/gh" <<'FAKE_GH'
#!/usr/bin/env python3
import json, os, sys

args = sys.argv[1:]
log = os.environ.get("GH_LOG")
if log:
    with open(log, "a", encoding="utf-8") as handle:
        handle.write(" ".join(args) + "\n")

def opt(name, default=""):
    return args[args.index(name) + 1] if name in args else default

if args[:3] == ["repo", "view", "--json"] or args[:2] == ["repo", "view"]:
    print("Mantheous/a_fish_in_sea")
    sys.exit(0)

if args[:2] == ["issue", "list"]:
    state = opt("--state", "open")
    path = os.environ.get("GH_OPEN_JSON" if state == "open" else "GH_CLOSED_JSON")
    sys.stdout.write(open(path, encoding="utf-8").read() if path else "[]")
    sys.exit(0)

if args[:2] == ["pr", "list"]:
    state = opt("--state", "open")
    if state == "open":
        path = os.environ.get("GH_PRS_JSON")
        sys.stdout.write(open(path, encoding="utf-8").read() if path else "[]")
    sys.exit(0)

if args[:2] == ["issue", "create"]:
    if os.environ.get("GH_FAIL_CREATE") == "1":
        print("simulated create failure", file=sys.stderr)
        sys.exit(1)
    title = opt("--title")
    body = open(opt("--body-file"), encoding="utf-8").read()
    labels = [args[i + 1] for i, arg in enumerate(args) if arg == "--label"]
    counter = os.environ["GH_COUNTER"]
    try:
        number = int(open(counter, encoding="utf-8").read())
    except Exception:
        number = 500
    with open(counter, "w", encoding="utf-8") as handle:
        handle.write(str(number + 1))
    with open(os.environ["GH_CREATES"], "a", encoding="utf-8") as handle:
        handle.write(json.dumps({"number": number, "title": title, "body": body, "labels": labels}) + "\n")
    print(f"https://github.com/Mantheous/a_fish_in_sea/issues/{number}")
    sys.exit(0)

if args[:2] == ["label", "create"]:
    sys.exit(0)

sys.exit(0)
FAKE_GH
chmod +x "$BIN/gh"

cat >"$BIN/llm-run" <<'FAKE_LLM'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
printf '%s\n' "$*" >>"${LLM_LOG:-/dev/null}"
printf '%s' "${FAKE_DISCOVER_MESSAGE:-}"
exit "${FAKE_DISCOVER_EXIT:-0}"
FAKE_LLM
chmod +x "$BIN/llm-run"

STATE="$TMP/state"
CREATES="$TMP/creates.jsonl"
COUNTER="$TMP/counter"
GHLOG="$TMP/gh.log"
LLMLOG="$TMP/llm.log"
printf '500' >"$COUNTER"
: >"$CREATES"
: >"$GHLOG"
: >"$LLMLOG"

run_discover() {
  env AGENT_REPO="$REPO" AGENT_STATE_DIR="$STATE" AGENT_LLM_RUN="$BIN/llm-run" \
    PATH="$BIN:$PATH" \
    GH_OPEN_JSON="${RUN_OPEN:-$OPEN}" GH_CLOSED_JSON="$CLOSED" GH_PRS_JSON="$PRS" \
    GH_CREATES="$CREATES" GH_COUNTER="$COUNTER" GH_LOG="$GHLOG" \
    GH_FAIL_CREATE="${GH_FAIL_CREATE:-0}" LLM_LOG="$LLMLOG" \
    FAKE_DISCOVER_MESSAGE="${FAKE_DISCOVER_MESSAGE:-}" FAKE_DISCOVER_EXIT="${FAKE_DISCOVER_EXIT:-0}" \
    AGENT_DISCOVER_MIN_INTERVAL_S=0 AGENT_DISCOVER_FAIL_BACKOFF_S=0 \
    AGENT_DISCOVER_QUEUE_LOW="${RUN_QUEUE_LOW:-10}" \
    AGENT_DISCOVER_MAX_INFLIGHT="${RUN_MAX_INFLIGHT:-10}" \
    AGENT_DISCOVER_MAX_ISSUES=2 \
    "$DISCOVER" "$@"
}

creates() { wc -l <"$CREATES" | tr -d ' '; }
last_create() { tail -n 1 "$CREATES"; }
field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2], ""))' "$1" "$2"; }

MESSAGE='DISCOVERY: 2
## Candidate
Title: Sign-out keeps previous account goals
Severity: high
Confidence: high
Fingerprint: signout-goals-cross-account
Where: lib/settings/view/settings_page.dart:249
User impact: After signing out on a shared device, the next person sees the previous account goals.
Evidence: Sign-out resets AuthCubit but not NodeCubit, so the hydrated store is reused by the next account.
Suggested scope: Reset NodeCubit in the sign-out path and extend the sign-out regression test.
Test idea: Sign out, sign in as account B, assert B starts with zero goals.
## Candidate
Title: Rename a terse calendar variable
Severity: low
Confidence: medium
Fingerprint: calendar-rename-variable
Where: lib/calendar/view/calendar_page.dart:10
User impact: No user impact; this is only a rename.
Evidence: The local variable name is terse but correct.
Suggested scope: Rename the variable.
Test idea: None; behavior is unchanged.'

# ── 1. files one high-confidence candidate, rejects medium confidence ────
set +e
OUT="$(FAKE_DISCOVER_MESSAGE="$MESSAGE" run_discover 2>"$TMP/err1")"
ST=$?
set -e
assert_eq 0 "$ST" "run exits 0"
assert_eq 1 "$(creates)" "files exactly one high-confidence candidate"
if [ "$(creates)" = "1" ]; then
  RECORD="$(last_create)"
  assert_eq "Sign-out keeps previous account goals" "$(field "$RECORD" title)" "title is preserved"
  assert_contains "$(field "$RECORD" body)" "<!-- discovered: signout-goals-cross-account -->" "body carries the fingerprint marker"
  assert_contains "$(field "$RECORD" labels)" "agent-pending" "issue enters the triage queue"
  assert_contains "$(field "$RECORD" labels)" "agent-discovered" "issue records its provenance"
  assert_contains "$OUT" "filed=1" "summary reports the filed count"
fi
[ -f "$STATE/discovery-last" ] && ok "success stamps the interval marker" || no "success stamps the interval marker"
[ -f "$STATE/discovery-index.json" ] && ok "success writes the fingerprint index" || no "success writes the fingerprint index"

# ── 2. rerun is deduped by fingerprint ───────────────────────────────────
set +e
FAKE_DISCOVER_MESSAGE="$MESSAGE" run_discover >"$TMP/out2" 2>"$TMP/err2"
ST=$?
set -e
assert_eq 0 "$ST" "dedupe run exits 0"
assert_eq 1 "$(creates)" "rerun does not file the same fingerprint again"
assert_contains "$(cat "$TMP/out2")" "rejected=2" "rerun reports the duplicates as rejected"

# ── 3. dry-run never writes ─────────────────────────────────────────────
DRY_MESSAGE="${MESSAGE/signout-goals-cross-account/dry-run-fingerprint}"
set +e
FAKE_DISCOVER_MESSAGE="$DRY_MESSAGE" run_discover --dry-run >"$TMP/out3" 2>"$TMP/err3"
ST=$?
set -e
assert_eq 0 "$ST" "dry-run exits 0"
assert_eq 1 "$(creates)" "dry-run files nothing"
assert_contains "$(cat "$TMP/out3")" "dry-run" "dry-run is reported"

# ── 4. queue depth gate skips the model entirely ────────────────────────
printf '%s' '[{"number":30,"title":"Pending one","body":"","labels":[{"name":"agent-pending"}]},
{"number":31,"title":"Pending two","body":"","labels":[{"name":"agent-pending"}]}]' >"$TMP/deep.json"
BEFORE_LLM="$(wc -l <"$LLMLOG")"
set +e
RUN_OPEN="$TMP/deep.json" RUN_QUEUE_LOW=2 FAKE_DISCOVER_MESSAGE="$MESSAGE" \
  run_discover >"$TMP/out4" 2>"$TMP/err4"
ST=$?
set -e
assert_eq 0 "$ST" "queue gate exits 0"
assert_eq "$BEFORE_LLM" "$(wc -l <"$LLMLOG")" "queue gate does not call the model"
assert_eq 1 "$(creates)" "queue gate files nothing"

# ── 5. unparseable model output fails closed and backs off ──────────────
rm -f "$STATE/discovery-retry"
set +e
FAKE_DISCOVER_MESSAGE='I could not decide what to file.' run_discover >"$TMP/out5" 2>"$TMP/err5"
ST=$?
set -e
assert_eq 1 "$ST" "unparseable output exits 1"
assert_eq 1 "$(creates)" "unparseable output files nothing"
[ -f "$STATE/discovery-retry" ] && ok "unparseable output stamps a retry backoff" || no "unparseable output stamps a retry backoff"

# ── 6. low-confidence-only output files nothing ─────────────────────────
rm -f "$STATE/discovery-retry"
LOW_MESSAGE='DISCOVERY: 1
## Candidate
Title: Maybe the calendar button is slow
Severity: low
Confidence: medium
Fingerprint: calendar-button-maybe-slow
Where: lib/calendar/view/calendar_page.dart:50
User impact: It might feel slower on a large calendar.
Evidence: The build method allocates a list every frame, but I did not verify the size.
Suggested scope: Cache the list.
Test idea: Profile a large calendar.'
set +e
FAKE_DISCOVER_MESSAGE="$LOW_MESSAGE" run_discover >"$TMP/out6" 2>"$TMP/err6"
ST=$?
set -e
assert_eq 0 "$ST" "low-confidence run exits 0"
assert_eq 1 "$(creates)" "low-confidence candidate is not filed"

# ── 7. failed create backs off instead of claiming success ──────────────
rm -f "$STATE/discovery-retry"
GH_FAIL_MESSAGE="${MESSAGE/Sign-out keeps previous account goals/Sign-out restores the wrong account snapshot}"
GH_FAIL_MESSAGE="${GH_FAIL_MESSAGE/signout-goals-cross-account/failing-create-fingerprint}"
set +e
GH_FAIL_CREATE=1 FAKE_DISCOVER_MESSAGE="$GH_FAIL_MESSAGE" run_discover >"$TMP/out7" 2>"$TMP/err7"
ST=$?
set -e
assert_eq 1 "$ST" "failed create exits 1"
assert_eq 1 "$(creates)" "failed create files nothing"
[ -f "$STATE/discovery-retry" ] && ok "failed create stamps a retry backoff" || no "failed create stamps a retry backoff"

# ── 8. a new fingerprint with a duplicate title is still rejected ───────
FUZZY_MESSAGE="${MESSAGE/signout-goals-cross-account/new-signout-fingerprint}"
set +e
FAKE_DISCOVER_MESSAGE="$FUZZY_MESSAGE" run_discover >"$TMP/out8" 2>"$TMP/err8"
ST=$?
set -e
assert_eq 0 "$ST" "fuzzy dedupe run exits 0"
assert_eq 1 "$(creates)" "similar title is not filed under a new fingerprint"
assert_contains "$(cat "$TMP/out8")" "similar to existing" "similar title is reported as rejected"

# ── 9. token-shaped or host-path content is never published ─────────────
SECRET_MESSAGE='DISCOVERY: 1
## Candidate
Title: Debug panel can expose the sync token
Severity: high
Confidence: high
Fingerprint: debug-panel-token-leak
Where: lib/sync/sync_engine.dart:42
User impact: The debug panel prints the account token into a public issue.
Evidence: The log line includes ghp_abcdefghijklmnopqrstuvwxyz0123456789.
Suggested scope: Redact the token in the debug log and add a regression test.
Test idea: Assert the debug string never contains the token.'
set +e
FAKE_DISCOVER_MESSAGE="$SECRET_MESSAGE" run_discover >"$TMP/out9" 2>"$TMP/err9"
ST=$?
set -e
assert_eq 0 "$ST" "secret-scan run exits 0"
assert_eq 1 "$(creates)" "token-shaped content is not filed"
assert_contains "$(cat "$TMP/out9")" "token/private-key-shaped" "secret scan is reported"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
