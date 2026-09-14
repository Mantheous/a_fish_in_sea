# AGENTS.md

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

## Shipping changes to the user

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
