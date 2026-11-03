# A Fish in Sea

Reports daily Anki review totals to your a fish in sea server so
memorization goals can show live progress. Only deck names and counts
leave the collection — never card text, notes, tags, or scheduling
details.

## Setup

1. In the app, open **Settings → Anki** and tap **Create add-on token**.
2. Copy the JSON snippet it shows. It contains `server_url` and
   `api_token`, plus the reporting defaults.
3. In Anki, open **Tools → Add-ons → A Fish in Sea → Config**, replace
   the file contents with that JSON, and save.
4. Run **Tools → A Fish in Sea: Test connection**.

The add-on reports a few seconds after you stop reviewing, when a
profile opens or closes, and after an AnkiWeb sync.

## What is sent

For each deck and each local calendar day, the number of distinct cards
studied and the number of answers. The app's goals use the distinct-card
count, matching Anki's own "cards studied" statistic. Reports are rolling
absolute totals; the server keeps the per-day maximum, so retries and
multiple profiles cannot double count.

## Options

- `server_url` — app server root, for example
  `https://alauris.tail088878.ts.net/fish` or `http://127.0.0.1:8000`.
- `api_token` — the `afm_…` token created in Settings → Anki. It only
  has the `anki:write` scope: it can submit review totals but cannot read
  any app data.
- `enabled` — turn automatic reports off without removing the config.
- `report_days` — how much history to recompute and send (1–730,
  default 400). A yearly goal needs at least 366.
- `rollover_hour` — hour at which the report day changes. `0` means
  local midnight, matching the app's calendar. Set it to Anki's own
  rollover value (usually `4`) if you want late-night reviews counted
  toward the previous day.

## Troubleshooting

- **"token was rejected"** — create a new token in Settings → Anki and
  paste it into the config.
- **"cannot reach …"** — check `server_url`. It should be the address you
  open the app at, without `/index.html` or a trailing slash.
- **No decks in the app** — run **Report reviews to A Fish in Sea** once
  from the Tools menu, then refresh Settings → Anki.
