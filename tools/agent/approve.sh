#!/usr/bin/env bash
# Approval handling: verified `approve` / `deny <reason>` comments on triaged
# (agent-pending + plan marker) issues flip labels or close. Safe to re-run.
set -euo pipefail
REPO="$HOME/Repos/a_fish_in_sea"
cd "$REPO"
DIR="$REPO/tools/agent"
MARKER='<!-- agent-plan -->'

COUNT="$(gh issue list --label agent-pending --state open --limit 20 --json number \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
echo "[approve] scanning $COUNT agent-pending issues"
[ "$COUNT" = "0" ] && exit 0

gh issue list --label agent-pending --state open --limit 20 --json number \
  | python3 -c 'import json,sys; [print(i["number"]) for i in json.load(sys.stdin)]' | while read -r N; do
  if ! gh issue view "$N" --comments --json comments --jq '.comments[].body' 2>/dev/null | grep -qF "$MARKER"; then
    continue  # not triaged yet
  fi
  URL="$(gh issue view "$N" --json url --jq .url)"
  TITLE="$(gh issue view "$N" --json title --jq .title)"
  # Latest decision comment from a verified tester: standalone `approve` or `deny <reason>`.
  DECISION="$(gh issue view "$N" --comments --json comments \
    | python3 -c "
import json, sys
testers = json.load(open('$REPO/tools/testers.json'))['testers']
comments = json.load(sys.stdin)['comments']
for c in reversed(comments):
    login = (c.get('author') or {}).get('login', '')
    if login not in testers:
        continue
    first = (c.get('body') or '').strip().splitlines()[0].strip() if (c.get('body') or '').strip() else ''
    low = first.lower()
    if low == 'approve' or 'agent approved' in low:
        print(f'approve|{login}|'); break
    if low.startswith('deny'):
        print(f'deny|{login}|{first[4:].strip()}'); break
print('', end='')
")"
  [ -z "$DECISION" ] && { echo "[approve] #$N no decision comment — waiting"; continue; }
  KIND="$(echo "$DECISION" | cut -d'|' -f1)"
  WHO="$(echo "$DECISION" | cut -d'|' -f2)"
  ARG="$(echo "$DECISION" | cut -d'|' -f3-)"
  if [ "$KIND" = "approve" ]; then
    echo "[approve] #$N approved by @$WHO"
    gh issue edit "$N" --remove-label agent-pending --add-label agent-approved >/dev/null
    gh issue comment "$N" --body "Approved by @$WHO — builder will pick this up automatically." >/dev/null
    "$DIR/tg.sh" "✅ #$N approved (@$WHO) — builder starting: $TITLE
$URL" || true
  else
    REASON="${ARG:-no reason given}"
    echo "[approve] #$N denied by @$WHO: $REASON"
    gh issue comment "$N" --body "Denied by @$WHO: $REASON" >/dev/null
    gh issue close "$N" >/dev/null
    "$DIR/tg.sh" "🚫 #$N denied (@$WHO): $REASON
$TITLE" || true
  fi
done
echo "[approve] done"
