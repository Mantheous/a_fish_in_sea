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
    _MAX_BUCKETS = 10000
    # Run a full stale-bucket sweep every N new-key insertions so memory is
    # reclaimed even when the same keys keep being accessed (no new-key churn
    # to trigger the cap eviction).
    _SWEEP_EVERY = 64

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._hits: dict[str, deque[float]] = {}
        self._windows: dict[str, float] = {}
        self._insertions = 0

    def _evict_stale_locked(self, now: float) -> None:
        stale = [
            k
            for k, v in self._hits.items()
            if not v or v[-1] <= now - self._windows.get(k, 60.0)
        ]
        for k in stale:
            self._hits.pop(k, None)
            self._windows.pop(k, None)

    def _evict_to_cap_locked(self) -> None:
        while len(self._hits) >= self._MAX_BUCKETS:
            oldest = next(iter(self._hits))
            self._hits.pop(oldest, None)
            self._windows.pop(oldest, None)

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
            hits = self._hits.get(key)
            if hits is None:
                self._insertions += 1
                if self._insertions % self._SWEEP_EVERY == 0:
                    self._evict_stale_locked(now)
                self._evict_to_cap_locked()
                hits = deque()
            else:
                # Move active key to end (LRU order)
                self._hits.pop(key, None)
            self._hits[key] = hits
            self._windows[key] = max(window_s, self._windows.get(key, 0.0))
            cutoff = now - window_s
            while hits and hits[0] <= cutoff:
                hits.popleft()
            if len(hits) >= max_calls:
                return False
            hits.append(now)
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
            self._windows.clear()


limiter = RateLimiter()


def _enforce(rl: RateLimiter, key: str, max_calls: int, window_s: float) -> None:
    if not rl.allowed(key, max_calls, window_s):
        raise HTTPException(
            status_code=429,
            detail="Rate limit exceeded, try again shortly",
            headers={"Retry-After": str(rl.retry_after(key, max_calls, window_s))},
        )


def _ip(request: Request) -> str:
    # Behind Tailscale Serve (and most reverse proxies) every user shares the
    # same client host (typically 127.0.0.1), so key rate limits on the
    # original client IP carried in X-Forwarded-For when present. The leftmost
    # entry is the originating client; intermediaries append downstream.
    xff = (request.headers.get("x-forwarded-for") or "").strip()
    if xff:
        client = xff.split(",")[0].strip()
        if client:
            return client[:128]
    if request.client is not None and request.client.host:
        return request.client.host[:128]
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
