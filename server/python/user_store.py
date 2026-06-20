"""Per-user Plaid token storage for local development.

Persists access tokens keyed by app user id so multiple developers or
test installs can connect different sandbox banks without clobbering
each other. Not for production — use a real database and encryption.
"""

from __future__ import annotations

import json
import threading
from pathlib import Path
from typing import Any

_STORE_PATH = Path(__file__).parent / ".plaid_users.json"
_MAX_USERS = 20  # generous headroom for ~10 dev users


class UserStore:
    def __init__(self, path: Path = _STORE_PATH) -> None:
        self._path = path
        self._lock = threading.Lock()
        self._users: dict[str, dict[str, Any]] = {}
        self._load()

    def _load(self) -> None:
        if not self._path.exists():
            return
        try:
            data = json.loads(self._path.read_text())
            if isinstance(data, dict):
                self._users = data
        except (json.JSONDecodeError, OSError):
            self._users = {}

    def _save(self) -> None:
        self._path.write_text(json.dumps(self._users, indent=2))

    def get(self, user_id: str) -> dict[str, Any] | None:
        with self._lock:
            record = self._users.get(user_id)
            return dict(record) if record else None

    def get_access_token(self, user_id: str) -> str | None:
        record = self.get(user_id)
        if not record:
            return None
        return record.get("access_token")

    def set_connection(
        self, user_id: str, *, access_token: str, item_id: str
    ) -> None:
        with self._lock:
            if user_id not in self._users and len(self._users) >= _MAX_USERS:
                raise ValueError(
                    f"User limit reached ({_MAX_USERS}). Remove old test users."
                )
            self._users[user_id] = {
                "access_token": access_token,
                "item_id": item_id,
            }
            self._save()

    def clear(self, user_id: str) -> None:
        with self._lock:
            self._users.pop(user_id, None)
            self._save()
