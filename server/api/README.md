# Sync API (FastAPI) — the one app server

Offline-first sync backend for web + mobile + MCP agents. One generic
envelope table (`sync_items`) covers all 13 client domains so the whole
app migrates in a single schema; validation stays lenient (unknown fields
pass through) to mirror the client's per-item-tolerant restores.

Secrets live in ONE place: `server/.env` (JWT/TOKEN_FERNET_KEY plus
GOOGLE_/PLAID_/OLLAMA_ keys), auto-loaded at startup; an optional local
`server/api/.env` overrides it.

## Run (dev, sqlite)

```bash
cd server/api
python -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/uvicorn app.main:app --port 8000 --reload
.venv/bin/python -m pytest tests/ -q
```

## Endpoints (`/api/v1`)

- `POST /auth/register|login|refresh`, `GET /auth/me` — JWT (15min access, 30d refresh)
- `POST /tokens`, `GET /tokens`, `DELETE /tokens/{id}` — scoped `afm_…` tokens for MCP agents
- `GET /sync/pull?since=&collections=&limit=` — incremental pull, `has_more` paging
- `POST /sync/push {changes:[{collection,item_id,data,deleted}]}` — batch upsert, last-write-wins, tombstones retained
- `/items/{collection}[/{id}]` — CRUD convenience over the same envelope for MCP (`tasks`, `events`, …)
- `POST /fetch/refresh {feed_id?, url?}` / `POST /fetch/refresh-due` — server fetches iCal URLs and caches raw ICS in `feed_snapshots`
- `GET /fetch/snapshot?feed_id=` — cached ICS for clients to parse (Google feeds excluded: they sync client-side through `/api/google/*`)

## Proxies (`/api/*`, same paths as the retired Flask server)

- `/api/google/*` — per-user Google Calendar/People proxy: `auth_url`, `callback` (OAuth `state` binds the browser flow to the user), `status`, `disconnect`, `calendars`, `contacts`, `events` + `events/one` + write routes. Tokens live in `oauth_connections`, Fernet-encrypted when `TOKEN_FERNET_KEY` is set.
- `/api/create_link_token`, `/api/set_access_token`, `/api/info`, `/api/disconnect`, `/api/sandbox/auto_connect`, `/api/auth`, `/api/transactions`, `/api/identity`, `/api/balance`, `/api/accounts`, `/api/item`, `/api/link_exit_error` — per-user Plaid proxy (same paths as Flask, so the app needs no changes). Bank tokens live in `oauth_connections`, never leave the server. Requires the sync JWT (bank connection now needs a sync account — register in the app first).
- `GET /api/ical?url=` — open iCal fetch proxy with SSRF guard (fixes web CORS).
- `POST /api/syllabus/extract {text}` — proxies to Ollama on localhost (`OLLAMA_BASE_URL`, `SYLLABUS_MODEL`), returns `{drafts, model}`.

Not ported from the Plaid quickstart (unused by the app; the
money-movement ones must never run outside a demo):
`create_link_token_for_payment`, `create_user_token`, `assets`,
`holdings`, `investments_transactions`, `transfer_authorize`,
`transfer_create`, `statements`, `signal_evaluate`, `payment`, `cra/*`.

## Cutover from Flask (done)

```bash
# 1. register in the app (creates the sync user), then import tokens:
.venv/bin/python -m app.migrate_json --user you@example.com
# 2. set TOKEN_FERNET_KEY in server/.env (generate: python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
# 3. this server now listens on :8000 (same port Flask used); no app changes needed
```

Legacy `server/.plaid_users.json` / `server/.google_users.json` (moved
from `server/python/` at removal) import once via `migrate_json`, then
delete them.

Collections: `tasks events feeds goals tags expenses budgets recurring_rules
transactions places reported_entries tracked_points settings waterfall plaid`
(`reported_entries` is day-granular: item_id = day key; `settings`,
`waterfall`, `plaid` are singletons with item_id = `singleton`).

Conflict policy: item-level last-write-wins, **server wins** true
conflicts. Clients track per-item content hashes + last-seen server
timestamps; undo history never leaves the device.

## Prod

`docker-compose up` in `server/` (postgres + api). Set `JWT_SECRET` and
`TOKEN_FERNET_KEY` in `server/.env`. Back up with `pg_dump`.

## Next (not yet)

- Alembic migrations (currently `create_all` on boot), refresh-token rotation, Flutter first-login bulk upload.
