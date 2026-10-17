# a_fish_in_sea — API instructions for the import agent

You push scraped course deadlines into the user's planner (web/mobile app)
via its sync API. This file is the contract; if it conflicts with anything
else, it wins. Your scraper is your own business — this covers only what
happens after you have structured items in hand.

## 1. Server + credentials

- Base URL: read `AFIS_BASE_URL` from a gitignored `.env` file (e.g.
  `https://<your-tailnet-host>/fish/api/v1` or `http://127.0.0.1:8000/api/v1`).
  Never hardcode the server hostname or IP address in tracked files.
- Read the `afm_…` token from a gitignored file in this repo (e.g. `.env`
  → `AFIS_TOKEN=afm_…`). Never hardcode it, never echo it into output or
  logs. Every request carries: `Authorization: Bearer afm_…`.
- One-time setup (the USER does this; you don't handle passwords):
  ```bash
  # get a JWT with the sync account's credentials
  curl -X POST $BASE/auth/login -H 'content-type: application/json' \
    -d '{"email":"you@example.com","password":"…"}'
  # mint a long-lived token FOR THE REVIEW QUEUE — review:true matters
  curl -X POST $BASE/tokens \
    -H "authorization: Bearer $ACCESS_TOKEN" \
    -H 'content-type: application/json' \
    -d '{"name":"laptop import","scopes":["sync"],"review":true}'
  ```
  The plaintext token is shown exactly once — save it into `.env`
  yourself. With `review:true`, your imports draft into the user's
  in-app approval inbox instead of writing their calendar directly.
  (Without it, `POST /imports` would apply immediately — do NOT mint
  a non-review token unless the user explicitly asks for trusted mode.)
- If the token leaks or stops working, tell the user: they revoke it
  (`DELETE /tokens/{id}`) and mint a new one. You never touch `/tokens`
  yourself past setup.

## 2. The only endpoint you use

```
POST /imports  body: {"source": "learning suite",
                      "items": [{"collection": ..., "item_id": ..., "data": {...}}]}
```

Response: `{"status":"pending","batch_id":7}` — report the batch id and
tell the user to open the app's Home tile to approve. With a review
token you get `pending`, never `applied`; if you ever see `applied`,
your token is NOT a review token — stop and tell the user.

- Max 200 items per call; split bigger scrapes across calls.
- (For reference: `GET /imports/pending` and the approve/reject routes
  are app-user-only — the server answers 403 for tokens. Never call them.)

## 3. Payload shapes (must match the app's parsers)

Assignments / homework → collection `nodes` (the app's live task object;
the old `tasks` collection is retired and invisible — never use it):
```json
{"id":"<same as item_id>","title":"…","notes":"…",
 "status":"open",
 "schedule":{"due":"2026-03-04T23:59:00"},
 "sourceEventId":"ls:<course>:<16-hex-hash>",
 "classLabel":"Course Name"}
```
- `id` and `title` are REQUIRED (`id` == the item_id in the call).
- `schedule.due` is optional ISO-8601; omit `schedule` for dateless work.
- End-of-day `T23:59:00` when only a date is known (the app renders the
  time only when it carries information); use a real time when the
  scrape provides one (e.g. from the ICS feed).
- `notes`: description + source URL; `classLabel`: human course name.

Timed things (exams/quizzes with posted times) → collection `events`:
```json
{"id":"<same as item_id>","subject":"…","notes":"…",
 "start":"2026-03-04T08:00:00","end":"2026-03-04T09:15:00",
 "allDay":false,"classLabel":"Course Name"}
```
- `start`/`end` are REQUIRED (`PlannerEvent.fromJson` throws without
  them). All-day or no-time items are better as NODES; if you must use
  an all-day event: `allDay:true`, `start` 00:00:00, `end` 23:59:59.
- Never set `taskId` — linkage is app-managed.

Task-vs-event is your judgement call: timed → event, due-by-end-of-day
→ node. When unsure, prefer node.

## 4. Idempotency (the core rule)

- `item_id` must be DETERMINISTIC: a stable hash of the authoritative
  source, e.g. `ls:<course>:<sha256(source|url|title)[:16]>`. Never a
  random uuid — a re-scrape must land on the same item_id so approval
  UPDATES the existing row instead of duplicating it.
- Due-date precedence (decide in YOUR parse step): the assignments-page
  / ICS date WINS over schedule text and syllabus prose. Some instructors
  post wrong dates in prose — the structured one is authoritative. A
  corrected date flows in naturally: same item_id, new `due`; the user's
  review screen shows it as "updates existing: Mar 4 → Mar 7".
- `data` replaces wholesale on approval: always send the complete
  record, not a partial delta.

## 5. Workflow — submit, then the user approves in the app

1. Build the items, `POST /imports`.
2. Tell the user: batch id, item count, and to check the Home screen's
   "Import received" tile — they approve all or pick one-by-one there,
   and items appear on their devices right after.
3. If a row collides with something they deleted in the app on purpose,
   they will discard it during review — that is their call, not yours.

## 6. Hard prohibitions

- NO `DELETE /items/…`, ever, unless the user explicitly asks you to
  delete a specific item in this conversation.
- NO tombstones: never write `deleted:true`, never use `POST /sync/push`.
  Deletions belong to the app's UI, not to you.
- Only `nodes` and `events` collections. Never invent collection names;
  never use the retired `tasks` collection.
- Item payloads < 256 KiB each (anything bigger means you're stuffing a
  whole dump into one item, which is wrong).
- No sleeping/retrying loops against the server; single-shot requests.
  A 4xx is a bug in your payload, not a transient failure to ride out.

## 7. Sanity check before real work

```bash
curl -s -X POST $BASE/imports -H "authorization: Bearer $AFIS_TOKEN" \
  -H 'content-type: application/json' -d '{"items":[],"source":"probe"}'
```
Expect `422` (empty items rejected — proves auth + base URL are right).
`401` → token revoked/expired: ask the user to mint a new one.
`404`/HTML → wrong base URL: use the tailnet path above.
