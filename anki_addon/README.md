# A Fish in Sea Anki add-on

Pushes daily review totals from your Anki collection to the a fish in sea
server. The app then reads those totals on every platform — web, desktop,
or phone — with no AnkiConnect, port forwarding, or server→laptop access.

## Install

```bash
cd anki_addon
./install.sh                # Linux/macOS; or pass your Anki2 directory
# restart Anki
```

Or build `dist/a_fish_in_sea.ankiaddon` with `./build.sh` and use
**Tools → Add-ons → Install from file…**.

## Configure

1. App → **Settings → Anki → Create add-on token**.
2. Copy the JSON snippet (server URL + token).
3. Anki → **Tools → Add-ons → A Fish in Sea → Config**, replace the
   contents with that JSON, save.
4. Anki → **Tools → A Fish in Sea: Test connection**.

The token has only the `anki:write` scope: it can submit review totals
but cannot read any app data. Revoke it in Settings → API tokens.

## What is reported

Per deck and local calendar day: distinct cards studied and total
answers. No card text, notes, tags, or scheduling data. Reports are
rolling absolute totals; the server keeps the per-day maximum, so
retries and multiple Anki profiles cannot double count.

## Development

```bash
python3 -m unittest discover -s anki_addon/tests
```

`report.py` is pure standard-library code; `__init__.py` contains the
Anki/Qt glue and is only loaded inside Anki.
