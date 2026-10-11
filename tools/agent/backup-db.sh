#!/usr/bin/env bash
# Data insurance: snapshot the sync-server SQLite DB (online-safe backup
# API), gzipped, with retention (32 most recent + 1 per day for 14 days).
# Skips effortlessly when the DB is missing or unchanged since the last
# snapshot. Safe to run any time; never modifies the source DB.
# Usage: backup-db.sh [--force]
set -euo pipefail
REPO="$HOME/Repos/a_fish_in_sea"
DIR="$REPO/server/api/data"
DB="$DIR/app.db"
OUT="$DIR/backups"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

[ -f "$DB" ] || { echo "[backup-db] no DB at $DB — skipping"; exit 0; }
mkdir -p "$OUT"

python3 - "$DB" "$OUT" "$FORCE" <<'PY'
import gzip, hashlib, os, sqlite3, sys, time, datetime

db, out, force = sys.argv[1], sys.argv[2], sys.argv[3] == '1'
stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
dest = os.path.join(out, f'app-{stamp}.db.gz')

# Skip if the DB content is unchanged since the newest snapshot.
with open(db, 'rb') as f:
    live_hash = hashlib.sha256(f.read()).hexdigest()
existing = sorted(f for f in os.listdir(out) if f.endswith('.db.gz'))
if existing and not force:
    newest = os.path.join(out, existing[-1])
    with gzip.open(newest, 'rb') as f:
        if hashlib.sha256(f.read()).hexdigest() == live_hash:
            print(f'[backup-db] unchanged since {existing[-1]} — skipping')
            sys.exit(0)

# Online backup API: consistent snapshot even while uvicorn is writing.
src = sqlite3.connect(db)
tmp = dest + '.tmp'
dst = sqlite3.connect(tmp)
with dst:
    src.backup(dst)
dst.close()
src.close()
with open(tmp, 'rb') as f_in, gzip.open(dest, 'wb') as f_out:
    f_out.write(f_in.read())
os.remove(tmp)
print(f'[backup-db] wrote {dest}')

# Retention: keep the 32 newest, then the newest of each of the 14 previous
# days. Everything older is pruned.
snaps = sorted((f for f in os.listdir(out) if f.endswith('.db.gz')), reverse=True)
keep = set(snaps[:32])
days = {}
for name in snaps:
    try:
        mtime = datetime.datetime.strptime(name[4:19], '%Y%m%d-%H%M%S')
    except ValueError:
        continue
    day = mtime.strftime('%Y%m%d')
    if day not in days and len(days) < 14:
        days[day] = name
        keep.add(name)
for name in snaps:
    if name not in keep:
        os.remove(os.path.join(out, name))
print(f'[backup-db] retention: {len(os.listdir(out))} snapshots kept')
PY
