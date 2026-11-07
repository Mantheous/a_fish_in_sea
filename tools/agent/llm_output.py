#!/usr/bin/env python3
"""Extract final messages from structured CLI output; never accept an error as prose."""
import json
import sys


def extract(backend, text):
    if backend == "antigravity":
        result = json.loads(text)
        if result.get("status") != "SUCCESS":
            raise ValueError("Antigravity did not report SUCCESS")
        response = result.get("response")
        if not isinstance(response, str):
            raise ValueError("Antigravity response is missing")
        return response
    messages = []
    for line in text.splitlines():
        row = json.loads(line)
        if row.get("type") == "error":
            raise ValueError("OpenCode emitted an error event")
        if row.get("type") == "step_start":
            messages = []
        if row.get("type") == "text":
            messages.append(row["part"]["text"])
    return "\n".join(messages)


if __name__ == "__main__":
    try:
        print(extract(sys.argv[1], open(sys.argv[2]).read()))
    except (ValueError, KeyError, TypeError) as error:
        print(f"[llm-run] invalid structured output: {error}", file=sys.stderr)
        sys.exit(3)
