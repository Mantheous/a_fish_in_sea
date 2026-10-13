#!/usr/bin/env bash
# Builder dispatcher: for each open agent-approved issue without a branch/PR,
# launch a detached tmux session running builder-run.sh. Safe to re-run.
set -euo pipefail
REPO="$HOME/Repos/a_fish_in_sea"
cd "$REPO"
DIR="$REPO/tools/agent"

COUNT="$(gh issue list --label agent-approved --state open --limit 20 --json number \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
echo "[build] agent-approved open: $COUNT"
[ "$COUNT" = "0" ] && exit 0

gh issue list --label agent-approved --state open --limit 20 --json number,title \
  | python3 -c 'import json,sys; [print(i["number"]) for i in json.load(sys.stdin)]' | while read -r N; do
  if tmux has-session -t "agent-$N" 2>/dev/null; then
    echo "[build] #$N tmux session agent-$N already running — skipping"
    continue
  fi
  TITLE="$(gh issue view "$N" --json title --jq .title)"
  SLUG="$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\+/-/g' | cut -c1-40 | sed 's/-$//')"
  if git ls-remote --heads origin "agent/$N-$SLUG" | grep -q .; then
    if gh pr list --head "agent/$N-$SLUG" --state open --limit 1 --json number \
      --jq '.[0].number // empty' 2>/dev/null | grep -q .; then
      echo "[build] #$N branch already pushed — skipping (PR presumably open)"
    else
      echo "[build] #$N branch pushed but NO open PR — stuck, needs a human (open a PR or delete the branch; close.sh reports this too)"
    fi
    continue
  fi
  echo "[build] #$N launching tmux session agent-$N"
  tmux new-session -d -s "agent-$N" "$DIR/builder-run.sh $N"
done
echo "[build] done"
