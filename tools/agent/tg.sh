#!/usr/bin/env bash
# Send a Telegram message via the existing opencode bot. Usage: tg.sh "<text>"
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
[ -z "$CHAT" ] && CHAT="8474661718"
if [ -z "$TOKEN" ]; then echo "tg: no bot token" >&2; exit 1; fi
[ $# -ge 1 ] || { echo "usage: tg.sh <text>" >&2; exit 1; }
python3 - "$TOKEN" "$CHAT" "$1" <<'EOF'
import json, sys, urllib.request
token, chat, text = sys.argv[1], sys.argv[2], sys.argv[3]
payload = json.dumps({"chat_id": chat, "text": text, "disable_web_page_preview": True}).encode()
req = urllib.request.Request(
    f"https://api.telegram.org/bot{token}/sendMessage",
    data=payload, headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(req, timeout=20) as res:
    body = json.load(res)
    if not body.get("ok"):
        print(f"tg: send failed: {body}", file=sys.stderr)
        sys.exit(1)
    print(f"tg: sent message_id={body['result']['message_id']}")
EOF
