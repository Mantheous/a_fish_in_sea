In the Finaces section:

- Recived real data from capital one app
- Assign purchases to budget sections
- Set finacial goals
  - Goal has
    - Due date
    - Ammount
    - Plan

---

# TODO:

- Upload our own csv file
  - Make a temporary storage cubit
  - Set up the UI to pull from the temp storage
- look at stuff for a give month
- Income
- Automatic buget assignment

---

# Planner (Sep 2026)

Built:

- Navigation: Home / Calendar / Tasks / PMG / Finances (finances = hub with Waterfall, Rules & Budgets, Bank tabs)
- Calendar page (SfCalendar): day/week/month, create/edit/delete events, repeating events (daily/weekdays/weekly/biweekly/monthly/yearly with count/until end), month agenda, tap-cell-to-create
- Classes: iCal feeds (Learning Suite / Canvas) with name, url, kind, color, create-tasks toggle, enable/disable, per-feed sync status; sync on app start (15 min throttle) + manual refresh
- iCal parsing (enough_icalendar): VEVENT + VTODO, all-day, TZID conversion, RRULE mapping (exotic rules degrade to single occurrence)
- Web CORS proxy: server /api/ical?url=... (server URL setting lives in the classes sheet)
- Tasks: To-Do tab (manual + imported, sorted, overdue red) and Homework tab (grouped by class); homework auto-imported as tasks, deduped by feed UID, completion survives resync
- Preach My Gospel: 13-chapter reading tracker
- Home dashboard: due today/overdue tasks, today's events, assignments due this week
- Global undo/redo (RevertableHydratedCubit + UndoCubit, hydrated, 100 steps) + undo snackbars on deletes; removing a class is one composite undo (feed + events + tasks)

TODO (planner):

- Periodic background resync while app open
- Edit single occurrence of a repeating event (currently series-level only)
- Notification/reminders for due homework
- PMG goals + study planner
- Feed event tap → link to its task directly

---

# TODO:

- Install Linux desktop toolchain (sudo apt install clang ninja-build pkg-config) and Android SDK 36 to build those targets; web builds fine

---

# Calendar sources rework (Sep 2026)

- Removed the Preach My Gospel page (was poorly understood; may return later): page, cubit, nav entry, docs
- Canvas: ONE user-level iCal feed covers all classes; courses are split automatically by parsing the `[COURSE CODE]` suffix Canvas appends to titles → per-course groups/colors in Homework tab + calendar; only `event-assignment-*` UIDs become tasks so class sessions don't spam the to-do list; source kind auto-detected from the URL
- Google Calendar: full server-side OAuth (calendar.readonly) in the Python server (`google_calendar.py`: auth_url/callback/status/disconnect/calendars/events, tokens in `.google_users.json`, global single-user connection). Flutter side: `FeedKind.google` + `calendarId` on Feed, `GoogleCalendarService`, FeedCubit branches per kind, "Connect Google" flow (status → consent page → calendar checklist) in the classes sheet; server expands recurring events so the app needs no recurrence handling; connection is one-time and shared across all app origins (web/Tailscale/mobile)
- FeedCubit.addFeed now upserts by id (google feeds use stable `gcal:<calendarId>` ids); syncFeeds for batch syncing
- 84 tests green; server smoke-tested (status/auth_url/calendars 401-style errors, ical proxy)
- Setup required: GOOGLE_CLIENT_ID/GOOGLE_CLIENT_SECRET in server/python/.env, register redirect URI http://localhost:8000/api/google/callback, connect once from localhost

---

# Settings page (Sep 2026)

- New "Settings" destination (gear) in the bottom navigation, at the same level as Tasks/Finances
- Settings page consolidates configuration: "Classes & calendars" section (feed manager body reused from the classes sheet + Sync server URL tile, moved out of the sheet header) and "Bank connection" section (Plaid connect/disconnect/status + sync transactions)
- Feed manager UI extracted into reusable `FeedManagerBody`; bank connection UI extracted into `ConnectionStatusChip` / `BankConnectionCard` / `syncPlaidTransactions` (shared with the Finances → Bank tab)
