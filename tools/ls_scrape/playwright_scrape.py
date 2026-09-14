"""Learning Suite course scraper — deterministic, local-only, no credentials in code.

The user runs this themselves. It reuses their own logged-in Chromium profile
(persistent context in .ls-profile/), so no username/password/Duo ever touches
code, env vars, or an LLM. The agent only reads the saved raw/ dump afterwards.

Usage:
    python3 -m venv .venv && source .venv/bin/activate
    pip install -r requirements.txt
    python -m playwright install chromium   # one time
    python playwright_scrape.py --course-url \\
        "https://learningsuite.byu.edu/.XiMK/cid-FOgnegoEKmGv/student/home"

URL pattern: https://learningsuite.byu.edu/.<tenant>/cid-<courseId>/student/<tab>
Tabs tried by default: home syllabus assignments schedule content announcements
grades. Teachers enable different subsets; missing tabs are logged, not fatal.

Output: raw/<cid>/manifest.json + per-tab <tab>.html / <tab>.txt + calendar.ics
(when found or passed via --ical-url).

Auth (pick one — never a password in code):
  A. Headless box / agent run: export cookies from your own logged-in browser
     (e.g. "Get cookies.txt LOCALLY" extension while on learningsuite.byu.edu),
     save as .cookies.txt (gitignored), then:
       python playwright_scrape.py --course-url "<home>" --cookies-file .cookies.txt
     If the session expired you'll get "still redirected to login" — re-export.
  B. Machine with a display: omit --cookies-file; first run opens a headed
     browser for manual login (+ Duo), session persists in .ls-profile/.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROFILE_DIR = HERE / ".ls-profile"
RAW_ROOT = HERE / "raw"

DEFAULT_TABS = (
    "home",
    "syllabus",
    "assignments",
    "schedule",
    "content",
    "announcements",
    "grades",
)

LOGIN_HINTS = ("cas.byu.edu", "login", "signin", "sign-in", "duo")


def parse_course_url(url: str) -> tuple[str, str, str]:
    """Return (base, tenant, cid) where base ends with /student/."""
    m = re.match(
        r"^(https://learningsuite\.byu\.edu/\.[^/]+/cid-[^/]+/student/).*?$", url.strip()
    )
    if not m:
        raise ValueError(
            "Expected https://learningsuite.byu.edu/.<tenant>/cid-<id>/student/<tab>"
        )
    base = m.group(1)
    m2 = re.match(
        r"^https://learningsuite\.byu\.edu/\.([^/]+)/(cid-[^/]+)/student/$", base
    )
    assert m2 is not None
    return base, m2.group(1), m2.group(2)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def looks_like_login(page_url: str, title: str) -> bool:
    hay = f"{page_url}\n{title}".lower()
    return any(h in hay for h in LOGIN_HINTS)


def load_cookies(path: Path) -> list[dict]:
    """Load cookies from JSON (Playwright/EditThisCookie export) or Netscape cookies.txt.

    Returns Playwright-format cookie dicts. Auto-detects by content.
    """
    text = path.read_text(encoding="utf-8")
    stripped = text.strip()
    if stripped.startswith("["):
        raw = json.loads(stripped)
        cookies = []
        for c in raw:
            cookies.append(
                {
                    "name": c["name"],
                    "value": c["value"],
                    "domain": c.get("domain", ".byu.edu"),
                    "path": c.get("path", "/"),
                    **({"expires": int(c["expirationDate"])} if "expirationDate" in c else {}),
                    **({"httpOnly": True} if c.get("httpOnly") else {}),
                    **({"secure": True} if c.get("secure") else {}),
                    "sameSite": {"no_restriction": "None", "lax": "Lax", "strict": "Strict"}.get(
                        str(c.get("sameSite", "")).lower(), "Lax"
                    ),
                }
            )
        return cookies
    # Netscape cookies.txt: domain<TAB>flag<TAB>path<TAB>secure<TAB>expiry<TAB>name<TAB>value
    cookies = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 7:
            continue
        domain, _flag, cpath, secure, expiry, name, value = parts
        entry: dict = {
            "name": name,
            "value": value,
            "domain": domain,
            "path": cpath,
            "sameSite": "Lax",
        }
        if secure.upper() == "TRUE":
            entry["secure"] = True
        try:
            if int(expiry) > 0:
                entry["expires"] = int(expiry)
        except ValueError:
            pass
        cookies.append(entry)
    if not cookies:
        raise ValueError(f"No cookies parsed from {path} (need JSON array or Netscape cookies.txt)")
    return cookies


def wait_for_manual_login() -> None:
    print(
        "\nLog in manually in the opened browser window (including Duo), "
        "then return here and press ENTER to continue.",
        flush=True,
    )
    try:
        input()
    except EOFError:
        pass


def download_ical(feed_url: str, dest: Path) -> bool:
    try:
        req = urllib.request.Request(
            feed_url, headers={"User-Agent": "a_fish_in_sea ls_scrape"}
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            dest.write_bytes(resp.read())
        return True
    except Exception as e:  # noqa: BLE001 — report, don't crash the crawl
        print(f"  iCal download failed: {e}")
        return False


def scrape_course(
    course_url: str,
    tabs: tuple[str, ...],
    ical_url: str | None,
    cookies_file: Path | None = None,
) -> Path:
    from playwright.sync_api import sync_playwright

    base, tenant, cid = parse_course_url(course_url)
    out_dir = RAW_ROOT / cid
    out_dir.mkdir(parents=True, exist_ok=True)

    cookies = load_cookies(cookies_file) if cookies_file else []
    if cookies_file:
        print(f"Loaded {len(cookies)} cookies from {cookies_file}")

    manifest: dict = {
        "course_url": course_url,
        "tenant": tenant,
        "cid": cid,
        "scraped_at": datetime.now(timezone.utc).isoformat(),
        "pages": [],
    }

    PROFILE_DIR.mkdir(parents=True, exist_ok=True)

    def new_context(p, *, headless: bool):
        ctx = p.chromium.launch_persistent_context(
            str(PROFILE_DIR), headless=headless, accept_downloads=True
        )
        if cookies:
            ctx.add_cookies(cookies)
        return ctx

    with sync_playwright() as p:
        # First attempt: headless with the saved profile (+ imported cookies).
        ctx = new_context(p, headless=True)
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        page.goto(course_url, wait_until="domcontentloaded", timeout=60000)
        page.wait_for_timeout(2500)
        if looks_like_login(page.url, page.title()):
            if cookies:
                ctx.close()
                raise SystemExit(
                    "error: still redirected to login with --cookies-file. "
                    "Session expired — re-export cookies from your browser and retry."
                )
            print("Session expired or first run — opening headed browser for login.")
            ctx.close()
            try:
                ctx = new_context(p, headless=False)
            except Exception as e:  # noqa: BLE001 — headed needs an X server
                raise SystemExit(
                    f"error: headed browser failed ({e}). This box has no display, so:\n"
                    "  1. Log into Learning Suite in your own browser,\n"
                    "  2. Export cookies (e.g. 'Get cookies.txt LOCALLY' extension),\n"
                    "  3. Save as tools/ls_scrape/.cookies.txt and re-run with\n"
                    "     --cookies-file .cookies.txt"
                ) from None
            page = ctx.pages[0] if ctx.pages else ctx.new_page()
            page.goto(course_url, wait_until="domcontentloaded", timeout=60000)
            wait_for_manual_login()
            page.wait_for_timeout(2000)

        for tab in tabs:
            url = f"{base}{tab}"
            print(f"[{tab}] {url}")
            try:
                page.goto(url, wait_until="domcontentloaded", timeout=60000)
                page.wait_for_timeout(2000)
                if looks_like_login(page.url, page.title()):
                    print(f"  skipped: redirected to login ({page.url})")
                    manifest["pages"].append(
                        {"tab": tab, "url": url, "status": "login-redirect"}
                    )
                    continue
                html = page.content()
                try:
                    text = page.evaluate("() => document.body ? document.body.innerText : ''")
                except Exception:  # noqa: BLE001
                    text = ""
                html_path = out_dir / f"{tab}.html"
                txt_path = out_dir / f"{tab}.txt"
                html_path.write_text(html, encoding="utf-8")
                txt_path.write_text(text or "", encoding="utf-8")
                manifest["pages"].append(
                    {
                        "tab": tab,
                        "url": page.url,
                        "status": "ok",
                        "html": html_path.name,
                        "text": txt_path.name,
                        "sha256": sha256_file(html_path),
                    }
                )
                shot = out_dir / f"{tab}.png"
                try:
                    page.screenshot(path=str(shot), full_page=False)
                except Exception:  # noqa: BLE001
                    pass
            except Exception as e:  # noqa: BLE001
                print(f"  failed: {e}")
                manifest["pages"].append({"tab": tab, "url": url, "status": f"error: {e}"})

        # iCal: explicit --ical-url wins; otherwise look for a feed link on schedule.
        ical_dest = out_dir / "calendar.ics"
        if ical_url:
            print(f"[ical] {ical_url}")
            if download_ical(ical_url, ical_dest):
                manifest["ical"] = {"url": ical_url, "file": "calendar.ics"}
        else:
            try:
                links = page.evaluate(
                    "() => Array.from(document.querySelectorAll('a[href]'))"
                    ".map(a => a.href).filter(h => h.includes('ical') || h.includes('calendar'))"
                )
                cands = [u for u in links if u.startswith("http")]
                if cands:
                    print(f"[ical] trying {cands[0]}")
                    if download_ical(cands[0], ical_dest):
                        manifest["ical"] = {"url": cands[0], "file": "calendar.ics"}
            except Exception:  # noqa: BLE001
                pass

        ctx.close()

    manifest_path = out_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    ok = sum(1 for pg in manifest["pages"] if pg.get("status") == "ok")
    print(f"\nDone: {ok}/{len(manifest['pages'])} tabs saved to {out_dir}")
    print("The agent can now run: python parse_tasks.py --course", cid)
    return out_dir


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--course-url", required=True, help="Any /student/<tab> URL for the course")
    ap.add_argument("--tabs", nargs="*", default=list(DEFAULT_TABS))
    ap.add_argument("--ical-url", default=None, help="Manual Schedule > Get iCalendar Feed URL")
    ap.add_argument(
        "--cookies-file",
        default=None,
        help="Cookies export (JSON array or Netscape cookies.txt) for headless auth",
    )
    args = ap.parse_args(argv)
    try:
        scrape_course(
            args.course_url,
            tuple(args.tabs),
            args.ical_url,
            Path(args.cookies_file) if args.cookies_file else None,
        )
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
