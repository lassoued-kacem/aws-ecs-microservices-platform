"""Cache-aside on ElastiCache (Valkey). Every call fails open: if the cache is
unreachable we serve from Postgres, slower but correct. The cache is never the
source of truth for inventory; the conditional UPDATE in Postgres is.
"""

import json
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


def get_json(key: str):
    try:
        raw = client().get(key)
        return json.loads(raw) if raw else None
    except redis.RedisError:
        log.warning("cache get failed", extra={"path": key})
        return None


def set_json(key: str, value, ttl: int) -> None:
    try:
        client().set(key, json.dumps(value, default=str), ex=ttl)
    except redis.RedisError:
        log.warning("cache set failed", extra={"path": key})


def delete(*keys: str) -> None:
    try:
        client().delete(*keys)
    except redis.RedisError:
        pass


def rate_limited(key: str, limit: int, window: int) -> bool:
    try:
        c = client()
        n = c.incr(key)
        if n == 1:
            c.expire(key, window)
        return n > limit
    except redis.RedisError:
        return False
