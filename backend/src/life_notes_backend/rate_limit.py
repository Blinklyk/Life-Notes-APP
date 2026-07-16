from __future__ import annotations

import math
import threading
import time
from collections import defaultdict, deque
from dataclasses import dataclass
from typing import Callable, Deque, DefaultDict


@dataclass(frozen=True)
class RateLimitDecision:
    allowed: bool
    retry_after_seconds: int = 0


class SlidingWindowRateLimiter:
    def __init__(
        self,
        *,
        limit: int,
        window_seconds: float = 60.0,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._limit = limit
        self._window_seconds = window_seconds
        self._clock = clock
        self._events: DefaultDict[str, Deque[float]] = defaultdict(deque)
        self._lock = threading.Lock()

    def consume(self, key: str) -> RateLimitDecision:
        now = self._clock()
        cutoff = now - self._window_seconds
        with self._lock:
            events = self._events[key]
            while events and events[0] <= cutoff:
                events.popleft()
            if len(events) >= self._limit:
                retry_after = max(1, math.ceil(events[0] + self._window_seconds - now))
                return RateLimitDecision(False, retry_after)
            events.append(now)
            return RateLimitDecision(True)
