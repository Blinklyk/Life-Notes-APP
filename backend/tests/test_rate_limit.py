from life_notes_backend.rate_limit import SlidingWindowRateLimiter


def test_sliding_window_rate_limit_and_retry_after():
    now = [100.0]
    limiter = SlidingWindowRateLimiter(limit=2, clock=lambda: now[0])

    assert limiter.consume("credential").allowed
    assert limiter.consume("credential").allowed
    rejected = limiter.consume("credential")
    assert not rejected.allowed
    assert rejected.retry_after_seconds == 60

    now[0] = 160.0
    assert limiter.consume("credential").allowed
