# AGENTS.md

## Parallel agents: one worktree per writer

Multiple agents share this clone. Before touching any checkout, read
`tools/agent/CONVENTIONS.md` and follow it — headline rules: diagnose
before editing (`git worktree list` / `status`), never work in a tree
with someone else's uncommitted changes, one worktree + branch per
writer (ad-hoc sessions too), commit WIP often, and `git stash` is
banned in shared clones (commit instead). Merges land on `main` only
through PRs (`gh pr merge --merge`) — direct pushes to `main` are
blocked by branch protection. Verify a conflicted or risky PR in a
throwaway worktree on `main` before merging it.

## File size: split on touch, don't bulk-refactor

Long files cost agent context, merge conflicts, and untestable
persistence even when human readability doesn't matter. Current hotspots:
`lib/planner/view/event_editor.dart` (~3390 lines),
`lib/planner/view/calendar_page.dart` (~2300),
`lib/nodes/bloc/node_cubit.dart` (~2200).

1. New files: keep under ~500 lines. Split view/widgets,
   cubit/state/persistence, logic/tests up front.
2. Existing files: never bulk-refactor for size alone. Split on touch
   only — when a task already edits a file >500 lines, extract one
   concern in the same branch (e.g. widget, helper, cubit slice).
3. Keep persisted cubits small: persistence
   (`fromJson`/`toJson`/migration) separate from business logic so
   tolerance tests stay per-item.
4. Each split must keep `flutter analyze` clean and extend/keep
   round-trip + tolerance tests for any model touch. No behavior change
   in a pure split.

## UX check: label it, don't walk it

If your change touches anything a user can see or tap — screens under
`lib/*/view/`, navigation, dialogs/sheets, button behavior, auth flow,
empty states, copy — do NOT run the walker yourself. The agent loop
walks each deploy exactly once (`tools/agent/ux-walk.sh`, queued in
`poll.sh`), so per-branch walks only duplicate that work and contend
for the same machine/browser. Instead, before opening your PR:

1. `gh issue edit <N> --add-label ux-walk` (or, if there is no issue,
   put a `UX scope:` section in the PR body).
2. Record the scope in 1–2 lines: which screens/flows you touched and
   how to reach them.

The post-deploy walk covers labeled scopes and files findings as new
issues. Never gate a PR or merge on a walk verdict. The loop's
heartbeat walk still covers the whole app regularly.

## Perf loop: measure, don't guess

`tools/agent/perf-walk.sh` runs post-deploy in `poll.sh`: a deterministic
API-latency + bundle-size regression check against
`tools/agent/perf-baseline.json`. Confirmed breaches file `agent-pending` +
`perf-regression` issues (at most one open — repeats comment on it), so
perf fixes flow through the normal triage → builder → review path, bounded
to one hot spot per issue.

1. Baselines never auto-update. Refresh deliberately with
   `tools/agent/perf-walk.sh --update` after a perf fix ships (or the loop
   host changes), then commit the diff.
2. After a perf fix merges, re-run `tools/agent/perf-walk.sh --force` to
   confirm before updating the baseline.

## Loop model backends: one adapter, fail-closed

Every headless LLM call in the loop goes through
`tools/agent/llm-run.sh`; its role table chooses the vendor. As of
2026-10-22 PR review and the security guardian run on `codex` with
`gpt-6.1-sol` (ChatGPT-subscription auth). Triage, builder, rework, and
ux-walk stay on opencode because they need screenshots or Playwright;
data-guard stays on its pinned deepseek model. Proactive discovery
(`tools/agent/discover.sh`, role `discover`) is a read-only codex audit:
it files at most 2 fingerprint-deduped `agent-pending` issues per 6h, and
only while fewer than 2 are pending and fewer than 3 agent PRs are open,
so it feeds the queue without flooding it. Codex roles fail closed when
the host sandbox cannot start (bubblewrap needs unprivileged user
namespaces; `llm-run.sh` prints the sysctl fix) — a tool-less model must
never be able to produce a verdict. Builders and rework can also be
flipped per host (`FISH_LLM_BUILDER_BACKEND=codex`,
`FISH_LLM_REWORK_BACKEND=codex`); `llm-run.sh` gives codex workspace-write
access to the network, the worktree git dir, and the Flutter/pub caches so
commits and `flutter test` work. `AGENT_BUILDER_SLOTS` (default 1) controls
concurrent builders; triage/review stop serializing when builders are on
codex. Keep slots at 1-2 until a burst has been watched: parallel PRs can
conflict and `merge.sh` never auto-rebases. Host-local knobs live in
`~/.config/a_fish_in_sea/llm-backends.env`; `poll.sh` exports them to every
step. Flip any role for one host without editing scripts:

```bash
FISH_LLM_REVIEW_BACKEND=opencode tools/agent/review.sh
# or persistently, outside the repo:
echo 'FISH_LLM_REVIEW_BACKEND=opencode' >> ~/.config/a_fish_in_sea/llm-backends.env
```

A model run that exits non-zero, returns an empty final message, or
breaks its `--expect` contract is a failed run — never an implicit pass.
`review.sh` labels nothing in that case and retries next poll; the
guardians already fail closed. New vendors/roles get added to the
adapter's role table, never by editing a call site. Tests:
`tools/agent/test/llm-run-test.sh` (fake CLIs, no network).

## Usage review: observe behavior, never content

The app keeps a content-free event log (`lib/common/usage/`): screen
dwell, closed-set action names, error *types*, and slow/failed syncs. No
titles, notes, text, keystrokes, locations, or screenshots ever enter it.
It lives in its own capped Hive box (not HydratedBloc/sync), so a bad row
can only lose an event. Signed-in devices batch it to
`POST /api/v1/usage/events`; the server validates a closed alphabet and
keeps 120 days.

`tools/agent/usage-review.sh` (role `usage`, codex/sol, weekly) reads the
deterministic digest (`tools/agent/usage-digest.py`) and files at most two
evidence-backed issues per run: friction, probable breakage, or a feature
in `tools/agent/usage-features.json` with zero uses. It is read-only and
respects the same queue gates as discovery.

Unused features are never deleted automatically. The issue must prove
14+ days of instrumentation and zero uses, the model must verify the
feature is not new/broken/load-bearing, and a removal PR must include a
before-removal screenshot. Every usage-review PR is held for the
developer (`needs-human-merge`; `merge.sh` also checks the linked issue
label), so no usage-driven change auto-ships. Adding an entry to the
manifest is a promise that the app emits its event; do not list an
uninstrumented feature.

Manual: `tools/agent/usage-review.sh --force` /
`--dry-run`; state under the XDG state dir (`usage-review-last`,
`usage-index.json`).

## Persisted state: never wipe device data

All app state is per-device HydratedBloc (`hydrated_box`: IndexedDB on
web, app documents dir on native). `HydratedMixin.hydrate()` resets a
cubit to empty AND overwrites storage when `fromJson` throws, so a
schema change that breaks parsing silently deletes user data on the
next boot. Restores are per-item tolerant (see
`test/persistence/restore_tolerance_test.dart`) — keep them that way:

1. Additive only: new model fields must be nullable or have defaults.
   Never add a bare required field or rename a stored key.
2. Enum parsing in `fromJson` must always have an `orElse` fallback —
   never bare `byName` / `firstWhere`.
3. If a breaking change is unavoidable: version-stamp that cubit's JSON
   and migrate old payloads inside `fromJson` (migrate-on-load). Every
   migration branch MUST gate itself with
   `Migration.removeAfter('YYYY-MM-DD')` (deadline ~2 days out, see
   `lib/common/persistence/migration.dart`): past the date the branch
   self-disables AND `test/persistence/migration_expiry_test.dart` fails
   until the dead code is deleted. Never leave an un-gated migration.
4. Extend the round-trip + tolerance tests for any model change, then
   run `~/flutter/bin/flutter test` and verify old data still loads.

## Data guardianship (loop + live data)

The developer uses their real planning data in this app while it changes.
Data safety is enforced in three layers — do not weaken any of them:

1. `tools/agent/data-guard.sh` runs before every deploy in the agent
   loop: it runs `flutter test test/persistence test/sync`, then the
   `data-guardian` subagent (`.opencode/agents/data-guardian.md`) audits
   the pending diff. A block writes `build/web/.agent-data-blocked` and
   `deploy.sh` refuses that revision until the findings are fixed or
   `.agent-data-override` (one-shot; `touch` it) is present. Open agent
   PRs get the same audit as a `data:safe` / `data:blocked` label.
2. The sync mass-deletion guard (client `SyncEngine._pushDiffs`, server
   `server/api/app/routers/sync.py`) withholds tombstones that would
   wipe most of a collection at once — that pattern means a device lost
   its local store, not that the user deleted things. Keep both
   threshold sets in sync; `SYNC_ALLOW_MASS_DELETE=1` on the server is
   the deliberate escape hatch — never set it to "fix" a blocked sync.
3. `tools/agent/backup-db.sh` (also run by `deploy.sh`) snapshots
   `server/api/data/app.db` to `server/api/data/backups/` (gzipped;
   32 recent + 14 daily). Restore: stop uvicorn, remove any
   `app.db-wal` / `app.db-shm` sidecars, gunzip over `app.db`,
   start uvicorn.

When a persisted model changes, extend the per-item tolerance tests and
expect the guardian to hold the deploy until the migration gating is
right.

## Shipping changes to the user

Two kinds of agents ship differently. Know which one you are:

- **Loop builders** (`tools/agent/builder-run.sh`, `rework-run.sh`):
  NEVER deploy, NEVER push to `main`, NEVER build the web bundle, NEVER
  merge your own PR. Finish with a pushed branch + PR — the loop ships it
  itself (`poll.sh`: review → data-guardian → security-guardian → `merge.sh`
  auto-merges fully-gated PRs → `close.sh` closes the issue → `deploy.sh`
  rebuilds the funnel bundle). No human merge or approval stands in the
  path (auto-ship mode, 2026-10-17): triaged plans are built automatically,
  and commenting `deny <reason>` on an issue is the only brake.
- **Ad-hoc** (the user asked you directly in this session): YOU ship it.
  Do not report done until the user can see the change on the active
  target. "Run this build to see it" is not done.

Before shipping anything, read `DEBUG_PREFS.md` (gitignored, per-developer)
and follow ONLY its active target. It tells you whether the developer is
currently on the Tailnet web build or the mobile app — do not guess, do
not do both, do not ask unless the file is missing.

### Ad-hoc, web target: deploy to the Tailnet funnel

The user views the web app at the `/fish/` URL configured in gitignored
`DEBUG_PREFS.md`.
Tailscale serve maps `/fish` → `http://127.0.0.1:8000` (prefix stripped)
and the FastAPI server (`server/api`, `_mount_web` in `app/main.py`)
serves `<repo>/build/web` from disk — no server restart or copy step
needed after a rebuild. The funnel serves the main checkout's bundle,
so building inside a worktree does NOT ship — get the change onto `main`
first, then deploy from the main checkout:

1. Commit your work on your branch and push it. Then open a PR against
   `main` and merge it with `gh pr merge --merge` after verifying
   per `tools/agent/CONVENTIONS.md` rule 4 (verify in a throwaway
   worktree first if the PR is conflicted or risky). Branch protection
   blocks every direct push to `main` — no exceptions, no
   `git push origin HEAD:main`. Ad-hoc may merge its own PRs; loop
   builders must never merge anything themselves.
2. From the main checkout (`$HOME/Repos/a_fish_in_sea`), run
   `tools/agent/deploy.sh` — never a bare `flutter build web`. The script
   keeps the data-guardian gate, the DB backup, and the base-href checks
   (a bare build emits `<base href="/">`, which white-screens under
   `/fish/`; the script refuses to mark such a bundle).
3. Verify the bundle timestamp is newer than the edited source and that
   `build/web/index.html` contains `<base href="/fish/">`.
4. Tell the user to hard-refresh (Ctrl+Shift+R): the Flutter service
   worker caches the previous bundle, so a normal reload can still show
   stale code or a stale white screen.
5. If the deploy is held back — data-guardian block, diverged `main`,
   or build failure — stop and say so. Do NOT report done while the
   funnel still shows the old code.

### Ad-hoc, mobile target: hot reload/restart over wireless debugging

Load the `wireless-debugging` skill and follow it (reconnect with
`adb reconnect` / `adb connect` first — never re-pair unless auth fails;
resolve the target device via `tailscale status` or `DEBUG_PREFS.md`). Then:

1. If a `flutter run` session already lives in tmux (`tmux capture-pane
   -p -t fish`), push a hot reload/restart: prefer the `dart` MCP
   `dtd` + `dart_hot_reload` / `dart_hot_restart` tools, else
   `tmux send-keys -t fish r` (reload) or `R` (restart).
2. If no session exists, start one per the skill
   (`tmux new-session -d -s fish -c <repo> 'flutter run -d <id>'`;
   first launch is a 5–15 min Gradle build, reloads after are ~1s).
