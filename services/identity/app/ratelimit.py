"""Fixed-window login throttling in Redis/Valkey (shared by all tasks).

Fails OPEN if the cache is down: a cache outage must not lock every user out.
That choice is logged so it is visible on the dashboard.
"""

import logging

import redis

from .config import get_settings

log = logging.getLogger(__name__)
_client: redis.Redis | None = None


def client() -> redis.Redis:
    global _client
    if _client is None:
        s = get_settings()
        _client = redis.Redis.from_url(
            s.redis_url,
            password=s.redis_auth_token or None,
            socket_timeout=0.5,
            socket_connect_timeout=0.5,
            decode_responses=True,
        )
    return _client


def too_many_attempts(key: str) -> bool:
    s = get_settings()
    try:
        c = client()
        k = f"identity:login:{key}"
        n = c.incr(k)
        if n == 1:
            c.expire(k, s.login_window_seconds)
        return n > s.login_max_attempts
    except redis.RedisError:
        log.warning("rate limiter unavailable, failing open")
        return False


def reset(key: str) -> None:
    try:
        client().delete(f"identity:login:{key}")
    except redis.RedisError:
        pass
