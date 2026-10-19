"""Canvas LMS API logic (BYU: byu.instructure.com).

All functions take an explicit user token — per-user token storage
lives in oauth_store.py (DB, Fernet-encrypted, provider='canvas').
No globals, no files. The token is only ever sent to validated
*.instructure.com hosts (see validate_host): it must never be
forwarded to an arbitrary caller-supplied URL.
"""

from __future__ import annotations

import datetime as dt
import re
import urllib.parse
from typing import Any

import httpx

_HOST_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", re.IGNORECASE)


class CanvasAuthError(Exception):
    def __init__(self, message: str, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


def validate_host(raw: str) -> str:
    """Normalize and allowlist a Canvas host.

    Only *.instructure.com is accepted — the stored personal token is
    password-equivalent, so an open host parameter would turn this
    proxy into a token-exfiltration oracle.
    """
    host = (raw or "").strip().lower()
    host = host.removeprefix("https://").removeprefix("http://").rstrip("/")
    host = host.split("/")[0].split("?")[0].split("#")[0]
    if host.endswith(".instructure.com"):
        labels = host[: -len(".instructure.com")].split(".")
        if labels and all(_HOST_RE.match(label) for label in labels):
            return host
    raise CanvasAuthError(
        "Canvas host must be a *.instructure.com address "
        "(e.g. byu.instructure.com)."
    )


def base_url(host: str) -> str:
    return f"https://{validate_host(host)}"


async def verify_token(host: str, token: str) -> dict[str, Any]:
    """Check a personal token via /users/self. Returns the user record."""
    if not token.strip():
        raise CanvasAuthError("Missing Canvas token")
    url = f"{base_url(host)}/api/v1/users/self"
    async with httpx.AsyncClient(timeout=30) as c:
        resp = await c.get(url, headers={"Authorization": f"Bearer {token}"})
    if resp.status_code == 401:
        raise CanvasAuthError(
            "Canvas rejected the token (invalid or revoked). "
            "Create a fresh one in Canvas → Account → Settings.",
            status=401,
        )
    if resp.status_code != 200:
        raise CanvasAuthError(
            f"Canvas check failed ({resp.status_code}): {resp.text[:200]}",
            status=resp.status_code,
        )
    data = resp.json()
    if not isinstance(data, dict):
        raise CanvasAuthError("Canvas returned an unexpected response.")
    return data


def _next_link(link_header: str | None) -> str | None:
    """Extract the rel="next" URL from an RFC 5988 Link header."""
    if not link_header:
        return None
    for part in link_header.split(","):
        segments = part.split(";")
        if len(segments) < 2:
            continue
        url = segments[0].strip().strip("<>")
        if any('rel="next"' in s for s in segments[1:]):
            return url
    return None


def normalize_planner_item(item: dict[str, Any]) -> dict[str, Any] | None:
    """Reduce one planner item to submission state, or None to skip.

    Only assignment plannables map onto the app's homework nodes
    (iCal UID `event-assignment-<id>`); announcements, discussions,
    and items with a boolean `submissions` carry no submission state.
    """
    if not isinstance(item, dict):
        return None
    if item.get("plannable_type") != "assignment":
        return None
    submissions = item.get("submissions")
    if not isinstance(submissions, dict):
        return None
    try:
        assignment_id = int(item.get("plannable_id"))
    except (TypeError, ValueError):
        return None
    plannable = item.get("plannable") or {}
    return {
        "assignment_id": assignment_id,
        "course_id": item.get("course_id"),
        "title": plannable.get("title") if isinstance(plannable, dict) else None,
        "due_at": plannable.get("due_at") if isinstance(plannable, dict) else None,
        "submitted": bool(submissions.get("submitted")),
        "excused": bool(submissions.get("excused")),
        "graded": bool(submissions.get("graded")),
        "missing": bool(submissions.get("missing")),
        "late": bool(submissions.get("late")),
    }


async def list_planner_items(
    host: str,
    token: str,
    start_date: str | None = None,
    end_date: str | None = None,
    max_pages: int = 10,
) -> list[dict[str, Any]]:
    """Fetch planner items across [start_date, end_date], following
    bookmark pagination. Returns normalized assignment entries."""
    if not token.strip():
        raise CanvasAuthError("Canvas account not connected")
    validated = validate_host(host)
    if start_date is None or end_date is None:
        default_min, default_max = default_sync_window()
        start_date = start_date or default_min
        end_date = end_date or default_max
    out: list[dict[str, Any]] = []
    url: str | None = f"https://{validated}/api/v1/planner/items"
    params: dict[str, Any] | None = {
        "start_date": start_date,
        "end_date": end_date,
        "per_page": 100,
    }
    async with httpx.AsyncClient(timeout=30) as c:
        for _ in range(max_pages):
            assert url is not None
            resp = await c.get(
                url,
                headers={"Authorization": f"Bearer {token}"},
                params=params,
            )
            params = None  # bookmark URLs already carry their query
            if resp.status_code in (401, 403):
                raise CanvasAuthError(
                    "Canvas rejected the token (invalid or revoked). "
                    "Reconnect with a fresh token.",
                    status=resp.status_code,
                )
            if resp.status_code != 200:
                raise CanvasAuthError(
                    f"Canvas planner call failed ({resp.status_code}): "
                    f"{resp.text[:200]}",
                    status=resp.status_code,
                )
            data = resp.json()
            if not isinstance(data, list):
                break
            for item in data:
                normalized = normalize_planner_item(
                    item if isinstance(item, dict) else {}
                )
                if normalized is not None:
                    out.append(normalized)
            next_url = _next_link(resp.headers.get("Link"))
            if not next_url:
                break
            parsed_next = urllib.parse.urlparse(next_url)
            if parsed_next.scheme.lower() != "https" or validate_host(
                parsed_next.hostname or ""
            ) != validated:
                raise CanvasAuthError(
                    "Canvas pagination Link pointed outside the validated host."
                )
            url = next_url
    return out


def default_sync_window() -> tuple[str, str]:
    """Wide window: auto-completion must cover the old overdue pile,
    not just this week (-180/+30 days)."""
    now = dt.datetime.now(dt.timezone.utc)
    time_min = (now - dt.timedelta(days=180)).strftime("%Y-%m-%d")
    time_max = (now + dt.timedelta(days=30)).strftime("%Y-%m-%d")
    return time_min, time_max


async def get_assignment(
    host: str,
    token: str,
    assignment_id: int,
    course_id: int | None = None,
) -> dict[str, Any]:
    """Fetch one Canvas assignment's details (description, link, due).

    ``course_id`` is optional: the importer only keeps the assignment id
    (iCal UID ``event-assignment-<id>``), so when it is missing the
    student's courses are walked until the assignment is found. The
    token never leaves the server — callers pass the stored per-user
    token straight through to the validated *.instructure.com host.
    """
    if not (token or "").strip():
        raise CanvasAuthError("Canvas account not connected")
    validated = validate_host(host)
    headers = {"Authorization": f"Bearer {token}"}
    base = f"https://{validated}"
    async with httpx.AsyncClient(timeout=30) as c:
        if course_id is not None:
            resp = await c.get(
                f"{base}/api/v1/courses/{course_id}/assignments/{assignment_id}",
                headers=headers,
            )
            if resp.status_code in (401, 403):
                raise CanvasAuthError(
                    "Canvas rejected the token (invalid or revoked).",
                    status=resp.status_code,
                )
            if resp.status_code == 404:
                raise CanvasAuthError("Assignment not found", status=404)
            if resp.status_code != 200:
                raise CanvasAuthError(
                    f"Canvas assignment call failed ({resp.status_code}): "
                    f"{resp.text[:200]}",
                    status=resp.status_code,
                )
            data = resp.json()
            resolved_course: int | None = course_id
        else:
            # No course stored on the node: find the owning course first.
            data = None
            resolved_course = None
            courses_resp = await c.get(
                f"{base}/api/v1/courses",
                headers=headers,
                params={"per_page": 100},
            )
            if courses_resp.status_code in (401, 403):
                raise CanvasAuthError(
                    "Canvas rejected the token (invalid or revoked).",
                    status=courses_resp.status_code,
                )
            courses = (
                courses_resp.json() if courses_resp.status_code == 200 else []
            )
            if isinstance(courses, list):
                for course in courses:
                    if not isinstance(course, dict):
                        continue
                    try:
                        cid = int(course.get("id"))  # type: ignore[arg-type]
                    except (TypeError, ValueError):
                        continue
                    r = await c.get(
                        f"{base}/api/v1/courses/{cid}/assignments/"
                        f"{assignment_id}",
                        headers=headers,
                    )
                    if r.status_code == 200:
                        data = r.json()
                        resolved_course = cid
                        break
            if data is None:
                raise CanvasAuthError("Assignment not found", status=404)
        if not isinstance(data, dict):
            raise CanvasAuthError("Canvas returned an unexpected response.")
        return {
            "assignment_id": data.get("id", assignment_id),
            "course_id": resolved_course
            if resolved_course is not None
            else data.get("course_id"),
            "title": data.get("name"),
            "description": data.get("description"),
            "html_url": data.get("html_url"),
            "due_at": data.get("due_at"),
            "points_possible": data.get("points_possible"),
        }
