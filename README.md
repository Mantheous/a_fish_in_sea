# a_fish_in_sea

A one-stop planning app: homework, calendar, tasks, and finances in one place.

## Running

```bash
flutter run -d <device>
```

Web requires the Python server running for iCal fetching (CORS proxy):

```bash
cd server/python
./start.sh
```

Set the server URL in the app under Settings → Classes & calendars → Sync server URL (default `http://localhost:8000`). Android, iOS, and Linux fetch iCal feeds directly.

## Homework

Canvas: add ONE feed with your personal calendar feed (Canvas web → Calendar → Calendar Feed); every class is included and courses are split automatically from the `[COURSE CODE]` in each title. Learning Suite: add each class separately (course → calendar → subscribe/export). Assignments appear on the calendar color-coded by course and auto-import as tasks. Turn the "create tasks" toggle off for class-schedule feeds so lectures stay calendar-only.

## Google Calendar

Classes & calendars sheet → Google → sign in once (from `http://localhost:8000` on the machine running the Python server) → pick calendars. Events flow in read-only on every sync; no re-entering anything. Requires `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` in `server/python/.env` (see `.env.example`).

Everything (events, tasks, classes) is undoable via the undo/redo buttons in each page's app bar or the Undo action on delete snackbars.

See `product_specs.md` for the full design and `Worklog.md` for status.
