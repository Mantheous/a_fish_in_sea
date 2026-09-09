# AGENTS.md

## Deploy = rebuild the web app, every time

The user runs this app as a **web build served by the Python sync server**:
`server/python/server.py` serves `build/web/` (see `WEB_BUILD_DIR` in
`server.py`). Source changes do NOTHING until the web build is refreshed.

After EVERY code change (no exceptions):

1. Verify: `~/flutter/bin/flutter test` (flutter is NOT on PATH; use the
   full path `~/flutter/bin/flutter`).
2. Deploy: `~/flutter/bin/flutter build web` from the repo root.
3. No `server.py` restart is needed for frontend-only changes (it serves
   static files). Restart it only if `server/python/*` changed.
4. Tell the user to hard-refresh the browser and re-sync their feeds.

Never leave a session with passing tests but a stale `build/web` — check
the `index.html` timestamp if unsure.

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
   follow the deploy rule above and verify old data still loads.
