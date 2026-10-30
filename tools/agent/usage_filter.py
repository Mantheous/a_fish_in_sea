#!/usr/bin/env python3
"""Filter and file candidates from the proactive usage review.

Reuses the discovery filter's parser, dedupe and safety checks
(``discover_filter.py``) so usage findings land in the same queue and
cannot duplicate or leak host paths/tokens. Differences:

  * fingerprints are prefixed ``usage-unused-`` / ``usage-fix-`` /
    ``usage-friction-``; an unused-feature finding carries the
    ``usage-unused`` label and the human-merge warning in its body,
  * every issue carries ``usage-finding`` (plus ``agent-pending`` and
    ``agent-discovered``), so the operator can filter them,
  * a removal candidate is only filed by ``usage-review.sh`` after the
    digest has proven zero uses over the window; the builder still has to
    capture a before screenshot and a human merges that PR.

Usage (called by usage-review.sh):
  usage_filter.py --input MSG --open OPEN.json --closed CLOSED.json \
      --prs PRS.json --index STATE/usage-index.json --max 2
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from discover_filter import (  # noqa: E402
    FIELDS,
    existing_markers,
    load_json,
    parse_candidates,
    reject_reason,
)


def _repo_slug(repo: str) -> list[str]:
    return ["--repo", repo] if repo else []


def _ensure_labels(repo: str) -> None:
    for name, color, description in (
        ("usage-finding", "0E8A16", "Filed by the loop's proactive usage review"),
        (
            "usage-unused",
            "FBCA04",
            "Unused-feature removal candidate: needs a before screenshot + human merge",
        ),
    ):
        command = ["gh", "label", "create", name, "--color", color, "--description", description]
        command += _repo_slug(repo)
        subprocess.run(command, capture_output=True, text=True)


def _is_removal(candidate: dict[str, str]) -> bool:
    return candidate.get("fingerprint", "").strip().lower().startswith("usage-unused-")


def _secret_values() -> set[str]:
    """Values from local .env files, so a read-only model cannot quote one
    into a public issue. Only long values are used to avoid false positives
    on common words/flags; the strings never leave this process."""
    values: set[str] = set()
    for path in (".env", "server/api/.env", "server/.env"):
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    _, value = line.split("=", 1)
                    value = value.strip().strip('"').strip("'")
                    if len(value) >= 12:
                        values.add(value)
        except OSError:
            continue
    return values


def _body(candidate: dict[str, str], now: str) -> str:
    fingerprint = candidate["fingerprint"].strip().lower()
    labels = "Removal candidate" if _is_removal(candidate) else "Usage finding"
    removal = ""
    if _is_removal(candidate):
        removal = (
            "\n## Before removing\n"
            "The builder must capture a screenshot of this feature before deleting it "
            "and put the screenshot path in the PR body. The PR must be labeled "
            "`needs-human-merge`; the loop never auto-merges feature removals. "
            "If the feature is newer than 30 days, still in active development, or "
            "overlaps a preferred path, close this issue instead of removing it.\n"
        )
    return (
        f"{labels} · Severity: {candidate['severity'].strip().lower()} · "
        f"Confidence: {candidate['confidence'].strip().lower()}\n\n"
        f"## What the user sees\n{candidate['impact'].strip()}\n\n"
        f"## Usage evidence\n{candidate['evidence'].strip()}\n\n"
        f"## Where\n{candidate['where'].strip()}\n\n"
        f"## Suggested scope\n{candidate['scope'].strip()}\n\n"
        f"## Test idea\n{candidate['test'].strip()}\n"
        f"{removal}\n"
        "---\n"
        f"Filed by the loop's proactive usage review on {now}. The review is "
        "read-only: it reads the content-free local usage log and the deployed "
        "bundle. No code or data was changed.\n"
        "This issue is in the normal queue — comment `deny <reason>` to stop it.\n\n"
        "<!-- agent-usage -->\n"
        "<!-- discovered: " + fingerprint + " -->\n"
        f"<!-- usage-finding: {fingerprint} -->\n"
    )


def _create(repo: str, candidate: dict[str, str], now: str) -> tuple[bool, str]:
    title = " ".join(candidate["title"].split())
    body = _body(candidate, now)
    labels = ["agent-pending", "agent-discovered", "usage-finding"]
    if _is_removal(candidate):
        labels.append("usage-unused")
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as handle:
        handle.write(body)
        body_path = handle.name
    command = ["gh", "issue", "create"]
    command += _repo_slug(repo)
    command += ["--title", title, "--body-file", body_path]
    for label in labels:
        command += ["--label", label]
    try:
        result = subprocess.run(command, capture_output=True, text=True)
    finally:
        try:
            os.unlink(body_path)
        except OSError:
            pass
    if result.returncode != 0:
        return False, (result.stderr or result.stdout or "gh issue create failed").strip()
    return True, (result.stdout or "").strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--open", dest="open_issues")
    parser.add_argument("--closed", dest="closed_issues")
    parser.add_argument("--prs")
    parser.add_argument("--index", required=True)
    parser.add_argument("--repo", default="")
    parser.add_argument("--max", type=int, default=2)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    try:
        text = open(args.input, encoding="utf-8").read()
    except OSError as exc:
        print(f"[usage-filter] cannot read model output: {exc}", file=sys.stderr)
        return 2
    if not re.search(r"^DISCOVERY:\s*\d+\s*$", text, re.M):
        print("[usage-filter] model output has no DISCOVERY: <n> line", file=sys.stderr)
        return 2

    open_issues = load_json(args.open_issues, [])
    closed_issues = load_json(args.closed_issues, [])
    prs = load_json(args.prs, [])
    index = load_json(args.index, {"fingerprints": {}})
    if not isinstance(index.get("fingerprints"), dict):
        index = {"fingerprints": {}}

    fingerprints, titles = existing_markers(open_issues + closed_issues, prs, index)
    parsed = parse_candidates(text)
    secrets = _secret_values()
    selected: list[dict[str, str]] = []
    rejected: list[dict[str, str]] = []

    for candidate in parsed:
        reason = reject_reason(candidate, fingerprints, titles)
        if reason:
            rejected.append(
                {"title": " ".join(candidate.get("title", "").split()), "reason": reason}
            )
            continue
        fingerprint = candidate["fingerprint"].strip().lower()
        if not fingerprint.startswith(("usage-unused-", "usage-fix-", "usage-friction-")):
            rejected.append(
                {
                    "title": " ".join(candidate.get("title", "").split()),
                    "reason": "usage fingerprint must start with usage-unused-/usage-fix-/usage-friction-",
                }
            )
            continue
        # Removal language must use the removal fingerprint. Otherwise a
        # usage-fix-* issue could ship a deletion without the human-merge
        # label/marker that the builder rule keys on.
        if not fingerprint.startswith("usage-unused-"):
            text = " ".join(
                candidate.get(field, "")
                for field in ("title", "impact", "evidence", "scope")
            )
            if re.search(r"\b(remove|delete|drop|retire|unregister)\b", text, re.I):
                rejected.append(
                    {
                        "title": " ".join(candidate.get("title", "").split()),
                        "reason": "removal language requires a usage-unused- fingerprint",
                    }
                )
                continue
        # A read-only model can read server/api/.env. Never let a candidate
        # publish an exact value from it, even if it is not token-shaped.
        if secrets:
            blob = "\n".join(candidate.get(field, "") for field in FIELDS)
            if any(secret in blob for secret in secrets):
                rejected.append(
                    {
                        "title": " ".join(candidate.get("title", "").split()),
                        "reason": "contains a value from the server environment",
                    }
                )
                continue
        selected.append(candidate)
        fingerprints.add(fingerprint)
        titles.append(candidate["title"])

    selected = selected[: max(args.max, 0)]
    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if not args.dry_run:
        _ensure_labels(args.repo)

    filed: list[dict[str, str]] = []
    errors: list[dict[str, str]] = []
    for candidate in selected:
        title = " ".join(candidate["title"].split())
        if args.dry_run:
            print(f"[usage-filter] dry-run would file: {title}", file=sys.stderr)
            continue
        ok, detail = _create(args.repo, candidate, now)
        if not ok:
            errors.append({"title": title, "error": detail[:500]})
            print(f"[usage-filter] create failed for {title!r}: {detail}", file=sys.stderr)
            continue
        number = 0
        match = re.search(r"/issues/(\d+)", detail)
        if match:
            number = int(match.group(1))
        filed.append({"number": number, "title": title, "url": detail})
        index["fingerprints"][candidate["fingerprint"].strip().lower()] = {
            "number": number,
            "title": title,
            "filed_at": now,
        }
        print(f"[usage-filter] filed #{number or '?'}: {title}", file=sys.stderr)

    if not args.dry_run and filed:
        state_dir = os.path.dirname(os.path.abspath(args.index))
        try:
            os.makedirs(state_dir, exist_ok=True)
            tmp = f"{args.index}.tmp"
            with open(tmp, "w", encoding="utf-8") as handle:
                json.dump(index, handle, indent=2, sort_keys=True)
                handle.write("\n")
            os.replace(tmp, args.index)
        except OSError as exc:
            print(f"[usage-filter] could not update index: {exc}", file=sys.stderr)

    summary = {
        "candidates": len(parsed),
        "selected": len(selected),
        "filed": filed,
        "errors": errors,
        "rejected": rejected,
        "dry_run": args.dry_run,
    }
    print(json.dumps(summary, indent=2))
    if not args.dry_run and selected and not filed:
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
