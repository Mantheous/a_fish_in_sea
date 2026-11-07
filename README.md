# a_fish_in_sea

A one-stop planning app: homework, calendar, tasks, and finances in one place.

## Running

```bash
flutter run -d <device>
```

Web requires the API server running for sync, bank, iCal fetching (CORS proxy) and syllabus extract:

```bash
cd server/api
.venv/bin/uvicorn app.main:app --port 8000 --reload
```

Set the server URL in the app under Settings → Classes & calendars → Sync server URL (default `http://localhost:8000`). Android, iOS, and Linux fetch iCal feeds directly.

## Homework

Canvas: add ONE feed with your personal calendar feed (Canvas web → Calendar → Calendar Feed); every class is included and courses are split automatically from the `[COURSE CODE]` in each title. Learning Suite: add each class separately (course → calendar → subscribe/export). Assignments appear on the calendar color-coded by course and auto-import as tasks. Turn the "create tasks" toggle off for class-schedule feeds so lectures stay calendar-only.

## Google Calendar

Classes & calendars sheet → Google → sign in once (from `http://localhost:8000` on the machine running the API server) → pick calendars. Events flow in read-only on every sync; no re-entering anything. Requires `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` in `server/.env` (see `server/.env.example`).

Everything (events, tasks, classes) is undoable via the undo/redo buttons in each page's app bar or the Undo action on delete snackbars.

## Anki memorization goals

Anki goals are fed by the add-on in `anki_addon/`, which pushes daily
per-deck review totals to the server. This works on web, desktop, and
phone without AnkiConnect or access from the server to your laptop.

1. Sign in and open **Settings → Anki**.
2. Download the `.ankiaddon` there and install it in Anki (Tools →
   Add-ons → Install from file).
3. Create an add-on token and paste the generated JSON into Tools →
   Add-ons → A Fish in Sea → Config.
4. Run **Tools → A Fish in Sea: Test connection**.

The token is write-only (`anki:write`): it can submit deck names and
counts, never read app data. The add-on reports only review totals —
no card text, notes, tags, or schedule details.



## Agent-driven development

Issues flow through an agent loop: a verified tester files an issue labelled `agent-pending`, triage reads the relevant feature docs and posts a plan, and the loop approves it unless the developer denies it or has unaddressed feedback. Builders work on isolated branches, independent reviewers and data/security guardians gate the current PR head, and fully gated PRs merge automatically. Rework escalates reasoning after every two completed attempts instead of stopping for a human. Agents never push directly to `main`. [Loop capacity, feature vision and research](tools/agent/LOOP.md) describes the 90% weekly Codex/Antigravity and monthly OpenCode targets, quota collectors and measured self-improvement.

- Verified testers (the only accounts whose issues are picked up) are listed in `tools/testers.json`.
- The loop scripts (triage, approve, build, review, deploy, ux-walk, poll, Telegram notify) live in `tools/agent/`.
- Before every deploy the loop runs a data guardian: `flutter test test/persistence test/sync` plus a `.opencode/agents/data-guardian.md` audit of the pending diff. A block holds the deploy (`build/web/.agent-data-blocked`, override with a one-shot `touch .agent-data-override`) and labels agent PRs `data:safe` / `data:blocked`. Every deploy is preceded by a gzipped snapshot of the sync DB (`tools/agent/backup-db.sh` → `server/api/data/backups/`). The sync server and client also withhold mass-deletion tombstones that look like a device lost its local data.
- After every web deploy, a code-blind UX walker drives the app in a real browser (like a first-time user) and files blockers as `agent-pending` issues. Label any issue `ux-walk` to request eyes on it.
- Screen goldens (`test/goldens/`, one per bottom-nav destination) run in `flutter test` as the deterministic visual gate; regenerate with `flutter test test/goldens --update-goldens` and review the diff.
- Behavioral UI tests (`patrol_test/`, Patrol + headless Chrome) prove user flows end-to-end against the dev API server: `patrol test --device chrome --web-headless --target patrol_test/<file>.dart --dart-define=SERVER_URL=http://127.0.0.1:8000` (needs `~/.local/bin` + `~/.pub-cache/bin` on PATH for node/patrol; first run downloads Playwright browsers). The `patrol` MCP server (`opencode.json`) is wired for future device-driven runs — `patrol develop` sessions only see mobile targets, so web runs go through the shell.
- Kill switch: touch `.agent-loop-paused` at the repo root or open an issue titled `AGENT LOOPS: PAUSED` and the poll loop goes quiet (running builds finish).

See `product_specs.md` for the full design and `Worklog.md` for status.
