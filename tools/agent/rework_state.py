#!/usr/bin/env python3
"""Pure rework policy, including compatibility with the old comment markers."""
import json
import re
import sys


def policy(comments, sha):
    bodies = [row.get("body") or "" for row in comments]
    rounds = sum("<!-- agent-rework -->" in body for body in bodies)
    tier = min(2, rounds // 2)
    reviews = [b for b in bodies if "<!-- agent-review -->" in b]
    last = reviews[-1] if reviews else ""
    current = f"<!-- agent-review --> sha={sha}" in last
    # An escalated model adjudicates before spending another builder run.
    adjudicate = not current or (tier > 0 and f"tier={tier}" not in last)
    return rounds, tier, int(adjudicate)


if __name__ == "__main__":
    data = json.load(sys.stdin)
    print(*policy(data["comments"], sys.argv[1]))
