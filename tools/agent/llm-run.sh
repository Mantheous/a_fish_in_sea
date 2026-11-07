#!/usr/bin/env bash
# Single entry point for every headless LLM call in the agent loop.
#
# The loop's correctness lives in GitHub labels/comments, git, and tmux —
# not in the model vendor. Callers pass a ROLE, a prompt on stdin, and an
# output contract (--expect), and get exactly the model's final message on
# stdout. Backend selection is the ROLE table below; flip a role without
# editing any script:
#
#   FISH_LLM_REVIEW_BACKEND=opencode tools/agent/review.sh
#   # or persistently, outside the repo:
#   echo 'FISH_LLM_REVIEW_BACKEND=opencode' >> ~/.config/a_fish_in_sea/llm-backends.env
#
# Usage:
#   printf '%s' "$PROMPT" | tools/agent/llm-run.sh --role review \
#       --title "review-42" --expect '^Verdict: (pass|changes-requested)$'
#
# Contract enforcement is fail-closed: a non-zero child exit, empty final
# message, or output that does not match --expect exits non-zero and emits
# nothing on stdout, so a caller can never mistake "model produced nothing"
# for a passing verdict.
#
# Exit codes: 0 ok · 2 usage/setup · 3 empty or contract-mismatched output
#             4 --read-only run changed the working tree · 124 timeout.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"

# Optional per-host overrides, outside the repo so they never dirty main.
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/a_fish_in_sea/llm-backends.env"
# Caller exports (including the poll's capacity plan) take precedence over
# host defaults. Re-sourcing the config must not undo adaptive routing.
declare -A INHERITED=()
while IFS= read -r key; do
  case "$key" in FISH_LLM_*) INHERITED["$key"]="${!key}" ;; esac
done < <(compgen -e)
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
fi
for key in "${!INHERITED[@]}"; do
  export "$key=${INHERITED[$key]}"
done

CODEX_MODEL="${FISH_LLM_CODEX_MODEL:-gpt-6.1-sol}"
CODEX_EFFORT="${FISH_LLM_CODEX_EFFORT:-high}"
OPENCODE_CHEAP_MODEL="${FISH_LLM_OPENCODE_CHEAP_MODEL:-opencode-go/muse-spark-1.3-contributor#xhigh}"
OPENCODE_DATA_MODEL="${FISH_LLM_OPENCODE_DATA_MODEL:-opencode-go/deepseek-v4.1-flash#high}"
OPENCODE_SEC_MODEL="${FISH_LLM_OPENCODE_SEC_MODEL:-opencode-go/claude-haiku-5-5}"
OPENCODE_UX_MODEL="${FISH_LLM_OPENCODE_UX_MODEL:-opencode-go/gpt-6-luna#xhigh}"

usage() {
  sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

ROLE=""
TITLE=""
EXPECT=""
AGENT=""
MODEL=""
TIMEOUT=""
READ_ONLY=0
TIER=0

while [ $# -gt 0 ]; do
  case "$1" in
    --tier) TIER="${2:-}"; shift 2 ;;
    --role) ROLE="${2:-}"; shift 2 ;;
    --title) TITLE="${2:-}"; shift 2 ;;
    --expect) EXPECT="${2:-}"; shift 2 ;;
    --agent) AGENT="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --read-only) READ_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[llm-run] unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$ROLE" ] || { echo "[llm-run] --role is required" >&2; exit 2; }

# ── Role table ──────────────────────────────────────────────────────────
# backend | per-backend model | agent | auto | timeout (s)
# Vision-heavy and long-running roles stay on opencode: triage reads issue
# screenshots, builders/rework attach review screenshots, and ux-walk drives
# the Playwright MCP server. Review, the security guardian and proactive
# discovery are text-only, read-only roles — the fit for codex.
DEFAULT_BACKEND="opencode"
DEFAULT_CODEX_MODEL="$CODEX_MODEL"
DEFAULT_OPENCODE_MODEL="$OPENCODE_CHEAP_MODEL"
DEFAULT_AGENT=""
DEFAULT_AUTO=0
DEFAULT_SANDBOX="read-only"
DEFAULT_TIMEOUT=1800

case "$ROLE" in
  review)
    DEFAULT_BACKEND="codex"
    ;;
  discover|harness)
    # Proactive issue discovery: read-only repo audit, text-only. Files at
    # most a couple of issues per run via tools/agent/discover.sh.
    DEFAULT_BACKEND="codex"
    DEFAULT_TIMEOUT=1800
    ;;
  usage)
    # Proactive usage review: read-only analysis of the content-free event
    # log, text-only. Files at most a couple of issues per run via
    # tools/agent/usage-review.sh; removal candidates are held for a human
    # merge. Codex/sol is used because this is a judgment-heavy audit.
    DEFAULT_BACKEND="codex"
    DEFAULT_TIMEOUT=1800
    ;;
  security-guard)
    DEFAULT_BACKEND="codex"
    DEFAULT_AGENT="security-guardian"
    ;;
  data-guard)
    DEFAULT_BACKEND="opencode"
    DEFAULT_OPENCODE_MODEL="$OPENCODE_DATA_MODEL"
    DEFAULT_AGENT="data-guardian"
    ;;
  triage)
    DEFAULT_OPENCODE_MODEL="$OPENCODE_CHEAP_MODEL"
    ;;
  builder|rework)
    DEFAULT_OPENCODE_MODEL="$OPENCODE_CHEAP_MODEL"
    DEFAULT_AUTO=1
    DEFAULT_TIMEOUT=10800
    DEFAULT_SANDBOX="workspace-write"
    ;;
  ux-walk)
    DEFAULT_OPENCODE_MODEL="$OPENCODE_UX_MODEL"
    DEFAULT_AGENT="ux-walker"
    DEFAULT_TIMEOUT=3600
    ;;
  *)
    echo "[llm-run] unknown role: $ROLE" >&2
    exit 2
    ;;
esac

ROLE_KEY="$(printf '%s' "$ROLE" | tr '[:lower:]-' '[:upper:]_')"
BACKEND_VAR="FISH_LLM_${ROLE_KEY}_BACKEND"
MODEL_VAR="FISH_LLM_${ROLE_KEY}_MODEL"
TIMEOUT_VAR="FISH_LLM_${ROLE_KEY}_TIMEOUT"
BACKEND="${!BACKEND_VAR:-$DEFAULT_BACKEND}"
case "$BACKEND" in
  codex) BASE_MODEL="$DEFAULT_CODEX_MODEL" ;;
  opencode) BASE_MODEL="$DEFAULT_OPENCODE_MODEL" ;;
  antigravity) BASE_MODEL="${FISH_LLM_AGY_MODEL:-gemini-3.8-flash-high}" ;;
  *) echo "[llm-run] $ROLE: unsupported backend '$BACKEND'" >&2; exit 2 ;;
esac

# Tiers deliberately override ordinary per-role routing. After two completed
# reworks, use the strongest installed model with deeper reasoning. Models
# can be changed per host without changing callers or silently downgrading.
[[ "$TIER" =~ ^[012]$ ]] || { echo "[llm-run] tier must be 0, 1 or 2" >&2; exit 2; }
MODEL="${MODEL:-${!MODEL_VAR:-$BASE_MODEL}}"
if [ "$TIER" -gt 0 ]; then
  BACKEND="${FISH_LLM_ESCALATION_BACKEND:-codex}"
  MODEL="${FISH_LLM_ESCALATION_MODEL:-gpt-6.1-sol}"
  CODEX_EFFORT=xhigh
  [ "$TIER" -eq 2 ] && CODEX_EFFORT=max
fi
TIMEOUT="${TIMEOUT:-${!TIMEOUT_VAR:-$DEFAULT_TIMEOUT}}"
AGENT="${AGENT:-$DEFAULT_AGENT}"
[ -n "$TITLE" ] || TITLE="$ROLE"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { echo "[llm-run] timeout must be positive" >&2; exit 2; }

resolve_bin() {
  local name="$1" override="${2:-}" cand
  if [ -n "$override" ]; then
    [ -x "$override" ] && { printf '%s\n' "$override"; return; }
    return 1
  fi
  command -v "$name" 2>/dev/null && return
  for cand in "$HOME/.local/bin/$name" "$HOME/.opencode/bin/$name" "/usr/local/bin/$name" "/usr/bin/$name"; do
    [ -x "$cand" ] && { printf '%s\n' "$cand"; return; }
  done
  return 1
}
CODEX_BIN="$(resolve_bin codex "${FISH_LLM_CODEX_BIN:-}" || true)"
OPENCODE_BIN="$(resolve_bin opencode "${FISH_LLM_OPENCODE_BIN:-}" || true)"
AGY_BIN="$(resolve_bin agy "${FISH_LLM_AGY_BIN:-}" || true)"
case "$BACKEND" in
  codex) BIN="$CODEX_BIN" ;;
  opencode) BIN="$OPENCODE_BIN" ;;
  antigravity) BIN="$AGY_BIN" ;;
  *) echo "[llm-run] unsupported escalation backend" >&2; exit 2 ;;
esac
[ -n "$BIN" ] || { echo "[llm-run] $BACKEND binary not found" >&2; exit 2; }
POOL="$(python3 - "$SELF_DIR" "$BACKEND" "$MODEL" <<'POOL_PY'
import sys
sys.path.insert(0, sys.argv[1])
from capacity import pool_for
print(pool_for(sys.argv[2], sys.argv[3]))
POOL_PY
)"
if ! python3 "$SELF_DIR/capacity.py" allow --pool "$POOL" --role "$ROLE"; then
  echo "[llm-run] $POOL allowance reserved or cooling down; retry next poll" >&2
  exit 75
fi

# ── Codex sandbox health (fail closed) ──────────────────────────────────
# Codex runs model-generated shell commands inside bubblewrap. On a host
# where unprivileged user namespaces are blocked (Ubuntu 24.04 AppArmor
# default: kernel.apparmor_restrict_unprivileged_userns=1) every shell call
# fails with "bwrap: ... Operation not permitted". The model can still emit
# a plausible final message, so a review would "pass" without ever reading
# the diff. Probe cheaply and refuse to run instead of trusting that output.
codex_sandbox_ok() {
  [ "$(uname -s 2>/dev/null || echo unknown)" = "Linux" ] || return 0
  if command -v bwrap >/dev/null 2>&1; then
    timeout 5 bwrap --ro-bind / / true >/dev/null 2>&1 && return 0
    return 1
  fi
  if command -v unshare >/dev/null 2>&1; then
    timeout 5 unshare -Ur true >/dev/null 2>&1 && return 0
    return 1
  fi
  return 0  # cannot probe on this host; do not block
}
if [ "$BACKEND" = "codex" ] && [ "$DEFAULT_SANDBOX" != "danger-full-access" ] \
  && [ "${FISH_LLM_CODEX_SANDBOX_CHECK:-1}" != "0" ] && ! codex_sandbox_ok; then
  echo "[llm-run] $ROLE: codex sandbox cannot start on this host — failing closed." >&2
  echo "[llm-run] A tool-less model can emit a plausible verdict without reading anything; refusing to run." >&2
  echo "[llm-run] Fix: sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0" >&2
  echo "[llm-run] (or set FISH_LLM_CODEX_SANDBOX_CHECK=0 only if you have verified the sandbox another way)" >&2
  exit 2
fi

# ── Prompt assembly ─────────────────────────────────────────────────────
PROMPT_FILE="$(mktemp)"
MSG_FILE="$(mktemp)"
OUT_FILE="$(mktemp)"
ERR_FILE="$(mktemp)"
LAST_FILE="$(mktemp)"
FULL_PROMPT="$(mktemp)"
START_TS="$(date +%s)"
cleanup() {
  local result=$? limited=()
  if [ "$result" -ne 0 ] && grep -qiE 'rate.limit.exceeded|rate_limit|http 429|too many requests|quota.exhausted|usage.limit' "$ERR_FILE" "$OUT_FILE"; then
    limited=(--limited)
  fi
  python3 "$SELF_DIR/llm_metrics.py" record --role "$ROLE" --backend "$BACKEND" \
    --model "$MODEL" --tier "$TIER" --seconds "$(( $(date +%s) - START_TS ))" \
    --exit "$result" --output "$OUT_FILE" "${limited[@]}" >/dev/null 2>&1 || true
  rm -f "$PROMPT_FILE" "$MSG_FILE" "$OUT_FILE" "$ERR_FILE" "$LAST_FILE" "$FULL_PROMPT"; }
trap cleanup EXIT

cat >"$PROMPT_FILE"
if [ ! -s "$PROMPT_FILE" ]; then
  echo "[llm-run] $ROLE: empty prompt on stdin" >&2
  exit 2
fi
# Every role sees the current doc map, including proposals and escalations.
# Keep it outside the task prose so it is not lost when a fresh agent starts.
python3 "$SELF_DIR/feature_docs.py" "$REPO_ROOT" >"$FULL_PROMPT"
cat "$PROMPT_FILE" >>"$FULL_PROMPT"

# opencode applies a role's .md via --agent; codex has no equivalent, so
# inline the same instructions (minus YAML frontmatter) ahead of the prompt.
if [ -n "$AGENT" ] && [ "$BACKEND" != "opencode" ]; then
  AGENT_FILE="$REPO_ROOT/.opencode/agents/$AGENT.md"
  if [ ! -f "$AGENT_FILE" ]; then
    echo "[llm-run] $ROLE: agent instructions not found: $AGENT_FILE" >&2
    exit 2
  fi
  {
    awk 'BEGIN { fm = 0 }
         NR == 1 && $0 == "---" { fm = 1; next }
         fm == 1 && $0 == "---" { fm = 0; next }
         fm == 0 { print }' "$AGENT_FILE"
    printf '\n---\n\n'
    cat "$FULL_PROMPT"
  } >"$MSG_FILE"
  cp "$MSG_FILE" "$FULL_PROMPT"
fi

# ── Read-only verification ──────────────────────────────────────────────
# The codex read-only sandbox should already block writes; verify it rather
# than trust it, and catch an opencode fallback that ignores the prompt.
TREE_BEFORE=""
if [ "$READ_ONLY" = "1" ]; then
  TREE_BEFORE="$(git -C "$PWD" status --porcelain=v1 --untracked-files=all 2>/dev/null || echo "__NO_GIT__")"
fi

START_TS="$(date +%s)"
python3 "$SELF_DIR/llm_metrics.py" start --role "$ROLE" --backend "$BACKEND" --model "$MODEL" >/dev/null 2>&1 || true
set +e
if [ "$BACKEND" = "codex" ]; then
  CODEX_ARGS=(
    exec --json
    -C "$PWD"
    -s "$DEFAULT_SANDBOX"
    -m "$MODEL"
    -c "model_reasoning_effort=$CODEX_EFFORT"
    -o "$LAST_FILE"
    -
  )
  # Codex's workspace-write sandbox only writes under its cwd by default.
  # A builder works in a linked git worktree, so commits need the exact
  # git dir (outside cwd), and flutter test needs the SDK/pub/telemetry
  # caches. Network access is required for git push / gh pr create.
  if [ "$DEFAULT_SANDBOX" = "workspace-write" ]; then
    CODEX_ARGS+=(-c "sandbox_workspace_write.network_access=true")
    WRITABLE_ROOTS=()
    GIT_DIR_ABS="$(git -C "$PWD" rev-parse --absolute-git-dir 2>/dev/null || true)"
    [ -n "$GIT_DIR_ABS" ] && [ -d "$GIT_DIR_ABS" ] && WRITABLE_ROOTS+=("$GIT_DIR_ABS")
    # A linked worktree's objects/refs live in the COMMON git dir, outside
    # the per-worktree git dir. Without it codex can create a file but
    # `git commit` hits a read-only objects dir.
    GIT_COMMON_ABS="$(git -C "$PWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    case "$GIT_COMMON_ABS" in
      /*) ;;
      *) GIT_COMMON_ABS="$PWD/${GIT_COMMON_ABS:-}" ;;
    esac
    if [ -n "$GIT_COMMON_ABS" ] && [ -d "$GIT_COMMON_ABS" ] && [ "$GIT_COMMON_ABS" != "$GIT_DIR_ABS" ]; then
      WRITABLE_ROOTS+=("$GIT_COMMON_ABS")
    fi
    for dir in "$HOME/flutter" "$HOME/.pub-cache" "$HOME/.dart-tool" "$HOME/.cache"; do
      [ -n "$dir" ] && [ -d "$dir" ] && WRITABLE_ROOTS+=("$dir")
    done
    if [ "${#WRITABLE_ROOTS[@]}" -gt 0 ]; then
      ROOTS_JSON="$(printf '"%s", ' "${WRITABLE_ROOTS[@]}" | sed 's/, $//')"
      CODEX_ARGS+=(-c "sandbox_workspace_write.writable_roots=[$ROOTS_JSON]")
    fi
  fi
  timeout "$TIMEOUT" "$CODEX_BIN" "${CODEX_ARGS[@]}" <"$FULL_PROMPT" >"$OUT_FILE" 2>"$ERR_FILE"
  ST=$?
elif [ "$BACKEND" = "antigravity" ]; then
  AGY_MODE=plan
  [ "$DEFAULT_SANDBOX" = "workspace-write" ] && AGY_MODE=auto
  AGY_ARGS=(--model "$MODEL" --effort "${FISH_LLM_AGY_EFFORT:-high}"
    --sandbox --mode "$AGY_MODE" --output-format json
    --settings '{"useG1Credits":false,"toolPermission":"proceed-in-sandbox","artifactReviewPolicy":"always-proceed"}')
  # Linked worktrees need their shared Git metadata and Flutter caches.
  if [ "$AGY_MODE" = auto ]; then
    for dir in "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" "$HOME/flutter" "$HOME/.pub-cache"; do
      [ -d "$dir" ] && AGY_ARGS+=(--add-dir "$dir")
    done
  fi
  timeout "$TIMEOUT" "$AGY_BIN" "${AGY_ARGS[@]}" --print "$(cat "$FULL_PROMPT")" \
    </dev/null >"$OUT_FILE" 2>"$ERR_FILE"
  ST=$?
else
  OPENCODE_ARGS=(run --format json)
  [ "$DEFAULT_AUTO" = "1" ] && OPENCODE_ARGS+=(--auto)
  [ -n "$AGENT" ] && OPENCODE_ARGS+=(--agent "$AGENT")
  OPENCODE_ARGS+=(--model "$MODEL" --title "$TITLE")
  timeout "$TIMEOUT" "$OPENCODE_BIN" "${OPENCODE_ARGS[@]}" "$(cat "$FULL_PROMPT")" \
    </dev/null >"$OUT_FILE" 2>"$ERR_FILE"
  ST=$?
fi
set -e
ELAPSED="$(( $(date +%s) - START_TS ))"

# Keep codex's full transcript for debugging builder runs. The caller only
# gets the final message on stdout, which is too little to diagnose a failed
# build; this file has every tool call. Best-effort: never fail the run for it.
if [ "$BACKEND" = "codex" ] && [ -n "${FISH_LLM_TRANSCRIPT:-}" ]; then
  {
    cat "$OUT_FILE" 2>/dev/null || true
    if [ -s "$ERR_FILE" ]; then
      printf '\n--- codex stderr ---\n'
      cat "$ERR_FILE" 2>/dev/null || true
    fi
  } >>"$FISH_LLM_TRANSCRIPT" 2>/dev/null || true
fi

if [ "$ST" -ne 0 ]; then
  echo "[llm-run] $ROLE ($BACKEND/$MODEL) failed exit=$ST after ${ELAPSED}s" >&2
  tail -n 20 "$ERR_FILE" >&2 || true
  exit "$ST"
fi

if [ "$BACKEND" = "codex" ]; then
  tr -d '\r' <"$LAST_FILE" >"$MSG_FILE" || true
else
  python3 "$SELF_DIR/llm_output.py" "$BACKEND" "$OUT_FILE" >"$MSG_FILE" || exit 3
fi

if ! grep -q '[^[:space:]]' "$MSG_FILE"; then
  echo "[llm-run] $ROLE ($BACKEND/$MODEL) produced an empty final message after ${ELAPSED}s (fail-closed)" >&2
  tail -n 20 "$ERR_FILE" >&2 || true
  exit 3
fi

if [ -n "$EXPECT" ] && ! grep -Eq "$EXPECT" "$MSG_FILE"; then
  echo "[llm-run] $ROLE ($BACKEND/$MODEL) output did not match /$EXPECT/ (fail-closed)" >&2
  sed -n '1,40p' "$MSG_FILE" >&2
  exit 3
fi

if [ "$READ_ONLY" = "1" ]; then
  TREE_AFTER="$(git -C "$PWD" status --porcelain=v1 --untracked-files=all 2>/dev/null || echo "__NO_GIT__")"
  if [ "$TREE_AFTER" != "$TREE_BEFORE" ]; then
    echo "[llm-run] $ROLE ($BACKEND/$MODEL) modified the working tree during a read-only run (fail-closed)" >&2
    echo "--- before" >&2
    printf '%s\n' "$TREE_BEFORE" >&2
    echo "--- after" >&2
    printf '%s\n' "$TREE_AFTER" >&2
    exit 4
  fi
fi

cat "$MSG_FILE"
if [ -n "$(tail -c 1 "$MSG_FILE" 2>/dev/null || true)" ]; then
  printf '\n'
fi
echo "[llm-run] $ROLE backend=$BACKEND model=$MODEL output=$(wc -c <"$MSG_FILE")b secs=$ELAPSED" >&2
