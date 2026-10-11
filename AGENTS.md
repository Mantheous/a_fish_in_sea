# AGENTS.md

## Parallel agents: one worktree per writer

Multiple agents share this clone. Before touching any checkout, read
`tools/agent/CONVENTIONS.md` and follow it — headline rules: diagnose
before editing (`git worktree list` / `status`), never work in a tree
with someone else's uncommitted changes, one worktree + branch per
writer (ad-hoc sessions too), commit WIP often, and `git stash` is
banned in shared clones (commit instead). Merges happen in a
throwaway worktree on `main`, verified before push.

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
   32 recent + 14 daily). Restore: stop uvicorn, gunzip over `app.db`,
   start uvicorn.

When a persisted model changes, extend the per-item tolerance tests and
expect the guardian to hold the deploy until the migration gating is
right.

## Shipping changes to the user

Before shipping anything, read `DEBUG_PREFS.md` (gitignored, per-developer)
and follow ONLY its active target. It tells you whether the developer is
currently on the Tailnet web build or the mobile app — do not guess, do
not do both, do not ask unless the file is missing.

### Mobile (preferred): hot reload/restart over wireless debugging

Load the `wireless-debugging` skill and follow it (reconnect with
`adb reconnect` / `adb connect` first — never re-pair unless auth fails;
known device `mantheous-a16` via Tailscale). Then:

1. If a `flutter run` session already lives in tmux (`tmux capture-pane
   -p -t fish`), push a hot reload/restart: prefer the `dart` MCP
   `dtd` + `dart_hot_reload` / `dart_hot_restart` tools, else
   `tmux send-keys -t fish r` (reload) or `R` (restart).
2. If no session exists, start one per the skill
   (`tmux new-session -d -s fish -c <repo> 'flutter run -d <id>'`;
   first launch is a 5–15 min Gradle build, reloads after are ~1s).

### Web: rebuild for the Tailnet funnel

The user views the web app at `https://alauris.tail088878.ts.net/fish/`.
Tailscale serve maps `/fish` → `http://127.0.0.1:8000` (prefix stripped)
and the FastAPI server (`server/api`, `_mount_web` in `app/main.py`)
serves `<repo>/build/web` from disk — no server restart or copy step
needed after a rebuild. After Dart changes:

1. Rebuild with the subpath base href (REQUIRED — a bare
   `flutter build web` emits `<base href="/">`, which white-screens
   under `/fish/`):
   `~/flutter/bin/flutter build web --base-href /fish/`
2. Verify the bundle timestamp is newer than the edited source and that
   `build/web/index.html` contains `<base href="/fish/">`.
3. Tell the user to hard-refresh (Ctrl+Shift+R): the Flutter service
   worker caches the previous bundle, so a normal reload can still show
   stale code or a stale white screen.
