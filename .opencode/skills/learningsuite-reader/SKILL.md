---
name: learningsuite-reader
description: >
  Crawl a BYU Learning Suite course without sharing login credentials, then turn
  the offline dump into structured tasks for the planner app. Deterministic
  Playwright scraper reuses the user's own logged-in browser profile; the agent
  only ever reads saved HTML/text. Use when the user says Learning Suite,
  learningsuite, LS crawl, scrape my class, or pastes a
  learningsuite.byu.edu/.XXX/cid-YYY/student/... URL.
---

# LearningSuite reader (no-login-sharing)

## Core rule

Agent NEVER logs in, NEVER asks for or handles passwords or Duo codes.
All authenticated fetching is done by the user running a local script.
The agent only reads files under `tools/ls_scrape/raw/` that the user already saved.

## URL pattern

Courses look like:

```text
https://learningsuite.byu.edu/.XiMK/cid-FOgnegoEKmGv/student/home
                                  ^^^^^ tenant  ^^^^^^^^^^^^^^^ course id
```

Base for a course is everything up to `/student/`. Tabs are the last segment:
`home`, `syllabus`, `assignments`, `schedule`, `content`, `announcements`,
`grades`. Teachers enable different subsets — a missing tab is normal, not an error.

## Phase 1 — user runs the scraper (deterministic, no LLM)

Headless box (no display for manual login) — cookie import:

```bash
# 1. On your own machine: log into learningsuite.byu.edu in your normal
#    browser, export cookies ("Get cookies.txt LOCALLY" extension), save the
#    file YOURSELF as tools/ls_scrape/.cookies.txt (gitignored — never paste
#    session cookies into chat).
# 2. Agent or user runs headless:
cd tools/ls_scrape
source .venv/bin/activate
python playwright_scrape.py --course-url "<home-url>" --cookies-file .cookies.txt
```

Machine with a display — persistent profile instead:

```bash
cd tools/ls_scrape
python3 -m venv .venv   # one time; mirrors server/api/.venv
source .venv/bin/activate
pip install -r requirements.txt
python -m playwright install chromium   # one time
python playwright_scrape.py --course-url "https://learningsuite.byu.edu/.XiMK/cid-FOgnegoEKmGv/student/home"
```

* First run opens a headed browser. User logs in manually (incl. Duo),
  then presses ENTER. Session persists in `tools/ls_scrape/.ls-profile/`
  (gitignored, never uploaded, never read by the agent).
* Later runs are headless with the saved profile. If SSO expired, the script
  falls back to headed mode and asks the user to re-login manually.
* Output: `raw/<cid>/manifest.json` + per-tab `*.html` / `*.txt` + `calendar.ics`
  when the schedule page exposes an iCal feed.
* Fallback if automation breaks: user clicks Schedule → Get iCalendar Feed,
  then `python playwright_scrape.py --course-url <home> --ical-url <feed-url>`.

## Phase 2 — agent parses offline text (this is the agent's job)

```bash
python tools/ls_scrape/parse_tasks.py --course <cid> [--raw tools/ls_scrape/raw --out tasks.json]
```

* Reads only `raw/<cid>/`. Never navigates to learningsuite.byu.edu.
* Merges the 5 hiding spots: syllabus (native / PDF-text / external link /
  missing), schedule, assignments, content pages, announcements.
* Conflict rule: Assignments date wins over Schedule text wins over Syllabus prose.
* Emits `tasks.json` (schema: `tools/ls_scrape/tasks.schema.json`):
  `title`, `due` (ISO-8601 or null), `type`
  (assignment|exam|reading|expectation|admin), `source`
  (assignments|schedule|syllabus|content|announcement), `source_url`,
  `description` (1–2 sentences), `confidence` (high|medium|low),
  `verbatim` (original snippet, ≤500 chars, for audit).
* Vague teacher prose with no date becomes `type: expectation`,
  `confidence: low` — flagged, never silently dropped.

## Import into the Flutter app (no code changes needed)

* `tasks.json` maps to the existing `Task` model: `title→title`, `due→due`,
  `description + source_url → notes`,
  `sha256(source+url) → sourceEventId` (re-runs dedupe, completion preserved),
  course → `classId`/`classLabel`.
* Review path: Tasks page, or paste `raw/<cid>/syllabus.txt` (or combined
  `*_combined.txt`) into the syllabus import sheet (accepts `.txt`/`.md`),
  which runs the on-device parser first and the Alauris model second.
* Only materialize user-approved drafts via `SyllabusDraft.toTask`.
  Never bulk-write HydratedBloc storage.

## Change detection

Each page stores sha256 in `manifest.json`. On re-scrape only re-prompt for
changed pages. `parse_tasks.py --check` prints changed tabs without rewriting
`tasks.json`.
