# Planning App

## Homework & Planner
The app is a one-stop planner for school, life, and missionary work. It is not just a homework viewer — the plan is that everything (classes, events, tasks, goals, money) lives in one customizable system.

### Classes & iCal Feeds
Each class is a feed: a name, an iCal link, a source type, and a color. Feeds are managed from the "Classes & calendars" section on the Settings page (gear in the bottom navigation), with a shortcut to the same manager as a sheet from the Calendar and Tasks pages. Feeds can be added, edited, colored, paused (sync off), or removed. Removing a feed removes its events from the calendar and its imported tasks, and the whole cascade is a single undoable change.

Canvas exports a single user-level iCal link that contains every class (Canvas web → Calendar → Calendar Feed). Add it once; the app splits it into per-course groups by parsing the `[COURSE CODE]` suffix Canvas appends to every title (e.g. `Exit Quiz [STAT 230-002]`). Each course gets a deterministic palette color on the calendar and in the Homework tab. Only Canvas assignment events (UID `event-assignment-*`) become tasks, so class sessions stay calendar-only. Learning Suite is per-class: add each course's calendar separately (course → Calendar → subscribe/export).

Sync fetches the iCal file, parses VEVENTs (and VTODOs), and upserts them into the calendar keyed by feed + iCal UID so re-syncs never duplicate. A feed has a "create tasks" toggle: on for homework feeds (assignments become tasks), off for class-schedule feeds (events only, no task spam). Sync runs automatically on app start (throttled to at most every 15 minutes) and can be forced from the refresh buttons. Per-feed sync status (last sync time / error) is shown in the manager.

Recurrence rules from feeds are mapped to the app's canonical rule format when possible (daily / weekly BYDAY / monthly / yearly, with COUNT or UNTIL). Exotic rules fall back to a single occurrence at DTSTART.

### Google Calendar
Google calendars sync through the Python server with a full OAuth flow (read-only `calendar.readonly` scope). The one-time "Connect Google" flow (in the classes manager: Settings page or the sheet from Calendar/Tasks) opens the Google consent page; the server exchanges the code and stores the refresh token (single-user, global). After connecting, pick which calendars to pull — each becomes a Google feed (events only, no tasks, no recurrence rules needed because the server expands recurring events with `singleEvents=true` into a −30/+180 day window). Sync goes through the same `/api/google/events` server endpoint from every platform, so no CORS or browser OAuth is needed in the app.

Note: Google only allows `http://localhost` redirect URIs over HTTP, so the one-time connect must happen from a registered host (by default `http://localhost:<server port>` on the machine running the server). Sync itself works from any origin afterwards. Server needs `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` in its `.env` (redirect URI to register: `http://localhost:8000/api/google/callback`).

On the web build the browser cannot fetch iCal URLs directly (no CORS headers on Canvas / Learning Suite), so fetches are proxied through the Python server at `GET /api/ical?url=...`. The proxy base URL is a setting on the Settings page (Classes & calendars → Sync server URL). Android, iOS, and Linux fetch directly.

### Calendar
A full calendar (Syncfusion SfCalendar) with Day, Week, and Month views (month includes an agenda panel). Events can be created from the + button or by tapping a day/time cell, edited and deleted from a detail sheet. Events support all-day and repeating (none / daily / weekdays / weekly on selected days / every 2 weeks / monthly / yearly) with end conditions (forever / N times / until date). Feed events render on the calendar color-coded by class so homework and personal events appear in one place. Personal events are teal; the default empty-cell tap pre-fills the editor with the tapped date and time.

### Tasks
A to-do list with manual tasks (title, notes, optional due date) and automatically imported homework tasks (deduped by source event, completion preserved across re-syncs). The page has two tabs: To-Do (everything, incomplete first, sorted by due date, overdue highlighted) and Homework (grouped by class with class color and counts, refresh + manage classes inline). Ticking off an imported task never modifies the feed.

### Preach My Gospel
Removed (was a 13-chapter reading tracker). May return later as part of a broader missionary-work planner.

### Home
A dashboard: tasks due today/overdue, today's events, and assignments due in the next 7 days, each with quick navigation.

### Revertable by design
Every manual mutation of events, tasks, and classes is recorded as a before/after snapshot. There is a global undo/redo (app bar buttons on every page, persisted across restarts, capped at 100 steps) plus an "Undo" action on the snackbars for deletes. Feed syncs are not undoable (they clear the undo history because they are bulk, re-runnable operations). Removing a class is one composite undoable change covering the feed, its events, and its tasks.

## Financial Planning
Currently this app only is focused on financial planning. It is important to remember that the context is broader for the finished app. **Prioritize flexibility** — many features will be added later, and the reason this app needs to exist is so that the plan is highly customizable.

### Water fall Ledger
There is a screen dedicated for displaying your accounts history combined with future projected expenses. These projections become more concrete as they approach the present. Much of this will be reported by the user. Periodically the user will upload a csv file that will be used to turn future abstract or concrete transactions and expenses into a history.

Approaching dates: A user may want to budget $100 for food on a given month, but when that month is closer they will want to see it as a weekly budget. These abstract amounts should be definable at any level of abstraction and modified as a group or as sub elements. Perhaps the user knows that next week they will need to spend extra on their food, they don't want to have to change their weekly budget just for that one week.

Repeating expenses need to be supported.

### Statistics
There is a page dedicated to helping the user understand their historical spending and income. It shows useful data for evaluating past performance. You can view by buget catagory.

# Budgets
Budgets are goals. They are like buckets that are fulfilled with transactions or expenses. They show planned expenses that fall into their time range and real expenses that have fallen into them. They can be viewed at different granularities like most things in this app. It is possible to generate an expense based off of the budget, however these will be changed over time. At the end of a budget's period it can optionally be passed to the next period of the same budget if it is a recuring budget. Most budgets are recuring and the default behavior is to roll over. This rollover can happen manually or automatically when the bugdet period ends and the next one begins.

### Expenses
Expenses are the fundamental way of representing spending. They are not goals; they are predicted or real transactions. They can be created at a specified granularity and can be subdivided, deleted, or merged by the user. 

#### Unity-style Inheritance (Prefabs)
Expenses behave like Unity's Prefabs to allow for powerful hierarchical editing:
- **Property Overrides**: When a sub-expense (a specific instance of a recurring rule) is modified (e.g., changing the amount), that specific field is marked as "overridden." It stops inheriting changes from the parent for that field but continues to inherit others (e.g., category or name).
- **Reversion**: Users can revert any overridden field back to the parent's value at any time.
- **Concrete State**: When an expense is tied to a real transaction (e.g., from Plaid), it becomes "concrete." It severs all inheritance from any parent template and becomes a unique historical record.

Example: User creates a monthly expense called "gas" for $50. Then they don't actually spend that money that month. When the expense is due it gets marked as due. The user might then update the due date. Then next week they fill up their gas tank and that expense comes through on bank statement. But it's $45. The user marks this transaction as the gas expense and then a smaller expense is created for the remaining $5. Then the user combines this with the gas for the following month. The user can see in their budget view that they were $5 below the goal.

### View Granularity
The waterfall ledger supports multiple view modes. Crucially, while the **view** may aggregate small expenses into larger buckets for readability, the **underlying data model** always preserves the granular transactions. The view modes are selectable via a dropdown similar to Google Calendar's week/month toggle:
- **Waterfall** (default): Dynamically shows far-future events at monthly granularity, near-future at weekly, and current week at daily. Thresholds are user-configurable via a sub-menu.
- **Fixed scale**: The user can also choose to view everything at a single scale (daily, weekly, monthly, quarterly, yearly, or a user-defined custom period like semesters).

### Recurring Rules
Recurring income and expenses (rent, paychecks, utilities, subscriptions) are first-class objects with a defined frequency, start date, and optional end date. The app auto-generates projected ledger entries from these rules up to a configurable horizon.

### Budget Templates
Abstract spending allocations (e.g. $400/month on food) that refine into finer-grained entries as their period approaches. Users can override specific sub-periods (a single week or day) without modifying the overall template.

### Plaid Reconciliation
Transaction data is loaded automatically via Plaid. The user can see these transactions in the waterfall ledger and report how those expenses fit into the budget. The user can assign an expense of any granularity to an transaction.
- **Auto-Categorization**: If an expense has the exact same name as a past transaction, it should be automatically assigned to the same budget category.
- **Subdivision**: If a transaction is smaller than the assigned expense, the expense should subdivide (creating a "remainder" expense). 
- **Over-spending**: If a transaction is larger than the assigned expense, the expense is logged as its actual value. This shows as "over-budget" in the view but does not modify the underlying recurring rule. Users can manually re-assign these transactions to less granular "bucket" expenses if they wish to balance the ledger.
- **Immutability**: Past transactions are immutable; the UI is only for modifying their *interpretation* as expenses and their impact on the budget. Currently, assigning a single transaction to multiple expenses is not supported.

### Starting Balance
Balance is always pulled from plaid.

### Time Scales
A unified time scale system is used throughout the app (recurring frequencies, budget granularity, view modes). Supported scales: daily, weekly, biweekly, monthly, quarterly, yearly, and user-defined custom periods.

