"""In-memory sliding-window rate limiter.

Single-process and dependency-free: state lives in a dict of deques,
so it suits the personal single-replica deployment. Behind multiple
workers each process enforces its own budget (the fail-open direction
is permissive, never a lockout). Over-limit requests answer 429 with
a Retry-After header.
"""

from __future__ import annotations

import threading
import time
from collections import deque

from fastapi import Depends, HTTPException, Request

from .deps import get_current_user
from .models import User


class RateLimiter:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._hits: dict[str, deque[float]] = {}

    def allowed(
        self,
        key: str,
        max_calls: int,
        window_s: float,
        now: float | None = None,
    ) -> bool:
        """Record a hit and return True when still within budget."""
        now = time.monotonic() if now is None else now
        with self._lock:
            hits = self._hits.setdefault(key, deque())
            cutoff = now - window_s
            while hits and hits[0] <= cutoff:
                hits.popleft()
            if len(hits) >= max_calls:
                return False
            hits.append(now)
            if len(self._hits) > 10000:
                # Drop empty buckets so memory can't grow unbounded.
                for stale in [k for k, v in self._hits.items() if not v][:1000]:
                    del self._hits[stale]
            return True

    def retry_after(self, key: str, max_calls: int, window_s: float) -> int:
        with self._lock:
            hits = self._hits.get(key)
            if not hits or len(hits) < max_calls:
                return 0
            return max(1, int(hits[0] + window_s - time.monotonic()) + 1)

    def reset(self) -> None:
        with self._lock:
            self._hits.clear()


limiter = RateLimiter()


def _enforce(rl: RateLimiter, key: str, max_calls: int, window_s: float) -> None:
    if not rl.allowed(key, max_calls, window_s):
        raise HTTPException(
            status_code=429,
            detail="Rate limit exceeded, try again shortly",
            headers={"Retry-After": str(rl.retry_after(key, max_calls, window_s))},
        )


def _ip(request: Request) -> str:
    if request.client is not None and request.client.host:
        return request.client.host
    return "unknown"


def limit(
    name: str,
    max_calls: int,
    window_s: float,
    *,
    by_user: bool = False,
    instance: RateLimiter | None = None,
):
    """FastAPI dependency factory. by_user keys on the authenticated
    user id (and therefore also requires auth); otherwise on client IP."""
    rl = instance or limiter
    if by_user:

        async def _dep_user(
            request: Request, user: User = Depends(get_current_user)
        ) -> None:
            _enforce(rl, f"{name}:user:{user.id}", max_calls, window_s)

        return _dep_user

    async def _dep_ip(request: Request) -> None:
        _enforce(rl, f"{name}:ip:{_ip(request)}", max_calls, window_s)

    return _dep_ip
