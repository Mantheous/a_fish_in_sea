#!/usr/bin/env python3
"""Bounded, content-free run accounting. Prompts/tool output never enter the ledger."""
import argparse
import collections
import fcntl
import json
import os
from pathlib import Path
import time

from capacity import pool_for, read_json, state_dir


def usage(path, backend):
    counts = {}
    try:
        with open(path) as handle:
            for line in handle:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if backend == "antigravity":
                    values = row.get("usage", {})
                elif backend == "codex" and row.get("type") == "turn.completed":
                    values = row.get("usage", {})
                elif backend == "opencode" and row.get("type") == "step_finish":
                    token = row.get("part", {}).get("tokens", {})
                    values = dict(input_tokens=token.get("input"), output_tokens=token.get("output"),
                        cache_read_tokens=(token.get("cache") or {}).get("read"))
                else:
                    continue
                for key in ("input_tokens", "output_tokens", "cached_input_tokens", "cache_read_tokens", "thinking_tokens"):
                    if isinstance(values.get(key), int):
                        counts[key] = counts.get(key, 0) + max(0, values[key])
    except OSError:
        pass
    return counts


def record(args):
    state = state_dir()
    state.mkdir(parents=True, exist_ok=True)
    pool = pool_for(args.backend, args.model)
    row = dict(at=time.time(), role=args.role, backend=args.backend, pool=pool,
               model=args.model, tier=args.tier, seconds=args.seconds, exit=args.exit,
               tokens=usage(args.output, args.backend))
    # Lock across writers; keep at most 20,000 metadata rows (~weeks).
    with (state / "runs.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = state / "runs.jsonl"
        if path.exists() and path.stat().st_size > 8_000_000:
            path.write_text("\n".join(path.read_text().splitlines()[-10000:]) + "\n")
        with path.open("a") as handle:
            handle.write(json.dumps(row) + "\n")
        if args.limited:
            # Use the provider's observed reset when available; otherwise retry
            # after one poll. A five-hour blind sleep can waste a whole window.
            from capacity import snapshots
            resets = [w["resets_at"] for w in snapshots(time.time()).get(pool, {}).values()
                      if w["used_percent"] >= 98]
            until = max(resets, default=time.time() + 900)
            (state / f"cooldown-{pool}.json").write_text(json.dumps(dict(until=until)))


def summary():
    groups = collections.defaultdict(lambda: dict(runs=0, failures=0, seconds=0, tokens=0))
    path = state_dir() / "runs.jsonl"
    if path.exists():
        for line in path.read_text().splitlines():
            try:
                row = json.loads(line)
                if row["at"] < time.time() - 7 * 86400:
                    continue
                bucket = groups[f'{row["role"]}/{row["backend"]}/tier{row["tier"]}']
                bucket["runs"] += 1
                bucket["failures"] += row["exit"] != 0
                bucket["seconds"] += row["seconds"]
                bucket["tokens"] += sum(v for k, v in row["tokens"].items()
                                        if k in ("input_tokens", "output_tokens"))
            except (ValueError, KeyError, TypeError):
                continue
    print(json.dumps(dict(period_days=7, groups=groups), indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["record", "summary", "start"])
    for key in ("role", "backend", "model", "output"):
        parser.add_argument(f"--{key}", default="")
    for key in ("tier", "seconds", "exit"):
        parser.add_argument(f"--{key}", type=int, default=0)
    parser.add_argument("--limited", action="store_true")
    args = parser.parse_args()
    if args.command == "record":
        record(args)
    elif args.command == "summary":
        summary()
    elif args.role == "builder":
        state_dir().mkdir(parents=True, exist_ok=True)
        (state_dir() / "last-builder.json").write_text(json.dumps(dict(pool=pool_for(args.backend, args.model))))
