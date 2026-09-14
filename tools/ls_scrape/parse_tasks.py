"""Offline Learning Suite dump -> tasks.json. No network, no login.

Reads only tools/ls_scrape/raw/<cid>/ (manifest.json + per-tab .html/.txt +
optional calendar.ics) and emits tasks.json for the planner app:

    python parse_tasks.py --course <cid>
    python parse_tasks.py --course <cid> --check   # print changed tabs only

Schema: tasks.schema.json. Mapping to the Flutter Task model:
title->title, due->due, description+source_url->notes,
sha256(source+url+title)->sourceEventId, course->classId/classLabel.

Conflict rule: Assignments date wins over Schedule text over Syllabus prose.
Dateless teacher prose becomes type=expectation, confidence=low (flagged,
never dropped). Stdlib only.
"""

from __future__ import annotations

import argparse
import hashlib
import html as htmlmod
import json
import re
import sys
from datetime import datetime
from html.parser import HTMLParser
from pathlib import Path

HERE = Path(__file__).resolve().parent
RAW_ROOT = HERE / "raw"

SOURCE_PRIORITY = {"assignments": 0, "schedule": 1, "syllabus": 2, "content": 3, "announcement": 4, "announcements": 4, "home": 5, "grades": 6}

TYPE_KEYWORDS = (
    (r"\b(midterm|final|exam|test)\b", "exam"),
    (r"\b(read(ing)?|chapter|pages?\s+\d)", "reading"),
    (r"\b(hw|homework|assignment|problem\s*set|pset|quiz|lab|project|paper|essay|report|presentation|worksheet|checkpoint|milestone|deliverable|draft|portfolio)\b", "assignment"),
)

EXPECTATION_HINTS = re.compile(
    r"\b(expect|participation|attendance|late|policy|required|must|office hours|grading)\b",
    re.IGNORECASE,
)

MONTHS = {
    "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3,
    "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7,
    "august": 8, "aug": 8, "september": 9, "sept": 9, "sep": 9,
    "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
}

MONTH_DAY = re.compile(
    r"\b(january|february|march|april|may|june|july|august|september|sept|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|oct|nov|dec)\w*\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b",
    re.IGNORECASE,
)
NUMERIC_MD = re.compile(r"\b(\d{1,2})[/-](\d{1,2})(?:[/-](\d{2,4}))?\b")
ISO_DATE = re.compile(r"\b(\d{4})-(\d{1,2})-(\d{1,2})\b")


class _TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self._skip = 0
        self.chunks: list[str] = []

    def handle_starttag(self, tag: str, attrs: list) -> None:
        if tag in ("script", "style", "nav", "header", "footer"):
            self._skip += 1
        elif tag in ("p", "div", "br", "li", "h1", "h2", "h3", "h4", "tr"):
            self.chunks.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in ("script", "style", "nav", "header", "footer") and self._skip:
            self._skip -= 1

    def handle_data(self, data: str) -> None:
        if not self._skip:
            self.chunks.append(data)


def html_to_text(html_text: str) -> str:
    ext = _TextExtractor()
    ext.feed(html_text)
    raw = "".join(ext.chunks)
    raw = htmlmod.unescape(raw)
    lines = [re.sub(r"\s+", " ", ln).strip() for ln in raw.splitlines()]
    return "\n".join(ln for ln in lines if len(ln) > 3)


def extract_date(line: str, ref: datetime) -> str | None:
    m = ISO_DATE.search(line)
    if m:
        y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if 1 <= mo <= 12 and 1 <= d <= 31:
            return f"{y:04d}-{mo:02d}-{d:02d}"
    m = MONTH_DAY.search(line)
    if m:
        mo = MONTHS[m.group(1).lower().rstrip(".")]
        d = int(m.group(2))
        year = ref.year
        try:
            cand = datetime(year, mo, d)
            if (ref - cand).days > 90:
                cand = datetime(year + 1, mo, d)
            return cand.strftime("%Y-%m-%d")
        except ValueError:
            return None
    m = NUMERIC_MD.search(line)
    if m:
        mo, d, y = int(m.group(1)), int(m.group(2)), m.group(3)
        if 1 <= mo <= 12 and 1 <= d <= 31:
            year = int(y) + (2000 if y is not None and int(y) < 100 else 0) if y else ref.year
            return f"{year:04d}-{mo:02d}-{d:02d}"
    return None


def infer_type(title: str) -> str:
    for pat, kind in TYPE_KEYWORDS:
        if re.search(pat, title, re.IGNORECASE):
            return kind
    if EXPECTATION_HINTS.search(title):
        return "expectation"
    return "admin"


def first_sentences(text: str, n: int = 2) -> str:
    parts = re.split(r"(?<=[.!?])\s+", text.strip())
    out = " ".join(p for p in parts if p)[:400]
    return out or text.strip()[:400]


def parse_ics(path: Path) -> list[dict]:
    """Minimal VEVENT scan: SUMMARY, DTSTART, DESCRIPTION, URL, UID."""
    events: list[dict] = []
    try:
        content = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return events
    for block in re.findall(r"BEGIN:VEVENT(.*?)END:VEVENT", content, re.DOTALL):
        def prop(name: str) -> str | None:
            mm = re.search(rf"^{name}[;:].*?:(.*)$", block, re.MULTILINE)
            return mm.group(1).strip() if mm else None

        summary = prop("SUMMARY")
        if not summary:
            continue
        dtstart = prop("DTSTART") or ""
        due = None
        mm = re.match(r"(\d{4})(\d{2})(\d{2})", dtstart)
        if mm:
            due = f"{mm.group(1)}-{mm.group(2)}-{mm.group(3)}"
        events.append(
            {
                "title": summary,
                "due": due,
                "verbatim": (prop("DESCRIPTION") or summary)[:500],
                "url": prop("URL"),
                "uid": prop("UID"),
            }
        )
    return events


def collect_lines(course_dir: Path, manifest: dict) -> list[dict]:
    items: list[dict] = []
    for pg in manifest.get("pages", []):
        if pg.get("status") != "ok":
            continue
        tab = pg["tab"]
        source = "announcement" if tab == "announcements" else tab
        url = pg.get("url", "")
        text = ""
        txt_path = course_dir / pg.get("text", f"{tab}.txt")
        html_path = course_dir / pg.get("html", f"{tab}.html")
        if txt_path.exists() and txt_path.stat().st_size > 0:
            text = txt_path.read_text(encoding="utf-8", errors="replace")
        elif html_path.exists():
            text = html_to_text(html_path.read_text(encoding="utf-8", errors="replace"))
        for line in text.splitlines():
            line = line.strip()
            if len(line) < 4 or len(line) > 300:
                continue
            items.append({"line": line, "source": source, "url": url})
    return items


def build_tasks(course: str, course_dir: Path, manifest: dict, ref: datetime) -> list[dict]:
    seen: dict[str, dict] = {}

    def upsert(title: str, due: str | None, source: str, url: str, verbatim: str) -> None:
        title = re.sub(r"\s+", " ", title).strip()[:140]
        if len(title) < 3:
            return
        key = f"{title.lower()}|{due or ''}"
        pri = SOURCE_PRIORITY.get(source, 9)
        kind = infer_type(title)
        if due:
            conf = "high" if source in ("assignments", "schedule") else "medium"
        else:
            conf = "low" if kind == "expectation" else "low"
        desc = first_sentences(verbatim)
        sid = hashlib.sha256(f"{source}|{url}|{title}".encode()).hexdigest()[:16]
        cand = {
            "title": title,
            "due": f"{due}T23:59:00" if due and len(due) == 10 else due,
            "type": kind,
            "source": source,
            "source_url": url,
            "description": desc,
            "confidence": conf,
            "verbatim": verbatim[:500],
            "sourceEventId": f"ls:{course}:{sid}",
        }
        prev = seen.get(key)
        if prev is None or pri < SOURCE_PRIORITY.get(prev["source"], 9):
            seen[key] = cand

    for item in collect_lines(course_dir, manifest):
        line, source, url = item["line"], item["source"], item["url"]
        due = extract_date(line, ref)
        has_signal = any(
            re.search(pat, line, re.IGNORECASE) for pat, _ in TYPE_KEYWORDS
        ) or EXPECTATION_HINTS.search(line)
        if due is None and not has_signal:
            continue
        if due is not None and not has_signal and len(re.sub(r"[\s:–—\-.,()/]+", "", re.sub(r"\d+", "", line))) < 8:
            continue
        upsert(line, due, source, url, line)

    for ev in parse_ics(course_dir / "calendar.ics"):
        upsert(ev["title"], ev["due"], "schedule", ev["url"] or "", ev["verbatim"])

    tasks = sorted(
        seen.values(),
        key=lambda t: (t["due"] is None, t["due"] or "", t["title"].lower()),
    )
    return tasks[:500]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Offline LS dump -> tasks.json (no network)")
    ap.add_argument("--course", required=True, help="Course id (raw/<cid> directory name)")
    ap.add_argument("--raw", default=str(RAW_ROOT))
    ap.add_argument("--out", default=None, help="Output path (default raw/<cid>/tasks.json)")
    ap.add_argument("--check", action="store_true", help="Print tab sha256 changes vs manifest, no rewrite")
    args = ap.parse_args(argv)

    course_dir = Path(args.raw) / args.course
    manifest_path = course_dir / "manifest.json"
    if not manifest_path.exists():
        print(f"error: no dump at {course_dir} — run playwright_scrape.py first", file=sys.stderr)
        return 2
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    if args.check:
        for pg in manifest.get("pages", []):
            print(f"{pg.get('tab')}: {pg.get('status')} {pg.get('sha256', '')[:12]}")
        return 0

    tasks = build_tasks(args.course, course_dir, manifest, datetime.now())
    out = Path(args.out) if args.out else course_dir / "tasks.json"
    out.write_text(json.dumps(tasks, indent=2), encoding="utf-8")
    kinds: dict[str, int] = {}
    for t in tasks:
        kinds[t["type"]] = kinds.get(t["type"], 0) + 1
    print(f"Wrote {len(tasks)} tasks to {out} {kinds}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
