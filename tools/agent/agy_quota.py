#!/usr/bin/env python3
"""Read agy's documented statusLine quota feed without submitting a model prompt.

The TUI starts on a private PTY, emits its initial status, then exits. Nothing
is typed into its prompt. The callback retains only quota buckets and times.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shlex
import shutil
import signal
import subprocess
import sys
import time

from capacity import read_json, state_dir, timestamp


def ingest(data):
    now = time.time()
    buckets = {}
    for key, item in (data.get("quota") or {}).items():
        try:
            fraction = float(item["remaining_fraction"])
            reset = timestamp(item["reset_time"])
            if not (0 <= fraction <= 1 and reset > now):
                continue
            # Preserve bucket identity: Gemini and Claude allowances differ.
            buckets[key] = dict(used_percent=100 * (1 - fraction), resets_at=reset,
                                observed_at=now, disabled=bool(item.get("disabled")))
        except (ValueError, KeyError, TypeError):
            continue
    if buckets:
        state = state_dir()
        state.mkdir(parents=True, exist_ok=True)
        with (state / "agy-quota.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            path = state / "agy-quota.json"
            temp = path.with_suffix(".tmp")
            temp.write_text(json.dumps(buckets))
            temp.replace(path)


def collect():
    binary = os.environ.get("FISH_LLM_AGY_BIN") or shutil.which("agy") or str(Path.home() / ".local/bin/agy")
    if not Path(binary).is_file():
        return
    state_dir().mkdir(parents=True, exist_ok=True)
    with (state_dir() / "agy-collect.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        path = state_dir() / "agy-quota.json"
        if path.exists() and time.time() - path.stat().st_mtime < 600:
            return
        before = path.stat().st_mtime if path.exists() else 0
        callback = shlex.join([sys.executable, str(Path(__file__).resolve()), "--ingest"])
        settings = json.dumps(dict(useG1Credits=False, statusLine=dict(
            type="command", command=callback, enabled=True)))
        master, slave = pty.openpty()
        child = subprocess.Popen([binary, "--settings", settings], stdin=slave,
            stdout=slave, stderr=slave, start_new_session=True, env={**os.environ, "TERM": "xterm-256color"})
        os.close(slave)
        try:
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline and child.poll() is None:
                if path.exists() and path.stat().st_mtime > before:
                    break
                if select.select([master], [], [], 0.2)[0]:
                    try:
                        os.read(master, 65536)  # discard TUI content
                    except OSError:
                        break
        finally:
            os.close(master)
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
        print("[capacity] agy quota " + ("refreshed" if path.exists() and path.stat().st_mtime > before else "unavailable"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ingest", action="store_true")
    args = parser.parse_args()
    ingest(json.load(sys.stdin)) if args.ingest else collect()
