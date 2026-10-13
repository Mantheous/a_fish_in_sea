#!/usr/bin/env bash
# Approval handling: verified `approve` / `deny <reason>` comments on triaged
# (agent-pending + plan marker) issues flip labels or close. Safe to re-run.
# An approval is only valid when it comes AFTER the latest <!-- agent-plan -->
# comment AND there is no unaddressed human feedback (tester follow-up that
# triage.sh has not revised yet) — otherwise we wait so the plan conversation
# (feedback -> revised plan -> re-approve) completes before the builder starts.
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
  # Decision + feedback state relative to the latest plan. Agent comments
  # share the human's login (same token), so agent vs human is by marker,
  # not author: anything with <!-- agent- or the known bot one-liners is
  # the loop talking to itself, everything else from a tester is human.
  STATE="$(gh issue view "$N" --comments --json comments \
    | python3 -c "
import json, sys
testers = json.load(open('$REPO/tools/testers.json'))['testers']
comments = json.load(sys.stdin)['comments']
def is_agent(body):
    b = (body or '')
    if '<!-- agent-' in b:
        return True
    s = b.strip().lower()
    for p in ('approved by @', 'denied by', 'not a verified tester', 'ux walk'):
        if s.startswith(p):
            return True
    return False
def decision_of(body):
    lines = (body or '').strip().splitlines()
    first = lines[0].strip() if lines else ''
    low = first.lower()
    if low == 'approve' or 'agent approved' in low:
        return 'approve'
    if low.startswith('deny'):
        return 'deny|' + first[4:].strip()
    return ''
last_plan = max((i for i, c in enumerate(comments) if '<!-- agent-plan' in (c.get('body') or '')), default=-1)
kind = ''; who = ''; arg = ''; feedback = 0
for i in range(last_plan + 1, len(comments)):
    c = comments[i]
    login = (c.get('author') or {}).get('login', '')
    body = c.get('body') or ''
    if login not in testers:
        continue
    if is_agent(body):
        continue
    d = decision_of(body)
    if d.startswith('deny'):
        kind, who, arg = 'deny', login, d.split('|', 1)[1] if '|' in d else ''
    elif d == 'approve':
        kind, who, arg = 'approve', login, ''
    else:
        feedback += 1
print(f'{kind}|{who}|{arg}|{feedback}')
")"
  KIND="$(echo "$STATE" | cut -d'|' -f1)"
  WHO="$(echo "$STATE" | cut -d'|' -f2)"
  ARG="$(echo "$STATE" | cut -d'|' -f3)"
  FEEDBACK_COUNT="$(echo "$STATE" | cut -d'|' -f4)"
  if [ -n "${FEEDBACK_COUNT:-}" ] && [ "$FEEDBACK_COUNT" -gt 0 ] 2>/dev/null; then
    echo "[approve] #$N $FEEDBACK_COUNT unaddressed human comment(s) after latest plan — waiting for triage revision"
    continue
  fi
  if [ -z "$KIND" ]; then
    echo "[approve] #$N no decision comment after latest plan — waiting"
    continue
  fi
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
