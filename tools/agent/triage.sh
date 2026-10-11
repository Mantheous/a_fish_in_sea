#!/usr/bin/env bash
# Triage agent-pending issues: verify tester, draft plan via headless opencode,
# post plan comment, ping Telegram. Safe to re-run: skips already-triaged issues.
# Read-only except: GitHub comments/labels + Telegram sends. Never touches code.
set -euo pipefail
REPO="$HOME/Repos/a_fish_in_sea"
cd "$REPO"
DIR="$REPO/tools/agent"
MARKER='<!-- agent-plan -->'

ISSUES_JSON="$(gh issue list --label agent-pending --state open --limit 20 \
  --json number,title,author,url)"
COUNT="$(echo "$ISSUES_JSON" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
echo "[triage] agent-pending open: $COUNT"
[ "$COUNT" = "0" ] && exit 0

echo "$ISSUES_JSON" | python3 -c 'import json,sys; [print(i["number"]) for i in json.load(sys.stdin)]' | while read -r N; do
  META="$(gh issue view "$N" --json number,title,author,url,comments)"
  AUTHOR="$(echo "$META" | python3 -c 'import json,sys; print(json.load(sys.stdin)["author"]["login"])')"
  TITLE="$(echo "$META" | python3 -c 'import json,sys; print(json.load(sys.stdin)["title"])')"
  URL="$(echo "$META" | python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])')"

  if ! python3 -c "import json,sys; sys.exit(0 if '$AUTHOR' in json.load(open('$REPO/tools/testers.json'))['testers'] else 1)"; then
    echo "[triage] #$N (@$AUTHOR) not a verified tester — commenting and unlabelling"
    gh issue comment "$N" --body "Not a verified tester (see \`tools/testers.json\`). This issue will not be picked up by the agent loop." >/dev/null
    gh issue edit "$N" --remove-label agent-pending >/dev/null
    continue
  fi

  if gh issue view "$N" --comments --json comments --jq '.comments[].body' 2>/dev/null | grep -qF "$MARKER"; then
    echo "[triage] #$N already has a plan — skipping (approval handled separately)"
    continue
  fi

  echo "[triage] #$N ($TITLE) drafting plan via headless opencode..."
  PROMPT="You are the triage agent for the repo you are already inside (a_fish_in_sea on branch main).
READ-ONLY task. Do NOT modify, create or delete any files. Do NOT run builds or tests. Do NOT commit.
1. Run: gh issue view $N --json number,title,body,author,labels
2. Explore the repo read-only (read/grep/glob) to ground the plan. Read AGENTS.md first for persistence rules.
3. Output ONLY the markdown below, no extra prose before or after:
## Triage plan #$N
Severity: <critical|high|medium|low>
Summary: <exactly 2 lines: line1 what is asked, line2 proposed approach>
Files to touch: <list of paths, or TBD with why>
Risk: <low|high> — <one-line reason>
Test idea: <one line: what test would prove it>
Persistence impact: <none | description + migration gating per AGENTS.md>
Effort: <S|M|L>"
  PLAN_FILE="$(mktemp)"
  if ! opencode run --title "triage-#$N" "$PROMPT" >"$PLAN_FILE" 2>"$PLAN_FILE.err"; then
    echo "[triage] #$N plan draft failed: $(tail -n 3 "$PLAN_FILE.err")"
    rm -f "$PLAN_FILE" "$PLAN_FILE.err"
    continue
  fi
  rm -f "$PLAN_FILE.err"
  PLAN="$(cat "$PLAN_FILE"; rm -f "$PLAN_FILE")"

  COMMENT="$PLAN

---
Approve: comment \`approve\` (or \`agent approved\`) on this issue (builder picks it up automatically).
Deny: comment \`deny <reason>\` (issue is closed).
$MARKER"
  gh issue comment "$N" --body "$COMMENT" >/dev/null
  echo "[triage] #$N plan posted"

  SUMMARY="$(echo "$PLAN" | python3 -c "
import sys
lines = sys.stdin.read().splitlines()
for i, l in enumerate(lines):
    if l.startswith('Summary:'):
        print(l.replace('Summary:', '').strip())
        if i + 1 < len(lines) and lines[i+1].strip() and not lines[i+1].startswith(('Files', 'Risk', '#')):
            print(lines[i+1].strip())
        break
" | head -n 2)"
  RISK="$(echo "$PLAN" | grep -m1 '^Risk:' || echo 'Risk: unknown')"
  "$DIR/tg.sh" "🆕 Triage plan #$N: $TITLE
$SUMMARY
$RISK
$URL
Approve: comment \`approve\` (or \`agent approved\`) on the issue / Deny: comment \`deny <reason>\`" || echo "[triage] #$N telegram ping failed (plan comment still posted)"
done
echo "[triage] done"
