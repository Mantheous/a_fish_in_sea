#!/usr/bin/env bash
# Tests for tools/agent/usage_filter.py. No network, no gh calls:
# dry-run only, with fake issue/PR JSON and a temp index.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="$HERE/../usage_filter.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/msg.md" <<'EOF'
DISCOVERY: 2
## Candidate
Title: Tasks tab has no recorded visits in 30 days
Severity: low
Confidence: high
Fingerprint: usage-unused-screen-tasks
Where: lib/navigation/bloc/navigation_cubit.dart:4
User impact: The Tasks tab was never opened since logging started.
Evidence: screen.tasks uses=0 over 20 active days with 19 days of history.
Suggested scope: Remove the Tasks destination after the developer confirms.
Test idea: drawer widget test that asserts the remaining destinations.
## Candidate
Title: Event sheet is cancelled more often than saved
Severity: medium
Confidence: high
Fingerprint: usage-friction-event-editor-cancel
Where: lib/planner/view/calendar_page.dart:2333
User impact: The create sheet is closed without saving more often than saved.
Evidence: event.editor.close saved=false 12 of 20 closes; no error events.
Suggested scope: inspect the create sheet defaults and the cancel path.
Test idea: widget test that cancels the sheet and asserts no draft remains.
EOF

echo '{"fingerprints": {}}' >"$TMP/index.json"
echo '[]' >"$TMP/open.json"
echo '[]' >"$TMP/closed.json"
echo '[]' >"$TMP/prs.json"

OUT="$(python3 "$FILTER" --input "$TMP/msg.md" --open "$TMP/open.json" \
  --closed "$TMP/closed.json" --prs "$TMP/prs.json" \
  --index "$TMP/index.json" --dry-run 2>"$TMP/err")"
printf '%s\n' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["selected"]==2, d; assert d["dry_run"], d'
grep -q 'would file: Tasks tab' "$TMP/err"
grep -q 'would file: Event sheet' "$TMP/err"
echo "ok - dry-run selects both candidates without filing"

# A fingerprint already present in an open issue is rejected.
python3 - "$TMP/open.json" <<'PY'
import json, sys
issue = {
    "number": 7,
    "title": "Tasks tab has no recorded visits in 30 days",
    "body": "<!-- discovered: usage-unused-screen-tasks -->",
    "labels": [],
}
json.dump([issue], open(sys.argv[1], "w"))
PY
OUT2="$(python3 "$FILTER" --input "$TMP/msg.md" --open "$TMP/open.json" \
  --closed "$TMP/closed.json" --prs "$TMP/prs.json" \
  --index "$TMP/index.json" --dry-run 2>"$TMP/err2")"
printf '%s\n' "$OUT2" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["selected"]==1, d; assert any("duplicate" in r["reason"] or "similar" in r["reason"] for r in d["rejected"]), d'
echo "ok - duplicate fingerprint is rejected"

# A removal body carries the screenshot + human-merge warning.
python3 - "$FILTER" <<'PY'
import sys
sys.path.insert(0, sys.argv[1].rsplit("/", 1)[0])
from usage_filter import _body, _is_removal
candidate = {
    "title": "Tasks tab has no recorded visits in 30 days",
    "severity": "low",
    "confidence": "high",
    "fingerprint": "usage-unused-screen-tasks",
    "where": "lib/navigation/bloc/navigation_cubit.dart:4",
    "impact": "The Tasks tab was never opened since logging started.",
    "evidence": "screen.tasks uses=0 over 20 active days with 19 days of history.",
    "scope": "Remove the Tasks destination after the developer confirms.",
    "test": "drawer widget test that asserts the remaining destinations.",
}
assert _is_removal(candidate)
body = _body(candidate, "2026-10-29T00:00:00Z")
assert "Before removing" in body
assert "needs-human-merge" in body
assert "screenshot" in body
assert "<!-- discovered: usage-unused-screen-tasks -->" in body
print("ok - removal body contains the human-merge warning")
PY

echo "passed: usage filter"
