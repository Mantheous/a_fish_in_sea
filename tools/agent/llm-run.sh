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
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
fi

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

while [ $# -gt 0 ]; do
  case "$1" in
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
# the Playwright MCP server. Review + the guardians are text-only, read-only
# roles — the fit for codex.
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
  *) echo "[llm-run] $ROLE: unsupported backend '$BACKEND'" >&2; exit 2 ;;
esac

# The systemd timer's PATH does not include ~/.local/bin, where the codex
# symlink lives. Resolve the binary without relying on the service PATH.
resolve_bin() { # name override
  local name="$1" override="${2:-}" cand
  if [ -n "$override" ]; then
    [ -x "$override" ] && { printf '%s\n' "$override"; return 0; }
    return 1
  fi
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  for cand in "$HOME/.local/bin/$name" "$HOME/.opencode/bin/$name" \
              "/usr/local/bin/$name" "/usr/bin/$name"; do
    [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

CODEX_BIN=""
OPENCODE_BIN=""
if [ "$BACKEND" = "codex" ]; then
  CODEX_BIN="$(resolve_bin codex "${FISH_LLM_CODEX_BIN:-}" || true)"
  if [ -z "$CODEX_BIN" ]; then
    echo "[llm-run] $ROLE: codex binary not found (PATH, ~/.local/bin, ~/.opencode/bin, /usr/local/bin, /usr/bin); set FISH_LLM_CODEX_BIN" >&2
    exit 2
  fi
else
  OPENCODE_BIN="$(resolve_bin opencode "${FISH_LLM_OPENCODE_BIN:-}" || true)"
  if [ -z "$OPENCODE_BIN" ]; then
    echo "[llm-run] $ROLE: opencode binary not found (PATH, ~/.local/bin, ~/.opencode/bin, /usr/local/bin, /usr/bin); set FISH_LLM_OPENCODE_BIN" >&2
    exit 2
  fi
fi

MODEL="${MODEL:-${!MODEL_VAR:-$BASE_MODEL}}"
TIMEOUT="${TIMEOUT:-${!TIMEOUT_VAR:-$DEFAULT_TIMEOUT}}"
AGENT="${AGENT:-$DEFAULT_AGENT}"

[ -n "$TITLE" ] || TITLE="$ROLE"
if ! [[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  echo "[llm-run] $ROLE: --timeout must be a positive integer (seconds)" >&2
  exit 2
fi

# ── Prompt assembly ─────────────────────────────────────────────────────
PROMPT_FILE="$(mktemp)"
MSG_FILE="$(mktemp)"
OUT_FILE="$(mktemp)"
ERR_FILE="$(mktemp)"
LAST_FILE="$(mktemp)"
FULL_PROMPT="$(mktemp)"
cleanup() { rm -f "$PROMPT_FILE" "$MSG_FILE" "$OUT_FILE" "$ERR_FILE" "$LAST_FILE" "$FULL_PROMPT"; }
trap cleanup EXIT

cat >"$PROMPT_FILE"
if [ ! -s "$PROMPT_FILE" ]; then
  echo "[llm-run] $ROLE: empty prompt on stdin" >&2
  exit 2
fi
cp "$PROMPT_FILE" "$FULL_PROMPT"

# opencode applies a role's .md via --agent; codex has no equivalent, so
# inline the same instructions (minus YAML frontmatter) ahead of the prompt.
if [ -n "$AGENT" ] && [ "$BACKEND" = "codex" ]; then
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
    cat "$PROMPT_FILE"
  } >"$FULL_PROMPT"
fi

# ── Read-only verification ──────────────────────────────────────────────
# The codex read-only sandbox should already block writes; verify it rather
# than trust it, and catch an opencode fallback that ignores the prompt.
TREE_BEFORE=""
if [ "$READ_ONLY" = "1" ]; then
  TREE_BEFORE="$(git -C "$PWD" status --porcelain=v1 --untracked-files=all 2>/dev/null || echo "__NO_GIT__")"
fi

START_TS="$(date +%s)"
set +e
if [ "$BACKEND" = "codex" ]; then
  CODEX_ARGS=(
    exec
    -C "$PWD"
    -s "$DEFAULT_SANDBOX"
    -m "$MODEL"
    -c "model_reasoning_effort=$CODEX_EFFORT"
    -o "$LAST_FILE"
    -
  )
  timeout "$TIMEOUT" "$CODEX_BIN" "${CODEX_ARGS[@]}" <"$FULL_PROMPT" >"$OUT_FILE" 2>"$ERR_FILE"
  ST=$?
else
  OPENCODE_ARGS=(run)
  [ "$DEFAULT_AUTO" = "1" ] && OPENCODE_ARGS+=(--auto)
  [ -n "$AGENT" ] && OPENCODE_ARGS+=(--agent "$AGENT")
  OPENCODE_ARGS+=(--model "$MODEL" --title "$TITLE")
  timeout "$TIMEOUT" "$OPENCODE_BIN" "${OPENCODE_ARGS[@]}" "$(cat "$FULL_PROMPT")" \
    </dev/null >"$OUT_FILE" 2>"$ERR_FILE"
  ST=$?
fi
set -e
ELAPSED="$(( $(date +%s) - START_TS ))"

if [ "$ST" -ne 0 ]; then
  echo "[llm-run] $ROLE ($BACKEND/$MODEL) failed exit=$ST after ${ELAPSED}s" >&2
  tail -n 20 "$ERR_FILE" >&2 || true
  exit "$ST"
fi

if [ "$BACKEND" = "codex" ]; then
  tr -d '\r' <"$LAST_FILE" >"$MSG_FILE" || true
else
  tr -d '\r' <"$OUT_FILE" >"$MSG_FILE" || true
fi

if [ ! -s "$MSG_FILE" ]; then
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
