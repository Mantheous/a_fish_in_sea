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



## Development and tests

Run `flutter analyze` and `flutter test` before submitting changes. Screen goldens
live in `test/goldens/`; behavioral UI tests live in `patrol_test/`. Persisted model
changes require round-trip and per-item restore-tolerance tests.

Development and deployment automation is maintained in a separate private
repository. It is not required to build or contribute to this app. Feedback,
account authorization, sync safeguards and content-free usage instrumentation
remain part of the app and API server.

See `product_specs.md` for the full design and `Worklog.md` for status.
