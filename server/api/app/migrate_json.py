"""One-time import of Flask-era token JSON files into oauth_connections.

Reads server/.google_users.json (global "default" key) and
server/.plaid_users.json ({userId: {access_token, item_id}}) — moved
there from server/python/ when the Flask app was retired — and stores
them for one sync user (matched by email). Secrets are
Fernet-encrypted when TOKEN_FERNET_KEY is set.

Usage:
    .venv/bin/python -m app.migrate_json --user you@example.com
    .venv/bin/python -m app.migrate_json --user you@example.com --only google
"""

from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import json
import sys
from pathlib import Path

from sqlalchemy import select

LegacyDir = Path(__file__).parent.parent.parent
_OldDir = LegacyDir / "python"  # pre-removal location, checked as fallback


def _legacy_path(name: str) -> Path:
    for candidate in (LegacyDir / name, _OldDir / name):
        if candidate.exists():
            return candidate
    return LegacyDir / name


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--user", required=True, help="sync account email")
    ap.add_argument("--only", choices=["google", "plaid"], default=None)
    args = ap.parse_args()

    from .db import init_db, session_factory
    from .models import User
    from .oauth_store import save_connection

    await init_db()
    factory = session_factory()
    async with factory() as session:
        user = (
            await session.execute(select(User).where(User.email == args.user))
        ).scalar_one_or_none()
        if user is None:
            print(f"No sync user {args.user!r}; register in the app first.")
            return 1

        if args.only in (None, "google"):
            path = _legacy_path(".google_users.json")
            if path.exists():
                try:
                    record = json.loads(path.read_text()).get("default") or {}
                except (json.JSONDecodeError, OSError):
                    record = {}
                if record.get("refresh_token"):
                    scopes = record.get("scopes") or []
                    await save_connection(
                        session,
                        user.id,
                        "google",
                        access_token=record.get("access_token") or "",
                        refresh_token=record.get("refresh_token") or "",
                        scopes=(
                            scopes
                            if isinstance(scopes, str)
                            else " ".join(scopes)
                        ),
                        expires_at=(
                            dt.datetime.fromtimestamp(
                                float(record["expires_at"]), dt.timezone.utc
                            )
                            if record.get("expires_at")
                            else None
                        ),
                        merge_refresh=False,
                    )
                    print("Imported Google connection.")
                else:
                    print("No Google refresh token in legacy file.")
            else:
                print("No legacy Google file; skipping.")

        if args.only in (None, "plaid"):
            path = _legacy_path(".plaid_users.json")
            if path.exists():
                try:
                    users = json.loads(path.read_text())
                    users = users if isinstance(users, dict) else {}
                except (json.JSONDecodeError, OSError):
                    users = {}
                # Legacy buckets are keyed by opaque app user id; import the
                # first connected one (single-user era data).
                imported = False
                for uid, rec in users.items():
                    if isinstance(rec, dict) and rec.get("access_token"):
                        await save_connection(
                            session,
                            user.id,
                            "plaid",
                            access_token=rec.get("access_token") or "",
                            item_id=rec.get("item_id") or "",
                            merge_refresh=False,
                        )
                        print(f"Imported Plaid connection (was bucket {uid!r}).")
                        imported = True
                        break
                if not imported:
                    print("No Plaid access token in legacy file.")
            else:
                print("No legacy Plaid file; skipping.")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
