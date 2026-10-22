#!/usr/bin/env bash
# GitHub label helper for the agent loop.
#
# Why this exists: as of 2026-10-13 `gh pr edit --add-label/--remove-label`
# is BROKEN on this host — GitHub's `Projects (classic)` deprecation makes
# every PR GraphQL mutation exit 1 and change NOTHING (gh 2.45.0). The loop's
# whole label state machine — review:pass, review:changes-requested,
# data:safe, data:blocked, agent-approved, ux-walk — silently stopped
# applying: verdicts never stuck, reviews re-ran fresh every poll, and the
# rework path (keyed on the FAIL label) never fired. `gh issue edit` is
# REST-based and still works; only PR edits go through the broken GraphQL
# path. This helper uses the REST API for BOTH (a PR is an issue in REST
# terms), so labels apply either way.
#
# Usage:
#   label.sh <issue-or-pr-number> add <label> [label...]
#   label.sh <issue-or-pr-number> remove <label> [label...]
set -euo pipefail
N="$1"; ACTION="$2"; shift 2
REPO="$(git -C "$HOME/Repos/a_fish_in_sea" remote get-url origin \
  | sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##')"
[ -n "$REPO" ] || { echo "label.sh: could not resolve owner/repo" >&2; exit 1; }
for L in "$@"; do
  case "$ACTION" in
    add)
      gh api -X POST "repos/$REPO/issues/$N/labels" -f "labels[]=$L" >/dev/null
      ;;
    remove)
      # Removing a label that isn't there is a no-op, not an error.
      gh api -X DELETE "repos/$REPO/issues/$N/labels/$L" >/dev/null 2>&1 || true
      ;;
    *)
      echo "label.sh: action must be add or remove (got '$ACTION')" >&2
      exit 2
      ;;
  esac
done
