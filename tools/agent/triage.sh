#!/usr/bin/env bash
# Triage agent-pending issues: verify tester, draft/revise plan via headless
# opencode, post plan comment, ping Telegram. Safe to re-run.
# Two paths per issue:
#   1. No plan yet -> draft initial plan (with screenshots).
#   2. Plan exists + human tester feedback after it -> revise the plan and
#      reply in-thread, so the human can converse until the plan is right.
# Read-only except: GitHub comments/labels + Telegram sends + /tmp image
# downloads. Never touches code.
#
# NOTE (2026-10-15): the plan comments below are the maintainer's primary
# reading material, and model prose skews too technical to parse without
# deep codebase context — hence the plain-words rules in the prompts. If
# readability is still poor, route the commentary through longcat (clear
# explanations, weak code): e.g. a second pass that rewrites the plan/PR
# body in plain words before posting.
set -euo pipefail
REPO="$HOME/Repos/a_fish_in_sea"
cd "$REPO"
DIR="$REPO/tools/agent"
MARKER='<!-- agent-plan -->'

# Serialized model quota: triage spawns headless opencode runs, so it must
# not stack LLM calls on top of a live builder/rework session (the quota
# death spiral build.sh/review.sh already guard against). Skip this poll
# when any loop run is active; the next poll retries.
loop_runs() {
  tmux ls -F '#{session_name}' 2>/dev/null | grep -cE '^(agent-[0-9]|rework-[0-9])' || true
}
RUNNING="$(loop_runs)"
if [ "${RUNNING:-0}" -ge 1 ]; then
  echo "[triage] $RUNNING loop run(s) already active — skipping triage this poll so builders are not starved"
  exit 0
fi

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
    if ! gh issue comment "$N" --body "Not a verified tester (see \`tools/testers.json\`). This issue will not be picked up by the agent loop." >/dev/null \
        || ! gh issue edit "$N" --remove-label agent-pending >/dev/null; then
      echo "[triage] #$N could not unlabel (gh hiccup) — retried next poll"
    fi
    continue
  fi

  # Pre-download issue screenshots so the agent can VIEW them (headless
  # agents can read local images via the read tool but cannot view remote
  # URLs — never report a screenshot as unloadable, read the download).
  IMGDIR="/tmp/opencode/issue-$N-imgs"
  "$DIR/fetch-issue-images.sh" "$N" "$IMGDIR" >/dev/null 2>&1 || true
  IMGS="$(ls "$IMGDIR"/img*.* 2>/dev/null | tr '\n' ' ' || true)"
  [ -z "${IMGS// /}" ] && IMGS="(none — no image attachments found)"

  HAS_PLAN=0
  if gh issue view "$N" --comments --json comments --jq '.comments[].body' 2>/dev/null | grep -qF "$MARKER"; then
    HAS_PLAN=1
  fi

  if [ "$HAS_PLAN" = "0" ]; then
    echo "[triage] #$N ($TITLE) drafting plan via headless opencode..."
    PROMPT="You are the triage agent for the repo you are already inside (a_fish_in_sea on branch main).
READ-ONLY task. Do NOT modify, create, delete, or commit any repo files. Do NOT run builds or tests. You MAY download files under /tmp/opencode/ for viewing only.
1. Run: gh issue view $N --json number,title,body,comments (the full spec — body plus every comment).
2. Screenshots are part of the spec — never say an image could not be loaded:
   - Pre-downloaded issue images (if any) are in $IMGDIR (found: $IMGS). List that dir and READ each image file with the read tool to VIEW it.
   - If the issue body/comments mention /tmp/opencode/... paths (ux-walk screenshots/reports live on this loop host), read those files directly.
   - If you see any other image URL in the thread you have not viewed, download it with: curl -sL \"<url>\" -o /tmp/opencode/issue-$N-extra-<i>.png then READ it. Use what you see to name the exact screen and widget.
3. Explore the repo read-only (read/grep/glob) to ground the plan. Read AGENTS.md first for persistence rules.
4. Write for the maintainer, who is NOT deep in the codebase: plain,
concrete words — name the screen and the user-visible behavior, never a
class or function name, and no unexplained jargon anywhere. The Summary
lines especially must make sense without reading any code; technical
detail belongs in the Files/Risk/Test fields only.
5. Output ONLY the markdown below, no extra prose before or after:
## Triage plan #$N
Severity: <critical|high|medium|low>
Summary: <exactly 2 lines in plain words: line1 what the user will notice, line2 proposed approach>
Files to touch: <list of paths, or TBD with why>
Risk: <low|high> — <one-line reason>
Test idea: <one line: what test would prove it>
Persistence impact: <none | description + migration gating per AGENTS.md>
UX check: <needed (touches user-visible UI — builder must add the ux-walk label + scope per AGENTS.md; the loop walks it post-deploy, never pre-merge) | not needed — <why>>
Effort: <S|M|L>"
    PLAN_FILE="$(mktemp)"
    # NOTE: `opencode run` without --model keeps the configured default (a
    # free-tier model). Pin --model explicitly so triage stays on opencode-go.
    if ! opencode run --model opencode-go/muse-spark-1.3-contributor#xhigh --title "triage-#$N" "$PROMPT" </dev/null >"$PLAN_FILE" 2>"$PLAN_FILE.err"; then
      echo "[triage] #$N plan draft failed: $(tail -n 3 "$PLAN_FILE.err")"
      rm -f "$PLAN_FILE" "$PLAN_FILE.err"
      continue
    fi
    rm -f "$PLAN_FILE.err"
    PLAN="$(cat "$PLAN_FILE"; rm -f "$PLAN_FILE")"

    COMMENT="$PLAN

---
The loop builds triaged plans automatically (auto-ship mode: no approval
needed). To stop this issue, comment \`deny <reason>\` — the loop closes it.
To question or correct the plan, just comment in-thread — the triage agent revises the plan on the next poll.
$MARKER"
    if ! gh issue comment "$N" --body "$COMMENT" >/dev/null; then
      echo "[triage] #$N plan comment failed (gh hiccup) — retried next poll"
      continue
    fi
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
    "$DIR/tg.sh" "🔨 Working on #$N: $TITLE
$SUMMARY
$RISK
$URL
To stop it, comment \`deny <reason>\` on the issue." || echo "[triage] #$N telegram ping failed (plan comment still posted)"
    continue
  fi

  # --- plan exists: look for human tester feedback after the latest plan ---
  FEEDBACK="$(gh issue view "$N" --comments --json comments \
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
def is_decision(body):
    lines = (body or '').strip().splitlines()
    first = lines[0].strip().lower() if lines else ''
    return first == 'approve' or 'agent approved' in first or first.startswith('deny')
last_plan = max((i for i, c in enumerate(comments) if '<!-- agent-plan' in (c.get('body') or '')), default=-1)
out = []
for i in range(last_plan + 1, len(comments)):
    c = comments[i]
    login = (c.get('author') or {}).get('login', '')
    body = c.get('body') or ''
    if login not in testers:
        continue
    if is_agent(body):
        continue
    if is_decision(body):
        continue
    out.append(f\"{login}: \" + body.strip()[:1500])
print('\n---\n'.join(out), end='')
")"
  if [ -z "$FEEDBACK" ]; then
    # Self-heal: a plan that gave up on screenshots ("could not be loaded")
    # is stale once fetch-issue-images.sh actually has the files — revise
    # without waiting for the human to repeat themselves (e.g. issue #32).
    LATEST_PLAN="$(gh issue view "$N" --comments --json comments --jq '[.comments[].body | select(contains("<!-- agent-plan"))] | last // empty' 2>/dev/null || true)"
    if echo "${LATEST_PLAN:-}" | grep -qiE 'could not be (loaded|read)|could not load|unable to (load|view|read)|screenshot.*(unavailable|missing|unknown)|specific .* (unidentified|unknown)' \
      && ls "$IMGDIR"/img*.* >/dev/null 2>&1; then
      FEEDBACK="system: previous plan reported screenshot as unloadable, but images are now available — re-examine them"
      echo "[triage] #$N previous plan missed screenshots but images now exist — revising..."
    else
      echo "[triage] #$N already has a plan and no new human feedback — skipping (approval handled separately)"
      continue
    fi
  else
    echo "[triage] #$N human feedback after plan — revising..."
  fi
  REVPROMPT="You are the triage agent revising the plan for issue #$N after human feedback. Repo: a_fish_in_sea on branch main.
READ-ONLY task. Do NOT modify, create, delete, or commit any repo files. Do NOT run builds or tests. You MAY download files under /tmp/opencode/ for viewing only.
1. Run: gh issue view $N --json number,title,body,comments (full thread: previous plan plus the human follow-ups after it).
2. Screenshots are part of the spec — never say an image could not be loaded:
   - Pre-downloaded issue images (if any) are in $IMGDIR (found: $IMGS). List that dir and READ each image file with the read tool to VIEW it.
   - If the thread mentions /tmp/opencode/... paths (ux-walk screenshots/reports on this loop host), read those files directly.
   - Any other image URL you have not viewed: curl -sL \"<url>\" -o /tmp/opencode/issue-$N-rev-<i>.png then READ it.
3. Explore the repo read-only (read/grep/glob) as needed. Read AGENTS.md first for persistence rules.
4. Address EVERY human follow-up point after the previous plan: answer questions, incorporate corrections into the revised scope. If feedback is ambiguous, pick the safest interpretation AND note the assumption plus what to confirm.
5. Write for the maintainer, who is NOT deep in the codebase: plain,
concrete words — name the screen and the user-visible behavior, never a
class or function name, and no unexplained jargon anywhere.
6. Output ONLY the markdown below, no extra prose before or after:
## Triage plan #$N (rev)
Replies: <one short plain-words line per follow-up point: what you changed or answered>
Severity: <critical|high|medium|low>
Summary: <exactly 2 lines in plain words: line1 what the user will notice (as clarified), line2 revised approach>
Files to touch: <list of paths, or TBD with why>
Risk: <low|high> — <one-line reason>
Test idea: <one line: what test would prove it>
Persistence impact: <none | description + migration gating per AGENTS.md>
UX check: <needed (touches user-visible UI — builder must add the ux-walk label + scope per AGENTS.md; the loop walks it post-deploy, never pre-merge) | not needed — <why>>
Effort: <S|M|L>"
  REV_FILE="$(mktemp)"
  if ! opencode run --model opencode-go/muse-spark-1.3-contributor#xhigh --title "triage-rev-#$N" "$REVPROMPT" </dev/null >"$REV_FILE" 2>"$REV_FILE.err"; then
    echo "[triage] #$N revision failed: $(tail -n 3 "$REV_FILE.err")"
    rm -f "$REV_FILE" "$REV_FILE.err"
    continue
  fi
  rm -f "$REV_FILE.err"
  REVPLAN="$(cat "$REV_FILE"; rm -f "$REV_FILE")"
  REVCOMMENT="$REVPLAN

---
The loop builds triaged plans automatically (auto-ship mode: no approval
needed). To stop this issue, comment \`deny <reason>\` — the loop closes it.
Further feedback in-thread will be revised again on the next poll.
$MARKER"
  if ! gh issue comment "$N" --body "$REVCOMMENT" >/dev/null; then
    echo "[triage] #$N revised plan comment failed (gh hiccup) — retried next poll"
  else
    echo "[triage] #$N revised plan posted"
    "$DIR/tg.sh" "🔄 Plan for #$N revised after feedback: $TITLE
$URL
Working on the latest plan automatically — comment \`deny <reason>\` on the issue to stop it." || echo "[triage] #$N telegram ping failed (revision still posted)"
  fi
done
echo "[triage] done"
