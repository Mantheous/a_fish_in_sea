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

# Security guardian gate: security-guard.sh (run earlier in poll.sh) blocks
# the revision when pending changes open an untrusted-user → GitHub →
# builder path or weaken auth/SSRF/access-control.
SEC_BLOCK_MARKER="build/web/.agent-sec-blocked"
SEC_OVERRIDE=".agent-sec-override"
SEC_ALERT_MARKER="build/web/.agent-sec-alerted"
if [ -f "$SEC_BLOCK_MARKER" ] && [ "$(cat "$SEC_BLOCK_MARKER")" = "$DESC" ]; then
  if [ -f "$SEC_OVERRIDE" ] && { [ ! -s "$SEC_OVERRIDE" ] || [ "$(cat "$SEC_OVERRIDE")" = "$DESC" ]; }; then
    echo "[deploy] security guardian blocked $DESC but override is present — proceeding"
    [ -s "$SEC_OVERRIDE" ] || rm -f "$SEC_OVERRIDE" # one-shot empty-file override
  else
    echo "[deploy] security guardian BLOCKED $DESC — not building this revision"
    echo "[deploy] see build/web/.agent-sec-report.md; override: touch .agent-sec-override"
    if [ ! -f "$SEC_ALERT_MARKER" ] || [ "$(cat "$SEC_ALERT_MARKER")" != "$DESC" ]; then
      echo "$DESC" > "$SEC_ALERT_MARKER"
      "$DIR/tg.sh" "🛑 Web deploy held back by the security guardian ($DESC)
Report: build/web/.agent-sec-report.md
Fix the findings or touch .agent-sec-override to ship anyway." || true
    fi
    exit 0
  fi
fi

# Data insurance before every deploy: snapshot the sync DB (kept if the
# deploy goes bad; cheap and skipped when nothing changed).
"$DIR/backup-db.sh" || echo "[deploy] backup-db failed (continuing)"

# What is about to ship (for the Telegram "shipped" note): subjects landed
# since the last deployed bundle. Merge commits from the loop's merge step
# carry the PR title; fast-forwarded ad-hoc commits show their own subjects.
OLD_SHA=""
if [ -f "$MARKER" ]; then
  case "$(cat "$MARKER")" in main-*) OLD_SHA="$(cat "$MARKER" | sed 's/^main-//')";; esac
fi
echo "[deploy] rebuilding web bundle for $DESC"
if "$FLUTTER" build web --base-href /fish/ 2>&1 | tail -n 3; then
  if ! grep -q '<base href="/fish/">' build/web/index.html; then
    echo "[deploy] build ok but base href wrong — refusing to mark"
    exit 1
  fi
  echo "$DESC" >"$MARKER"
  rm -f "$FAIL_MARKER"
  echo "[deploy] done $DESC"
  NEW_SHA="$(git rev-parse HEAD)"
  SHIPPED=""
  if [ -n "${OLD_SHA:-}" ] && [ "$OLD_SHA" != "$NEW_SHA" ] \
      && git cat-file -e "$OLD_SHA" 2>/dev/null; then
    # Prefer PR titles (what the "Working on" messages named) over raw
    # merge-commit subjects. Best-effort: any gh hiccup falls back to plain
    # commit subjects, and an empty range keeps the generic message.
    MERGES="$(git log --merges --format=%H "$OLD_SHA..$NEW_SHA" 2>/dev/null | head -n 3 || true)"
    if [ -n "${MERGES:-}" ]; then
      SLUG="$(git remote get-url origin \
        | sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##')"
      while read -r M; do
        [ -z "${M:-}" ] && continue
        T=""
        [ -n "${SLUG:-}" ] && T="$(gh api "repos/$SLUG/commits/$M/pulls" \
          --jq '.[0].title // empty' 2>/dev/null || true)"
        [ -z "${T:-}" ] && T="$(git log -1 --format=%s "$M" 2>/dev/null || true)"
        T="$(echo "$T" | sed -E 's/^\[agent #[0-9]+\] //')"
        [ -n "${T:-}" ] && SHIPPED="${SHIPPED}${SHIPPED:+; }$T"
      done <<< "$MERGES"
    fi
    if [ -z "${SHIPPED:-}" ]; then
      SHIPPED="$(git log --format=%s "$OLD_SHA..$NEW_SHA" 2>/dev/null \
        | grep -vE '^(fix\(loop\)|chore:)' | head -n 3 | tr '\n' ';' | sed 's/; *$//' | sed 's/; */; /g' || true)"
    fi
  fi
  if [ -n "${SHIPPED:-}" ]; then
    "$DIR/tg.sh" "🚀 Shipped to /fish/: $SHIPPED — hard-refresh to see it" || true
  else
    "$DIR/tg.sh" "🚀 Web app rebuilt ($DESC) — hard-refresh /fish/ to see it" || true
  fi
else
  echo "[deploy] flutter build failed for $DESC"
  if [ ! -f "$FAIL_MARKER" ] || [ "$(cat "$FAIL_MARKER")" != "$DESC" ]; then
    echo "$DESC" >"$FAIL_MARKER"
    "$DIR/tg.sh" "🔥 Web build FAILED ($DESC) — check the loop host" || true
  fi
  exit 1
fi
