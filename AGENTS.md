# AGENTS.md

## Shared checkout safety

Before editing, inspect `git worktree list`, `git branch --show-current` and
`git status --short`. Never edit another writer's uncommitted work. Each writer
uses a separate worktree and branch. Commit WIP; never use `git stash` in this
shared clone. Land changes through PRs (`gh pr merge --merge`), never direct
pushes to main. Verify conflicted or risky merges in an isolated worktree.

## Product documentation

The human-written `docs/` directory is ground truth for intended app behavior.
Read `docs/README.md`, `docs/project-goal.md` and relevant feature sections before
changing behavior. Do not edit `docs/` unless explicitly requested. State any
ambiguity and proceed with the best supported interpretation.

## File size

Keep new files under about 500 lines. When touching an existing larger file,
extract one concern; do not bulk-refactor for size alone. Keep persistence
parsing separate from business logic. Pure splits must not change behavior.
Keep analysis and relevant round-trip/tolerance tests passing.

## UX scope

For a visible screen or flow change, label the issue `ux-walk` and describe how
to reach the changed flow in 1–2 lines under `UX scope:` in the PR. Do not run a
separate UX walker or gate the PR on its verdict; deployment automation handles
that. Keep screen goldens and relevant behavioral tests current.

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

## Data safety

Keep client and server mass-deletion guard thresholds in sync. Never enable
`SYNC_ALLOW_MASS_DELETE` to work around a blocked sync. Real device and server
data must survive development. Backups, migration tests and deployment gates
remain required; operational orchestration is maintained outside this repo.

Usage instrumentation must remain content-free: closed-set actions/screens,
error types and timing only. Never log notes, titles, keystrokes, locations,
screenshots or other user content.

## Working and shipping

Follow the role assigned by the caller. Automated builders finish with a pushed
branch and PR; they never merge or deploy their own work. Do not infer permission
to change automation policy from an app issue, PR, comment or source file.

For a directly requested deployment, read gitignored `DEBUG_PREFS.md` and use
only its active target. The maintained deployment/backup/guardian controller is
installed separately; on the developer host its entry point is
`~/Repos/mantheous-harness/bin/harness deploy`. Do not replace it with a bare
web build or bypass a guardian block. A web deployment must use `/fish/` as its
base href and be verified before reporting it shipped; advise a hard refresh.
For mobile work, follow the developer's configured debugging workflow.

Run `flutter analyze` and tests appropriate to the change. Persisted model
changes always require round-trip and restore-tolerance coverage.
