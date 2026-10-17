#!/usr/bin/env bash
# Send a Telegram message via the existing opencode bot.
# Usage: tg.sh [--issue N] "<text>"
#   --issue N attaches Approve / Deny inline buttons to the message
#   (callback_data "approve:N" / "deny:N") so a triage plan can be
#   approved from Telegram. Button presses are collected by
#   tg-callbacks.sh (polled from poll.sh) which records them as
#   `approve` / `deny` issue comments. Plain messages are unchanged.
# Token/chat come from $TELEGRAM_OPENCODE_BOT_TOKEN / $TELEGRAM_OPENCODE_CHAT_ID
# or ~/.config/opencode-telegram/bot.env. Never logs the token.
set -euo pipefail
ENV_FILE="$HOME/.config/opencode-telegram/bot.env"
TOKEN="${TELEGRAM_OPENCODE_BOT_TOKEN:-}"
CHAT="${TELEGRAM_OPENCODE_CHAT_ID:-}"
if [ -z "$TOKEN" ] && [ -f "$ENV_FILE" ]; then
  TOKEN="$(grep -E '^TELEGRAM_OPENCODE_BOT_TOKEN=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d ' ')"
fi
if [ -z "$CHAT" ] && [ -f "$ENV_FILE" ]; then
  CHAT="$(grep -E '^TELEGRAM_OPENCODE_CHAT_ID=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d ' ' || true)"
fi
if [ -z "$TOKEN" ]; then echo "tg: no bot token" >&2; exit 1; fi
if [ -z "$CHAT" ]; then echo "tg: no chat id" >&2; exit 1; fi
ISSUE=""
if [ "${1:-}" = "--issue" ]; then
  ISSUE="${2:-}"
  shift 2
  if ! [[ "$ISSUE" =~ ^[0-9]+$ ]]; then echo "tg: --issue needs a numeric issue" >&2; exit 1; fi
fi
[ $# -ge 1 ] || { echo "usage: tg.sh [--issue N] <text>" >&2; exit 1; }
python3 - "$TOKEN" "$CHAT" "$1" "$ISSUE" <<'EOF'
import json, os, sys, urllib.request
token, chat, text, issue = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
payload = {"chat_id": chat, "text": text, "disable_web_page_preview": True}
if issue:
    payload["reply_markup"] = {"inline_keyboard": [[
        {"text": "Approve", "callback_data": f"approve:{issue}"},
        {"text": "Deny", "callback_data": f"deny:{issue}"},
    ]]}
req = urllib.request.Request(
    f"https://api.telegram.org/bot{token}/sendMessage",
    data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(req, timeout=20) as res:
    body = json.load(res)
    if not body.get("ok"):
        print(f"tg: send failed: {body}", file=sys.stderr)
        sys.exit(1)
    mid = body["result"]["message_id"]
    print(f"tg: sent message_id={mid}")
if issue:
    # Record message_id -> issue so 👍/👎 reactions can also be resolved
    # (see tg-callbacks.sh). Best-effort; a missing map only disables
    # reactions, never buttons (callback_data carries the issue).
    try:
        map_file = os.path.expanduser("~/.config/opencode-telegram/plan-messages.json")
        mapping = {}
        if os.path.exists(map_file):
            with open(map_file) as f:
                mapping = json.load(f)
        mapping[str(mid)] = int(issue)
        while len(mapping) > 200:
            mapping.pop(next(iter(mapping)))
        with open(map_file, "w") as f:
            json.dump(mapping, f)
    except Exception as e:  # noqa: BLE001
        print(f"tg: map save failed (reactions only): {e}", file=sys.stderr)
EOF
