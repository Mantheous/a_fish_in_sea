#!/usr/bin/env bash
# Collect Telegram inline-button presses (and 👍/👎 reactions) on plan
# messages and record them as `approve` / `deny` GitHub issue comments.
# Polled from poll.sh right before the approve step, so a button press
# flows through the normal approve path (verified tester, plan marker,
# no unaddressed feedback) on the same cycle. Safe to re-run.
#
# Auth: only presses/reactions from the configured chat/user
# ($TELEGRAM_OPENCODE_CHAT_ID) are honored; everything else is ignored.
# Read-only except: GitHub comments + Telegram answerCallbackQuery /
# reply-markup removal + the updates offset file. Never touches code.
set -euo pipefail
ENV_FILE="$HOME/.config/opencode-telegram/bot.env"
OFFSET_FILE="$HOME/.config/opencode-telegram/updates.offset"
TOKEN="${TELEGRAM_OPENCODE_BOT_TOKEN:-}"
CHAT="${TELEGRAM_OPENCODE_CHAT_ID:-}"
if [ -z "$TOKEN" ] && [ -f "$ENV_FILE" ]; then
  TOKEN="$(grep -E '^TELEGRAM_OPENCODE_BOT_TOKEN=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d ' ')"
fi
if [ -z "$CHAT" ] && [ -f "$ENV_FILE" ]; then
  CHAT="$(grep -E '^TELEGRAM_OPENCODE_CHAT_ID=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d ' ' || true)"
fi
if [ -z "$TOKEN" ]; then echo "tg-callbacks: no bot token" >&2; exit 1; fi
if [ -z "$CHAT" ]; then echo "tg-callbacks: no chat id" >&2; exit 1; fi
OFFSET="0"
[ -f "$OFFSET_FILE" ] && OFFSET="$(cat "$OFFSET_FILE" | tr -d ' ' || echo 0)"
python3 - "$TOKEN" "$CHAT" "$OFFSET" "$OFFSET_FILE" <<'EOF'
import json, os, subprocess, sys, urllib.request
token, chat, offset, offset_file = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
MAP_FILE = os.path.expanduser("~/.config/opencode-telegram/plan-messages.json")


def api(method, payload, timeout=20):
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/{method}",
        data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as res:
        body = json.load(res)
    if not body.get("ok"):
        raise RuntimeError(f"{method} failed: {body}")
    return body["result"]


def gh(*args):
    return subprocess.run(["gh", *args], capture_output=True, text=True, timeout=60)


def answer(cq_id, text):
    try:
        api("answerCallbackQuery", {"callback_query_id": cq_id, "text": text[:190]})
    except Exception as e:  # noqa: BLE001
        print(f"[tg-callbacks] answer failed: {e}", file=sys.stderr)


def disarm(chat_id, message_id):
    # Remove the buttons so a decided plan can't be pressed twice.
    # Best-effort: a failure here never blocks the approval itself.
    try:
        api("editMessageReplyMarkup",
            {"chat_id": chat_id, "message_id": message_id,
             "reply_markup": {"inline_keyboard": []}})
    except Exception as e:  # noqa: BLE001
        print(f"[tg-callbacks] disarm failed: {e}", file=sys.stderr)


def plan_state(n):
    """Mirror of approve.sh's gate: is #n awaiting a decision, and is there
    unaddressed human feedback after the latest plan?"""
    r = gh("issue", "view", str(n), "--json", "state,labels,comments")
    if r.returncode != 0:
        return ("error", f"gh hiccup ({r.stderr.strip()[:100]})")
    try:
        meta = json.loads(r.stdout)
    except json.JSONDecodeError:
        return ("error", "gh hiccup (bad json)")
    if meta.get("state") != "OPEN":
        return ("stale", "issue is closed")
    labels = [lbl["name"] for lbl in meta.get("labels", [])]
    if "agent-pending" not in labels:
        return ("stale", "already decided")
    comments = meta.get("comments", [])
    last_plan = max(
        (i for i, c in enumerate(comments) if "<!-- agent-plan" in (c.get("body") or "")),
        default=-1,
    )
    if last_plan < 0:
        return ("stale", "no plan posted yet")
    feedback = 0
    for c in comments[last_plan + 1:]:
        body = (c.get("body") or "")
        s = body.strip().lower()
        if "<!-- agent-" in body:
            continue
        if s.startswith(("approved by @", "denied by", "not a verified tester", "ux walk")):
            continue
        first = body.strip().splitlines()[0].strip().lower() if body.strip() else ""
        if first == "approve" or "agent approved" in first or first.startswith("deny"):
            continue
        feedback += 1
    if feedback > 0:
        return ("feedback", f"{feedback} unaddressed comment(s) — wait for the revised plan")
    return ("ready", "")


def record_approve(n):
    r = gh("issue", "comment", str(n), "--body", "approve\n\n(via Telegram)")
    if r.returncode != 0:
        return f"could not record (gh hiccup) — retrying next poll"
    return f"Approved #{n} — builder picks it up next poll"


def record_deny(n):
    r = gh("issue", "comment", str(n), "--body", "deny via Telegram")
    if r.returncode != 0:
        return f"could not record (gh hiccup) — retrying next poll"
    return f"Denied #{n} (via Telegram)"


try:
    updates = api("getUpdates", {"offset": int(offset), "limit": 100,
                                 "timeout": 0,
                                 "allowed_updates": ["callback_query", "message_reaction"]})
except Exception as e:  # noqa: BLE001
    print(f"[tg-callbacks] getUpdates failed: {e}", file=sys.stderr)
    sys.exit(0)  # transient network — next poll retries; never fail the cycle

mapping = {}
if os.path.exists(MAP_FILE):
    try:
        with open(MAP_FILE) as f:
            mapping = json.load(f)
    except (json.JSONDecodeError, OSError):
        pass

next_offset = int(offset)
APPROVE_EMOJI = {"👍", "❤", "🎉", "🔥"}
DENY_EMOJI = {"👎"}

for u in updates:
    uid = u["update_id"]
    handled = True
    if "callback_query" in u:
        cq = u["callback_query"]
        data = cq.get("data", "")
        from_id = str((cq.get("from") or {}).get("id", ""))
        msg = cq.get("message") or {}
        chat_id = (msg.get("chat") or {}).get("id", "")
        message_id = msg.get("message_id")
        action, _, num = data.partition(":")
        if from_id != str(chat) and str(chat_id) != str(chat):
            answer(cq["id"], "Not authorized for this bot")
        elif action not in ("approve", "deny") or not num.isdigit():
            pass  # unknown button — ignore
        else:
            n = int(num)
            if action == "approve":
                state, detail = plan_state(n)
                if state == "ready":
                    msg_text = record_approve(n)
                    if message_id:
                        disarm(chat_id, message_id)
                elif state == "feedback":
                    msg_text = f"#{n}: {detail}"
                else:
                    msg_text = f"#{n}: {detail} — ignoring"
                    if message_id and state == "stale":
                        disarm(chat_id, message_id)
                answer(cq["id"], msg_text)
                print(f"[tg-callbacks] approve-btn #{n} from {from_id}: {msg_text}")
            else:
                state, detail = plan_state(n)
                if state == "error":
                    answer(cq["id"], f"#{n}: {detail} — retrying next poll")
                    break  # keep offset so this press is retried
                msg_text = record_deny(n)
                if message_id:
                    disarm(chat_id, message_id)
                answer(cq["id"], msg_text)
                print(f"[tg-callbacks] deny-btn #{n} from {from_id}: {msg_text}")
    elif "message_reaction" in u:
        mr = u["message_reaction"]
        user = mr.get("user") or mr.get("actor_chat") or {}
        reactor = str(user.get("id", ""))
        mid = str(mr.get("message_id", ""))
        added = {(r.get("emoji")) for r in (mr.get("new_reaction") or []) if r.get("emoji")}
        if reactor != str(chat):
            pass  # someone else's reaction — ignore
        elif mid not in mapping:
            pass  # not a plan message we sent — ignore
        elif added & APPROVE_EMOJI:
            n = int(mapping[mid])
            state, detail = plan_state(n)
            if state == "ready":
                print(f"[tg-callbacks] reaction-approve #{n}: {record_approve(n)}")
            else:
                print(f"[tg-callbacks] reaction-approve #{n} held: {detail}")
        elif added & DENY_EMOJI:
            n = int(mapping[mid])
            print(f"[tg-callbacks] reaction-deny #{n}: {record_deny(n)}")
    else:
        pass
    next_offset = uid + 1

with open(offset_file, "w") as f:
    f.write(str(next_offset))
print(f"[tg-callbacks] processed {len(updates)} update(s), offset -> {next_offset}")
EOF
