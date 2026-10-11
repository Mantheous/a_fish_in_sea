#!/usr/bin/env bash
# Deploy step of the agent loop: rebuild the Flutter web bundle when the
# source moved, so users at /fish/ actually see merged agent work.
# Safe to re-run: skips when the bundle already matches the source.
# Read-only w.r.t. git history except a fast-forward of a clean main;
# never commits. Build output lives in gitignored build/web (served
# from disk by the API server), state in build/web/.agent-* markers.
set -euo pipefail
REPO="$HOME/Repos/a_fish_in_sea"
cd "$REPO"
DIR="$REPO/tools/agent"
FLUTTER="$HOME/flutter/bin/flutter"
MARKER="build/web/.agent-build-desc"
FAIL_MARKER="build/web/.agent-build-failed-desc"

git fetch origin --quiet 2>&1 | head -n 5 || true

DESC=""
if [ -n "$(git status --porcelain | head -n 20)" ]; then
  # Dirty tree (human iterating): build it, keyed on HEAD + worktree hash
  # so steady state still skips.
  WT_HASH="$(git status --porcelain | sha256sum | cut -c1-16)"
  DESC="worktree-$(git rev-parse HEAD)-$WT_HASH"
else
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$BRANCH" != "main" ]; then
    echo "[deploy] on $BRANCH with clean tree — skipping (main only)"
    exit 0
  fi
  if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
    if ! git merge --ff-only origin/main --quiet; then
      echo "[deploy] main diverged from origin/main — not touching it"
      "$DIR/tg.sh" "⚠️ Web deploy skipped: local main diverged from origin/main" || true
      exit 1
    fi
  fi
  DESC="main-$(git rev-parse HEAD)"
fi

if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$DESC" ] \
    && [ -f build/web/index.html ] \
    && grep -q '<base href="/fish/">' build/web/index.html; then
  echo "[deploy] bundle already matches $DESC — skipping"
  exit 0
fi

# Data guardian gate: data-guard.sh (run earlier in poll.sh) blocks the
# revision when pending changes could break the user's existing data.
BLOCK_MARKER="build/web/.agent-data-blocked"
OVERRIDE=".agent-data-override"
ALERT_MARKER="build/web/.agent-data-alerted"
if [ -f "$BLOCK_MARKER" ] && [ "$(cat "$BLOCK_MARKER")" = "$DESC" ]; then
  if [ -f "$OVERRIDE" ] && { [ ! -s "$OVERRIDE" ] || [ "$(cat "$OVERRIDE")" = "$DESC" ]; }; then
    echo "[deploy] data guardian blocked $DESC but override is present — proceeding"
    [ -s "$OVERRIDE" ] || rm -f "$OVERRIDE" # one-shot empty-file override
  else
    echo "[deploy] data guardian BLOCKED $DESC — not building this revision"
    echo "[deploy] see build/web/.agent-data-report.md; override: touch .agent-data-override"
    if [ ! -f "$ALERT_MARKER" ] || [ "$(cat "$ALERT_MARKER")" != "$DESC" ]; then
      echo "$DESC" > "$ALERT_MARKER"
      "$DIR/tg.sh" "🛑 Web deploy held back by the data guardian ($DESC)
Report: build/web/.agent-data-report.md
Fix the findings or touch .agent-data-override to ship anyway." || true
    fi
    exit 0
  fi
fi

# Data insurance before every deploy: snapshot the sync DB (kept if the
# deploy goes bad; cheap and skipped when nothing changed).
"$DIR/backup-db.sh" || echo "[deploy] backup-db failed (continuing)"

echo "[deploy] rebuilding web bundle for $DESC"
if "$FLUTTER" build web --base-href /fish/ 2>&1 | tail -n 3; then
  if ! grep -q '<base href="/fish/">' build/web/index.html; then
    echo "[deploy] build ok but base href wrong — refusing to mark"
    exit 1
  fi
  echo "$DESC" >"$MARKER"
  rm -f "$FAIL_MARKER"
  echo "[deploy] done $DESC"
  "$DIR/tg.sh" "🚀 Web app rebuilt ($DESC) — hard-refresh /fish/ to see it" || true
else
  echo "[deploy] flutter build failed for $DESC"
  if [ ! -f "$FAIL_MARKER" ] || [ "$(cat "$FAIL_MARKER")" != "$DESC" ]; then
    echo "$DESC" >"$FAIL_MARKER"
    "$DIR/tg.sh" "🔥 Web build FAILED ($DESC) — check the loop host" || true
  fi
  exit 1
fi
