#!/usr/bin/env python3
"""Filter, dedupe and file candidates from a proactive-discovery model run.

The model is asked for a strict ``DISCOVERY: <n>`` + ``## Candidate``
markdown message.  This helper is deliberately deterministic: it decides
what becomes a GitHub issue, so a chatty model cannot flood the builder
queue.  Rules:

  * only ``Confidence: high`` findings are filed (the rest are reported
    as rejected so the run log still shows what the model considered),
  * every finding must cite a real ``path:line`` in ``Where``,
  * duplicates are rejected by fingerprint marker and by fuzzy title
    against open/closed issues, open PRs, and the local index,
  * at most ``--max`` issues are filed per run.

Issue creation goes through ``gh issue create --body-file`` (never a
shell-evaluated body).  ``--dry-run`` prints the selection and files
nothing, which is how the prompt/parser is tested without touching the
queue.

Exit codes: 0 ok (even when nothing was filed) · 2 unparseable model
output · 3 all attempted creates failed.
"""

from __future__ import annotations

import argparse
import datetime as dt
import difflib
import json
import os
import re
import subprocess
import sys
import tempfile

FIELDS = (
    "title",
    "severity",
    "confidence",
    "fingerprint",
    "where",
    "impact",
    "evidence",
    "scope",
    "test",
)

FIELD_RE = re.compile(
    r"^(Title|Severity|Confidence|Fingerprint|Where|User impact|Evidence|"
    r"Suggested scope|Test idea):\s*(.*)$"
)
FP_RE = re.compile(r"<!--\s*discovered:\s*([a-z0-9][a-z0-9-]{1,79})\s*-->")
PATH_LINE_RE = re.compile(
    r"[\w./@-]+\.(?:dart|py|json|ya?ml|sh|md|html|css|js|ts):\d+"
)
BAD_TITLE_RE = re.compile(r"\b(fix(?:es|ed)?|close[sd]?|resolve[sd]?)\s+#\d+", re.I)
PLACEHOLDER_RE = re.compile(r"^(?:<[^>]+>|\.\.\.|tbd|todo|n/?a)$", re.I)
SECRET_RE = re.compile(
    r"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|"
    r"sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|"
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[baprs]-[A-Za-z0-9-]{10,})"
)
HOST_PATH_RE = re.compile(r"/(?:home|Users)/[A-Za-z0-9._-]+/")

SEVERITY_RANK = {"high": 0, "medium": 1, "low": 2}
ALLOWED_SEVERITY = set(SEVERITY_RANK)
ALLOWED_CONFIDENCE = {"high", "medium", "low"}


def slugify(text: str) -> str:
    text = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return re.sub(r"-{2,}", "-", text)[:60].strip("-")


def norm_title(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", (text or "").lower()).strip()


def load_json(path: str | None, default):
    if not path or not os.path.exists(path):
        return default
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def parse_candidates(text: str) -> list[dict[str, str]]:
    """Return candidate dicts from the model's markdown.

    Unknown prose is ignored; a field ends at the next field or blank line.
    This mirrors the prompt contract without demanding byte-perfect output.
    """
    candidates: list[dict[str, str]] = []
    current: dict[str, list[str]] | None = None
    field: str | None = None

    for raw in text.splitlines():
        line = raw.rstrip()
        if line.strip() == "## Candidate":
            if current is not None:
                candidates.append({key: "\n".join(value).strip() for key, value in current.items()})
            current = {key: [] for key in FIELDS}
            field = None
            continue
        if current is None:
            continue
        match = FIELD_RE.match(line.strip())
        if match:
            field = match.group(1).lower()
            field = {
                "user impact": "impact",
                "suggested scope": "scope",
                "test idea": "test",
            }.get(field, field)
            if field in current:
                value = match.group(2).strip()
                if value:
                    current[field].append(value)
            continue
        if field and line.strip() and not line.strip().startswith("```"):
            current[field].append(line.strip())
        elif not line.strip():
            field = None

    if current is not None:
        candidates.append({key: "\n".join(value).strip() for key, value in current.items()})
    return candidates


def existing_markers(issues: list[dict], prs: list[dict], index: dict) -> tuple[set[str], list[str]]:
    fingerprints: set[str] = set(index.get("fingerprints", {}).keys())
    titles: list[str] = [entry.get("title", "") for entry in index.get("fingerprints", {}).values()]

    for item in list(issues) + list(prs):
        body = item.get("body") or ""
        fingerprints.update(FP_RE.findall(body))
        if item.get("title"):
            titles.append(item["title"])
    return fingerprints, titles


def reject_reason(candidate: dict[str, str], fingerprints: set[str], titles: list[str]) -> str | None:
    title = " ".join(candidate.get("title", "").split())
    if not title:
        return "missing title"
    if len(title) < 10 or len(title) > 110:
        return "title length outside 10..110"
    if BAD_TITLE_RE.search(title):
        return "title looks like a commit message that auto-closes another issue"

    fingerprint = candidate.get("fingerprint", "").strip().lower()
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,79}", fingerprint):
        return "missing/invalid fingerprint"
    if fingerprint in fingerprints:
        return "duplicate fingerprint"

    confidence = candidate.get("confidence", "").strip().lower()
    if confidence not in ALLOWED_CONFIDENCE:
        return "missing/invalid confidence"
    if confidence != "high":
        return "confidence is not high"

    severity = candidate.get("severity", "").strip().lower()
    if severity not in ALLOWED_SEVERITY:
        return "missing/invalid severity"

    where = " ".join(candidate.get("where", "").split())
    if not PATH_LINE_RE.search(where):
        return "Where does not cite a path:line"

    for field in ("impact", "evidence", "scope", "test"):
        value = candidate.get(field, "").strip()
        if len(value) < 12:
            return f"{field} is too short"
        if PLACEHOLDER_RE.match(value):
            return f"{field} is a template placeholder"

    # The repo is public and the audit reads untrusted issue/PR text. Never
    # let a prompt-injected candidate publish host paths or token-shaped
    # strings into a new issue.
    blob = "\n".join(candidate.get(field, "") for field in FIELDS)
    if SECRET_RE.search(blob):
        return "contains a token/private-key-shaped string"
    if HOST_PATH_RE.search(blob):
        return "contains an absolute host path"
    if len(blob) > 12000:
        return "candidate is too long (possible dump)"

    normalized = norm_title(title)
    for existing in titles:
        other = norm_title(existing)
        if not other:
            continue
        if normalized == other or difflib.SequenceMatcher(None, normalized, other).ratio() >= 0.88:
            return f"similar to existing: {existing[:80]}"

    return None


def issue_body(candidate: dict[str, str], now: str) -> str:
    fingerprint = candidate["fingerprint"].strip().lower()
    return (
        f"Severity: {candidate['severity'].strip().lower()} · "
        f"Confidence: {candidate['confidence'].strip().lower()}\n\n"
        f"## What the user sees\n{candidate['impact'].strip()}\n\n"
        f"## Where\n{candidate['where'].strip()}\n\n"
        f"## Evidence\n{candidate['evidence'].strip()}\n\n"
        f"## Suggested scope\n{candidate['scope'].strip()}\n\n"
        f"## Test idea\n{candidate['test'].strip()}\n\n"
        "---\n"
        f"Filed by the loop's proactive discovery audit on {now}. The audit "
        "was read-only: no code or data was changed.\n"
        "This issue is in the normal queue — comment `deny <reason>` to stop it.\n\n"
        "<!-- agent-discovery -->\n"
        f"<!-- discovered: {fingerprint} -->\n"
    )


def gh_create(repo: str, candidate: dict[str, str], now: str) -> tuple[bool, str]:
    title = " ".join(candidate["title"].split())
    body = issue_body(candidate, now)
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as handle:
        handle.write(body)
        body_path = handle.name
    command = ["gh", "issue", "create"]
    if repo:
        command += ["--repo", repo]
    command += [
        "--title",
        title,
        "--body-file",
        body_path,
        "--label",
        "agent-pending",
        "--label",
        "agent-discovered",
    ]
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
    parser.add_argument("--input", required=True, help="model final message")
    parser.add_argument("--open", dest="open_issues", help="gh issue list JSON (open)")
    parser.add_argument("--closed", dest="closed_issues", help="gh issue list JSON (closed)")
    parser.add_argument("--prs", help="gh pr list JSON (open)")
    parser.add_argument("--index", required=True, help="persistent fingerprint index JSON")
    parser.add_argument("--repo", default="", help="owner/name for gh (omit when cwd is the repo)")
    parser.add_argument("--max", type=int, default=2)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    try:
        with open(args.input, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        print(f"[discover-filter] cannot read model output: {exc}", file=sys.stderr)
        return 2

    if not re.search(r"^DISCOVERY:\s*\d+\s*$", text, re.M):
        print("[discover-filter] model output has no DISCOVERY: <n> line", file=sys.stderr)
        return 2

    open_issues = load_json(args.open_issues, [])
    closed_issues = load_json(args.closed_issues, [])
    prs = load_json(args.prs, [])
    index = load_json(args.index, {"fingerprints": {}})
    if not isinstance(index.get("fingerprints"), dict):
        index = {"fingerprints": {}}

    fingerprints, titles = existing_markers(open_issues + closed_issues, prs, index)
    parsed = parse_candidates(text)
    selected: list[dict[str, str]] = []
    rejected: list[dict[str, str]] = []

    for candidate in parsed:
        reason = reject_reason(candidate, fingerprints, titles)
        if reason:
            rejected.append({"title": " ".join(candidate.get("title", "").split()), "reason": reason})
            continue
        selected.append(candidate)
        # Reserve the fingerprint/title immediately so two blocks in one
        # message cannot file the same root cause twice.
        fingerprints.add(candidate["fingerprint"].strip().lower())
        titles.append(candidate["title"])

    selected.sort(
        key=lambda candidate: (
            SEVERITY_RANK.get(candidate["severity"].strip().lower(), 9),
            0 if candidate["confidence"].strip().lower() == "high" else 1,
        )
    )
    overflow = selected[args.max :]
    selected = selected[: max(args.max, 0)]
    for candidate in overflow:
        rejected.append({"title": " ".join(candidate["title"].split()), "reason": "per-run cap"})

    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    filed: list[dict[str, str]] = []
    errors: list[dict[str, str]] = []

    for candidate in selected:
        title = " ".join(candidate["title"].split())
        if args.dry_run:
            print(f"[discover-filter] dry-run would file: {title}", file=sys.stderr)
            continue
        ok, detail = gh_create(args.repo, candidate, now)
        if not ok:
            errors.append({"title": title, "error": detail[:500]})
            print(f"[discover-filter] create failed for {title!r}: {detail}", file=sys.stderr)
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
        print(f"[discover-filter] filed #{number or '?'}: {title}", file=sys.stderr)

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
            print(f"[discover-filter] could not update index: {exc}", file=sys.stderr)

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
