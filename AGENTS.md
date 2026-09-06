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
