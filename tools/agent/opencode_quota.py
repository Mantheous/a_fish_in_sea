#!/usr/bin/env python3
"""Observe Go quota using the same active Console credential as OpenCode.

The installed server may predate /api/experimental/usage/limits. Its upstream
Go endpoint is used directly; keys/tokens and account metadata never leave
this process except in the Authorization header to opencode.ai.
"""
import calendar
import datetime as dt
import json
from pathlib import Path
import sqlite3
import time
import urllib.request

from capacity import state_dir, timestamp


def credential():
    path = Path.home() / ".local/share/opencode/opencode.db"
    with sqlite3.connect(f"file:{path}?mode=ro", uri=True) as conn:
        row = conn.execute("SELECT value FROM credential WHERE integration_id='opencode' AND active=1").fetchone()
        if row:
            data = json.loads(row[0])
            if data.get("type") == "oauth":
                if data.get("expires", 0) < time.time() * 1000:
                    raise ValueError("active Console credential expired; let OpenCode refresh it")
                return data["access"], (data.get("metadata") or {}).get("orgID")
        row = conn.execute("SELECT value FROM credential WHERE integration_id='opencode-go' ORDER BY active DESC LIMIT 1").fetchone()
        if row:
            return json.loads(row[0])["key"], None
    raise ValueError("no Go credential")


def normalize(data, now):
    data = data.get("usage", data)
    result = {}
    for key, period, seconds in (("rollingUsage", "five_hour", 18000),
                                  ("weeklyUsage", "weekly", 604800),
                                  ("monthlyUsage", "monthly", None)):
        row = data.get(key) or data.get({"rollingUsage":"rolling", "weeklyUsage":"weekly", "monthlyUsage":"monthly"}[key]) or {}
        try:
            used = float(row["percent"])
            reset = timestamp(row.get("resetsAt", row.get("resetAt")))
            if not 0 <= used <= 100:
                continue
            if seconds:
                start = reset - seconds
            else:
                end = dt.datetime.fromtimestamp(reset, dt.timezone.utc)
                year, month = (end.year - 1, 12) if end.month == 1 else (end.year, end.month - 1)
                start = end.replace(year=year, month=month, day=min(end.day,
                    calendar.monthrange(year, month)[1])).timestamp()
            result[period] = dict(used_percent=used, starts_at=start,
                                  resets_at=reset, observed_at=now)
        except (ValueError, TypeError, KeyError):
            continue
    return result


def main():
    try:
        token, org = credential()
        headers = {"Authorization": f"Bearer {token}", "User-Agent": "fish-loop-quota/1.0"}
        if org:
            headers["x-opencode-org-id"] = org
        request = urllib.request.Request("https://opencode.ai/zen/go/v1/usage", headers=headers)
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                return None  # never forward Authorization to a redirected host
        with urllib.request.build_opener(NoRedirect).open(request, timeout=15) as response:
            data = json.load(response)
        result = normalize(data, time.time())
        if not result:
            # Schema names only: never log provider responses or credentials.
            def shape(value, depth=0):
                return {k: shape(v, depth + 1) for k, v in value.items()} if isinstance(value, dict) and depth < 4 else type(value).__name__
            print("[capacity] Go quota schema unsupported: " + json.dumps(shape(data)))
            return
        state_dir().mkdir(parents=True, exist_ok=True)
        path = state_dir() / "opencode-quota.json"
        path.write_text(json.dumps(result))
        print("[capacity] Go quota refreshed: " + ", ".join(
            f"{key}={row['used_percent']:.1f}%" for key, row in result.items()))
    except (OSError, ValueError, KeyError, sqlite3.Error):
        print("[capacity] Go quota unavailable; retaining dated observations")


if __name__ == "__main__":
    main()
