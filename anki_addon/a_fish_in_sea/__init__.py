"""A Fish in Sea — report Anki review totals to the app server.

Install this folder as an Anki add-on, then paste the setup JSON from the
app's Settings → Anki section into Tools → Add-ons → A Fish in Sea →
Config. The add-on reads only `revlog` counts and deck names: no card
text, notes, tags, or schedule details leave the collection.

Reports are rolling absolute totals, posted about 20 seconds after you
stop reviewing (and at least every five minutes during a long session),
on profile open/close, and after an AnkiWeb sync. The server keeps the
per-day, per-deck maximum, so a retry or a missed upload cannot double
count.
"""

from __future__ import annotations

import datetime as dt
import json
import threading
import time
import traceback
import urllib.error
import urllib.request

from aqt import gui_hooks, mw
from aqt.operations import QueryOp
from aqt.utils import showInfo, showWarning, tooltip

try:  # Anki 2.1.50+ ships Qt6; older builds use Qt5.
    from PyQt6.QtCore import QTimer
    from PyQt6.QtWidgets import QAction
except ImportError:  # pragma: no cover - depends on the Anki build
    from PyQt5.QtCore import QTimer
    from PyQt5.QtWidgets import QAction

from . import report

_DEFAULTS = {
    "server_url": "",
    "api_token": "",
    "enabled": True,
    "report_days": 400,
    "rollover_hour": 0,
}

# Automatic reports are debounced after the last answer so a review
# session produces one upload, not one per card.
_DEBOUNCE_MS = 20_000
_OPEN_DELAY_MS = 4_000
_SYNC_DELAY_MS = 8_000
# Don't upload more than once every two minutes on close/answer bursts.
_MIN_AUTO_INTERVAL_S = 120.0
_HTTP_TIMEOUT_S = 12

_timer: QTimer | None = None
_busy = False
_config_cache: dict | None = None
_last_success_at = 0.0
_last_attempt_at = 0.0
_last_error_notice = 0.0
_pending_notice: str | None = None
_menu_added = False


# ── Config ──────────────────────────────────────────────────────────────


def _load_config() -> dict:
    raw = mw.addonManager.getConfig(__name__) or {}
    cfg = dict(_DEFAULTS)
    if isinstance(raw, dict):
        cfg.update({k: raw[k] for k in _DEFAULTS if k in raw})
    try:
        cfg["report_days"] = max(1, min(730, int(cfg.get("report_days", 400))))
    except (TypeError, ValueError):
        cfg["report_days"] = 400
    try:
        cfg["rollover_hour"] = max(0, min(23, int(cfg.get("rollover_hour", 0))))
    except (TypeError, ValueError):
        cfg["rollover_hour"] = 0
    cfg["server_url"] = str(cfg.get("server_url") or "").strip()
    cfg["api_token"] = str(cfg.get("api_token") or "").strip()
    cfg["enabled"] = bool(cfg.get("enabled", True))
    return cfg


def _cfg() -> dict:
    """Cached config: the reviewer hook runs per answer, so no file I/O
    on that path. Refreshed on profile open and after the config editor."""
    global _config_cache
    if _config_cache is None:
        _config_cache = _load_config()
    return _config_cache


def _refresh_config() -> dict:
    global _config_cache
    _config_cache = _load_config()
    return _config_cache


def _base_url(server_url: str) -> str:
    """Normalize what the app shows into the server root.

    Accepts `https://host/fish`, a trailing slash, the app URL ending in
    `index.html`, or an API URL ending in `/api/v1`. Returns "" when the
    value is empty.
    """
    base = (server_url or "").strip().rstrip("/")
    if base.endswith("/index.html"):
        base = base[: -len("/index.html")]
    elif base.endswith(".html"):
        base = base.rsplit("/", 1)[0]
    for suffix in ("/api/v1", "/api"):
        if base.endswith(suffix):
            base = base[: -len(suffix)]
            break
    return base.rstrip("/")


def _endpoint(cfg: dict, name: str) -> str:
    return f"{_base_url(cfg['server_url'])}/api/v1/anki/{name}"


def _config_ready(cfg: dict) -> bool:
    return bool(_base_url(cfg["server_url"]) and cfg["api_token"])


# ── HTTP ────────────────────────────────────────────────────────────────


class _HttpError(Exception):
    def __init__(self, message: str, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


def _request(
    method: str,
    url: str,
    token: str,
    payload: dict | None = None,
    timeout: float = _HTTP_TIMEOUT_S,
) -> dict:
    data = None
    headers = {
        "Accept": "application/json",
        "User-Agent": report.CLIENT,
        "Authorization": f"Bearer {token}",
    }
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            parsed = json.loads(exc.read().decode("utf-8", "replace"))
            if isinstance(parsed, dict):
                detail = str(parsed.get("detail") or "")
        except Exception:
            pass
        if not detail:
            detail = exc.reason or "request rejected"
        raise _HttpError(f"HTTP {exc.code}: {detail}", exc.code) from exc
    except urllib.error.URLError as exc:
        raise _HttpError(f"cannot reach {url}: {exc.reason}") from exc
    except Exception as exc:  # timeouts, TLS, malformed URLs
        raise _HttpError(f"cannot reach {url}: {exc}") from exc
    if not body:
        return {}
    try:
        parsed = json.loads(body.decode("utf-8"))
    except ValueError as exc:
        raise _HttpError("server answered with something that is not JSON") from exc
    return parsed if isinstance(parsed, dict) else {}


def _note_error(exc: Exception) -> None:
    global _last_error_notice, _pending_notice
    print(f"[a_fish_in_sea] {exc}")
    now = time.monotonic()
    if now - _last_error_notice < 3600:
        return
    _last_error_notice = now
    if isinstance(exc, _HttpError) and exc.status in (401, 403):
        _pending_notice = (
            "A Fish in Sea: the Anki add-on token was rejected. Create a "
            "new token in Settings → Anki, then update the add-on config."
        )
    else:
        _pending_notice = (
            "A Fish in Sea: couldn't report Anki reviews. Check the server "
            "address in Tools → Add-ons → A Fish in Sea → Config."
        )


def _flush_notice() -> None:
    global _pending_notice
    if _pending_notice is None:
        return
    message, _pending_notice = _pending_notice, None
    try:
        tooltip(message, period=8000)
    except Exception:
        print(f"[a_fish_in_sea] {message}")


# ── Report collection ───────────────────────────────────────────────────


def _deck_names(dids: set[int]) -> dict[int, str]:
    names: dict[int, str] = {}
    for did in dids:
        try:
            name = mw.col.decks.name(did)
        except Exception:
            name = None
        if not name:
            try:
                deck = mw.col.decks.get(did)
                name = deck.get("name") if isinstance(deck, dict) else None
            except Exception:
                name = None
        if name:
            names[int(did)] = str(name)
    return names


def _payload_for_collection(cfg: dict) -> dict | None:
    """Synchronous query + payload build, used on close and for manual
    reports. Returns None when there is no collection yet."""
    if mw.col is None:
        return None
    cutoff = report.cutoff_ms(cfg["report_days"])
    rows = report.query_reviews(mw.col.db, cutoff)
    names = _deck_names({int(row[1]) for row in rows if row[1] is not None})
    return report.build_payload(
        rows,
        names,
        rollover_hour=cfg["rollover_hour"],
    )


def _upload(cfg: dict, payload: dict, timeout: float = _HTTP_TIMEOUT_S) -> None:
    global _last_success_at
    _request(
        "POST",
        _endpoint(cfg, "report"),
        cfg["api_token"],
        payload,
        timeout=timeout,
    )
    _last_success_at = time.monotonic()


def _upload_in_background(cfg: dict, payload: dict) -> None:
    def work() -> None:
        try:
            _upload(cfg, payload)
        except Exception as exc:  # keep the review UI alive
            _note_error(exc)
            traceback.print_exc()

    threading.Thread(target=work, daemon=True).start()


def _report(manual: bool = False) -> None:
    """Collect review rows in the background, then upload them.

    Anki's [QueryOp] is the supported way to read the collection off the
    UI thread. Deck-name lookup stays on the main thread in `on_success`.
    """
    global _busy, _last_attempt_at
    _flush_notice()
    cfg = _refresh_config()
    if not manual and not cfg["enabled"]:
        return
    if not _config_ready(cfg):
        if manual:
            showWarning(
                "A Fish in Sea is not configured yet.\n\n"
                "Open Settings → Anki in the app, create an add-on token, "
                "and paste the generated JSON into Tools → Add-ons → "
                "A Fish in Sea → Config."
            )
        return
    if mw.col is None:
        if manual:
            showWarning("Open a deck first, then report reviews.")
        return
    if _busy:
        return
    _busy = True
    _last_attempt_at = time.monotonic()
    cutoff = report.cutoff_ms(cfg["report_days"])

    def op(col):
        try:
            return report.query_reviews(col.db, cutoff)
        except Exception:
            traceback.print_exc()
            return []

    def success(rows) -> None:
        global _busy
        try:
            names = _deck_names(
                {int(row[1]) for row in rows if row[1] is not None}
            )
            payload = report.build_payload(
                rows,
                names,
                rollover_hour=cfg["rollover_hour"],
            )
            if manual:
                try:
                    _upload(cfg, payload)
                    showInfo(
                        f"Reported {len(payload['days'])} day/deck row"
                        f"{'' if len(payload['days']) == 1 else 's'} "
                        "to A Fish in Sea."
                    )
                except Exception as exc:
                    _note_error(exc)
                    showWarning(f"Could not report reviews:\n\n{exc}")
            else:
                _upload_in_background(cfg, payload)
        finally:
            _busy = False

    try:
        QueryOp(parent=mw, op=op, on_success=success).run_in_background()
    except Exception:
        _busy = False
        traceback.print_exc()


def _schedule(delay_ms: int) -> None:
    global _timer
    if mw is None or mw.col is None:
        return
    if _timer is None:
        _timer = QTimer(mw)
        _timer.setSingleShot(True)
        _timer.timeout.connect(lambda: _report(manual=False))
    _timer.start(max(0, int(delay_ms)))


# ── Menu actions ────────────────────────────────────────────────────────


def _ago(iso: str | None) -> str:
    if not iso:
        return "never"
    try:
        moment = dt.datetime.fromisoformat(iso.replace("Z", "+00:00"))
        if moment.tzinfo is None:
            moment = moment.replace(tzinfo=dt.timezone.utc)
        delta = dt.datetime.now(dt.timezone.utc) - moment
        seconds = int(delta.total_seconds())
        if seconds < 60:
            return "just now"
        if seconds < 3600:
            return f"{seconds // 60} min ago"
        if seconds < 86400:
            return f"{seconds // 3600} h ago"
        return f"{seconds // 86400} d ago"
    except Exception:
        return iso


def _test_connection(*_args) -> None:
    _flush_notice()
    cfg = _refresh_config()
    if not _config_ready(cfg):
        showWarning(
            "Set the server URL and add-on token first.\n\n"
            "In the app: Settings → Anki → Create add-on token."
        )
        return
    try:
        body = _request(
            "GET", _endpoint(cfg, "summary"), cfg["api_token"]
        )
    except Exception as exc:
        showWarning(f"Could not reach A Fish in Sea:\n\n{exc}")
        return
    account = body.get("email") or ""
    account_line = f"Account: {account}\n" if account else ""
    showInfo(
        "Connected to A Fish in Sea.\n\n"
        f"{account_line}"
        f"Last report: {_ago(body.get('last_report_at'))}\n"
        f"Decks with data: {body.get('decks', 0)}\n"
        f"Days with data: {body.get('days', 0)}\n"
        f"Last 7 days: {body.get('cards_7d', 0)} cards "
        f"({body.get('reviews_7d', 0)} answers)"
    )


def _setup_help(*_args) -> None:
    showInfo(
        "1. In the app: Settings → Anki → Create add-on token.\n"
        "2. Copy the JSON config it shows (it contains the server URL and "
        "the token).\n"
        "3. In Anki: Tools → Add-ons → A Fish in Sea → Config, replace "
        "the file contents with that JSON, and save.\n\n"
        "The add-on reports only deck names and daily review counts. It "
        "never sends card text, notes, tags, or scheduling details."
    )


def _add_menu() -> None:
    global _menu_added
    if _menu_added or mw is None:
        return
    try:
        report_action = QAction("Report reviews to A Fish in Sea", mw)
        report_action.triggered.connect(lambda *_a: _report(manual=True))
        mw.form.menuTools.addAction(report_action)

        test_action = QAction("A Fish in Sea: Test connection", mw)
        test_action.triggered.connect(_test_connection)
        mw.form.menuTools.addAction(test_action)

        help_action = QAction("A Fish in Sea: Setup help", mw)
        help_action.triggered.connect(_setup_help)
        mw.form.menuTools.addAction(help_action)
        _menu_added = True
    except Exception:
        traceback.print_exc()


# ── Hooks ───────────────────────────────────────────────────────────────


def _on_answer(*_args) -> None:
    if not _cfg()["enabled"]:
        return
    _flush_notice()
    now = time.monotonic()
    if now - _last_success_at < _MIN_AUTO_INTERVAL_S:
        return
    # Long review sessions never pause long enough for the debounce timer.
    # Force a max-five-minutes report so the app does not go stale.
    if now - _last_attempt_at >= 300:
        _report(manual=False)
        return
    _schedule(_DEBOUNCE_MS)


def _on_profile_open(*_args) -> None:
    global _last_success_at
    _last_success_at = 0.0
    _refresh_config()
    _add_menu()
    _schedule(_OPEN_DELAY_MS)


def _on_profile_close(*_args) -> None:
    """Last-chance flush while the collection is still open.

    A short synchronous upload is acceptable here; if it fails, the next
    profile open reports the same rolling totals again.
    """
    global _timer
    if _timer is not None:
        _timer.stop()
    cfg = _cfg()
    if not cfg["enabled"] or not _config_ready(cfg):
        return
    if time.monotonic() - _last_success_at < _MIN_AUTO_INTERVAL_S:
        return
    try:
        payload = _payload_for_collection(cfg)
        if payload is not None:
            _upload(cfg, payload, timeout=4)
    except Exception as exc:
        _note_error(exc)
        traceback.print_exc()


def _on_sync(*_args) -> None:
    if _cfg()["enabled"]:
        _schedule(_SYNC_DELAY_MS)


def _on_config_updated(*_args) -> None:
    global _timer
    if _timer is not None:
        _timer.stop()
    cfg = _refresh_config()
    if not _config_ready(cfg):
        tooltip("A Fish in Sea: add the server URL and token in the config.")
        return
    tooltip("A Fish in Sea: config saved. Testing the next report soon.")
    _schedule(1_000)


_add_menu()
gui_hooks.reviewer_did_answer_card.append(_on_answer)
gui_hooks.profile_did_open.append(_on_profile_open)
gui_hooks.profile_will_close.append(_on_profile_close)
gui_hooks.sync_did_finish.append(_on_sync)
try:
    mw.addonManager.setConfigUpdatedAction(__name__, _on_config_updated)
except Exception:
    traceback.print_exc()
_schedule(2_000)
