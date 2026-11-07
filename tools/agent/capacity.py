#!/usr/bin/env python3
"""Quota pacing. Percentages come from provider observations, never token estimates.

External snapshots: $AGENT_STATE_DIR/quota.json (see LOOP.md). Codex is also
read from token_count events in its local session logs; no conversation content
is retained. Unknown/stale limits keep conservative defaults, not fictional 0%.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import time

TARGET = 90
PERIODS = {"codex": "weekly", "antigravity": "weekly", "antigravity-3p": "weekly", "opencode": "monthly"}


def state_dir():
    return Path(os.environ.get("AGENT_STATE_DIR", str(Path(os.environ.get(
        "XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "a_fish_in_sea")))


def read_json(path, default):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return default


def timestamp(value):
    if isinstance(value, (int, float)):
        return float(value)
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def codex_snapshot(now):
    root = Path(os.environ.get("AGENT_CODEX_SESSIONS", str(Path.home() / ".codex/sessions")))
    # Inspect only recent files and bounded tails; never ingest a whole conversation.
    paths = []
    for days in range(3):
        day = dt.datetime.fromtimestamp(now, dt.timezone.utc) - dt.timedelta(days=days)
        paths.extend((root / day.strftime("%Y/%m/%d")).glob("*.jsonl"))
    paths.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    best = {}
    for path in paths[:20]:
        try:
            with path.open("rb") as handle:
                handle.seek(max(0, path.stat().st_size - 262144))
                lines = handle.read().splitlines()
            for line in reversed(lines):
                try:
                    row = json.loads(line)
                    payload = row.get("payload", {})
                    if row.get("type") != "event_msg" or payload.get("type") != "token_count":
                        continue
                    limits = payload.get("rate_limits") or {}
                    observed = timestamp(row["timestamp"])
                    for key in ("primary", "secondary"):
                        item = limits.get(key) or {}
                        minutes = item.get("window_minutes")
                        period = {300: "five_hour", 10080: "weekly"}.get(minutes)
                        if period and observed > best.get(period, {}).get("observed_at", 0):
                            best[period] = dict(used_percent=item["used_percent"],
                                resets_at=item["resets_at"], starts_at=item["resets_at"] - minutes * 60,
                                observed_at=observed)
                except (ValueError, KeyError, TypeError):
                    continue
        except OSError:
            continue
    return best


def valid_window(row, now):
    try:
        used = float(row["used_percent"])
        start, reset, observed = (timestamp(row[k]) for k in ("starts_at", "resets_at", "observed_at"))
        if not (0 <= used <= 100 and start <= now < reset and 0 <= now - observed <= 1800):
            return None
        return dict(used_percent=used, starts_at=start, resets_at=reset, observed_at=observed)
    except (ValueError, KeyError, TypeError, AttributeError):
        return None


def snapshots(now):
    raw = read_json(os.environ.get("AGENT_QUOTA_FILE", str(state_dir() / "quota.json")), {})
    if not isinstance(raw, dict):
        raw = {}
    raw["codex"] = {**(raw.get("codex") or {}), **codex_snapshot(now)}
    raw["opencode"] = {**(raw.get("opencode") or {}), **read_json(state_dir() / "opencode-quota.json", {})}
    agy = read_json(state_dir() / "agy-quota.json", {})
    for provider, prefix in (("antigravity", "gemini"), ("antigravity-3p", "3p")):
        raw.setdefault(provider, {})
        for period, suffix, seconds in (("five_hour", "5h", 18000), ("weekly", "weekly", 604800)):
            row = agy.get(f"{prefix}-{suffix}", {})
            if row and not row.get("disabled"):
                raw[provider][period] = {**row, "starts_at": row["resets_at"] - seconds}
    result = {}
    for provider in PERIODS:
        result[provider] = {}
        for period in dict.fromkeys(("five_hour", "weekly", PERIODS[provider])):
            item = valid_window((raw.get(provider) or {}).get(period), now)
            if item:
                result[provider][period] = item
    return result


def pace(provider, windows, now):
    period = windows.get(PERIODS[provider])
    short = windows.get("five_hour")
    if any(w["used_percent"] >= TARGET for w in windows.values()):
        return "reserve"
    if not period:
        return "unknown"
    elapsed = (now - period["starts_at"]) / (period["resets_at"] - period["starts_at"])
    # Two percentage points of hysteresis prevents toggling every poll.
    if period["used_percent"] < TARGET * elapsed - 2 and (not short or short["used_percent"] < 80):
        return "spare"
    if period["used_percent"] > TARGET * elapsed + 5:
        return "ahead"
    return "steady"


def pool_for(backend, model):
    # OpenCode is a harness too: an Antigravity provider is the same allowance
    # whether accessed via agy or OpenCode. Never double-count it as Go quota.
    if backend == "antigravity" or "antigravity" in model.lower():
        return "antigravity-3p" if any(x in model.lower() for x in ("claude", "gpt-oss")) else "antigravity"
    return backend


def allowed(provider, role, now=None):
    now = time.time() if now is None else now
    windows = snapshots(now).get(provider, {})
    optional = role in ("builder", "discover", "harness", "usage")
    for window in windows.values():
        if window["used_percent"] >= (TARGET if optional else 98):
            return False
    cooldown = read_json(state_dir() / f"cooldown-{provider}.json", {})
    return cooldown.get("until", 0) <= now


def plan(now):
    quotas = snapshots(now)
    modes = {p: pace(p, w, now) for p, w in quotas.items()}
    # Alternate actual builder starts, not poll numbers. A full queue never
    # blocks the other provider just because one subscription is exhausted.
    last = read_json(state_dir() / "last-builder.json", {}).get("pool", "antigravity")
    ring = ["codex", "antigravity", "antigravity-3p", "opencode"]
    offset = (ring.index(last) + 1) % len(ring) if last in ring else 0
    preferred = ring[offset:] + ring[:offset]
    available = [p for p in preferred if allowed(p, "builder", now) and modes[p] != "reserve"
                 and (modes[p] != "unknown" or p == "codex")]
    chosen = next(iter(available), "")
    # When a provider is ahead of pace, prefer a known subscription behind it.
    if chosen and modes[chosen] == "ahead":
        chosen = next((p for p in available if modes[p] in ("spare", "steady")), chosen)
    spare = any(m == "spare" for m in modes.values())
    exports = {
        "AGENT_DISCOVER_MIN_INTERVAL_S": 1800 if spare else 21600,
        "AGENT_DISCOVER_QUEUE_LOW": 4 if spare else 2,
        "AGENT_DISCOVER_MAX_INFLIGHT": 5 if spare else 3,
        "AGENT_HARNESS_INTERVAL_S": 18000 if spare else 86400,
    }
    if chosen and os.environ.get("AGENT_CAPACITY_ROUTE_BUILDERS", "1") == "1":
        exports["FISH_LLM_BUILDER_BACKEND"] = "antigravity" if chosen == "antigravity-3p" else chosen
        if chosen.startswith("antigravity"):
            exports["FISH_LLM_BUILDER_MODEL"] = "claude-opus-4-6-thinking" if chosen.endswith("3p") else "gemini-3.8-flash-high"
    return dict(target_percent=TARGET, modes=modes, quotas=quotas, exports=exports)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["plan", "allow", "report"])
    parser.add_argument("--pool", choices=list(PERIODS))
    parser.add_argument("--role", default="builder")
    args = parser.parse_args()
    now = time.time()
    if args.command == "allow":
        raise SystemExit(0 if allowed(args.pool, args.role, now) else 75)
    result = plan(now)
    if args.command == "plan":
        for key, value in result["exports"].items():
            # Values are closed-set backend names or integers, safe to export.
            print(f"{key}={value}")
    else:
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
