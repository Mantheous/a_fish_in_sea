#!/usr/bin/env bash
# Reviewer step of the agent loop: the maker is never the checker.
# For each open PR from an agent/* branch without a current verdict label,
# a headless reviewer (READ-ONLY on code; may only comment + label) checks
# the diff against the linked issue + triage plan and posts exactly one of:
#   review:pass — matches the plan, gates green, no new risks
#   review:changes-requested — with a concrete, bounded fix list
# PRs with review:changes-requested get bounded rework (max 2 rounds,
# tracked by <!-- agent-rework --> comments) in their existing worktree.
# After 2 rounds the verdict stands and a human is pinged. The reviewer
# NEVER merges — merging stays human.
set -euo pipefail
REPO="$HOME/Repos/a_fish_in_sea"
cd "$REPO"
DIR="$REPO/tools/agent"
REVIEW_MARKER='<!-- agent-review -->'
REWORK_MARKER='<!-- agent-rework -->'
PASS_LABEL="review:pass"
FAIL_LABEL="review:changes-requested"
MAX_REWORK=2

gh label create "$PASS_LABEL" --color "0E8A16" \
  --description "Reviewer: diff matches the plan, safe to merge" >/dev/null 2>&1 || true
gh label create "$FAIL_LABEL" --color "D93F0B" \
  --description "Reviewer: changes requested, see verdict comment" >/dev/null 2>&1 || true

PRS="$(gh pr list --state open --limit 20 --json number,headRefName,url,title)"
COUNT="$(echo "$PRS" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
echo "[review] open PRs: $COUNT"
[ "$COUNT" = "0" ] && exit 0

echo "$PRS" | python3 -c 'import json,sys; [print(f"{p[\"number\"]}|{p[\"headRefName\"]}") for p in json.load(sys.stdin)]' | while read -r LINE; do
  N="${LINE%%|*}"
  BRANCH="${LINE#*|}"
  case "$BRANCH" in
    agent/*) ;;
    *) echo "[review] #$N ($BRANCH) not an agent branch — skipping"; continue ;;
  esac
  LABELS="$(gh pr view "$N" --json labels --jq '.labels[].name')"
  if echo "$LABELS" | grep -qx "$PASS_LABEL"; then
    echo "[review] #$N already passed — skipping"
    continue
  fi

  if echo "$LABELS" | grep -qx "$FAIL_LABEL"; then
    # --- bounded rework path ---
    ROUNDS="$(gh pr view "$N" --comments --json comments --jq '.comments[].body' 2>/dev/null | grep -cF "$REWORK_MARKER" || true)"
    if [ "${ROUNDS:-0}" -ge "$MAX_REWORK" ]; then
      echo "[review] #$N rework exhausted ($ROUNDS rounds) — needs human"
      "$DIR/tg.sh" "🧑‍⚖️ PR #$N failed review twice — needs a human:
$(gh pr view "$N" --json url --jq .url)" || true
      continue
    fi
    SESSION="rework-$N"
    if tmux has-session -t "$SESSION" 2>/dev/null; then
      echo "[review] #$N rework session $SESSION already running — skipping"
      continue
    fi
    WT="$(git worktree list --porcelain | awk -v b="$BRANCH" 'BEGIN{dir=""} /^worktree /{dir=$2} $0=="branch refs/heads/"b {print dir; exit}')"
    if [ -z "${WT:-}" ] || [ ! -d "$WT" ]; then
      echo "[review] #$N worktree for $BRANCH gone — cannot rework, needs human"
      continue
    fi
    echo "[review] #$N launching rework round $((ROUNDS + 1)) in $WT"
    tmux new-session -d -s "$SESSION" "$DIR/rework-run.sh $N $((ROUNDS + 1))"
    continue
  fi

  # --- fresh review path ---
  echo "[review] #$N reviewing diff vs plan..."
  PROMPT="You are the reviewer agent. READ-ONLY on code: do NOT modify, create or delete any files. Do NOT run builds or tests. Do NOT commit or push. You may only use gh to READ.
1. Run: gh pr view $N --json number,title,body,comments and: gh pr diff $N
2. Find the linked issue (Closes #<n> in the PR body) and read its <!-- agent-plan --> triage comment: gh issue view <n> --comments --json comments
3. Explore the repo read-only (read/grep/glob) to check the diff against the plan. Read AGENTS.md first for persistence rules.
4. Output ONLY the markdown below, no extra prose before or after:
## Review #$N
Verdict: <pass | changes-requested>
Plan fidelity: <one line: does the diff implement exactly the triage plan scope?>
Correctness: <one line: bugs, edge cases, or wrong behavior you can see>
Persistence: <ok | violation — cite the AGENTS.md rule>
Security: <ok | changes-requested — untrusted-user → GitHub/builder path, auth/scope/SSRF/secrets weakening, or attacker-controlled input executed; cite file:line>
Tests: <one line: do the tests cover the change, including goldens for screens?>
Behavioral: <one line: does a patrol_test cover the changed user flow, or is one needed?>
Walker: <for any user-visible change (lib/*/view, navigation, dialogs, copy): walked pre-merge with report path in the PR body, or CHANGES-REQUESTED listing the exact walk to run. Pass only if walked or provably not user-visible.>
Smallness: <ok | bloated — what should be cut?>
Fix list: <if changes-requested: numbered, concrete, bounded items. If pass: none.>
$REVIEW_MARKER"
  REVIEW_FILE="$(mktemp)"
  if ! opencode run --title "review-#$N" "$PROMPT" >"$REVIEW_FILE" 2>"$REVIEW_FILE.err"; then
    echo "[review] #$N reviewer run failed: $(tail -n 3 "$REVIEW_FILE.err")"
    rm -f "$REVIEW_FILE" "$REVIEW_FILE.err"
    continue
  fi
  rm -f "$REVIEW_FILE.err"
  REVIEW="$(cat "$REVIEW_FILE"; rm -f "$REVIEW_FILE")"
  VERDICT="$(echo "$REVIEW" | grep -m1 '^Verdict:' | grep -o 'changes-requested' || echo pass)"
  gh pr comment "$N" --body "$REVIEW" >/dev/null
  if [ "$VERDICT" = "changes-requested" ]; then
    gh pr edit "$N" --add-label "$FAIL_LABEL" >/dev/null
    echo "[review] #$N changes requested"
    "$DIR/tg.sh" "🧑‍⚖️ PR #$N review: changes requested
$(echo "$REVIEW" | grep -m1 '^Plan fidelity:')
$(gh pr view "$N" --json url --jq .url)" || true
  else
    gh pr edit "$N" --add-label "$PASS_LABEL" >/dev/null
    echo "[review] #$N passed"
  fi
done
echo "[review] done"
