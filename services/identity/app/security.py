"""Password hashing and token issuance.

- argon2id (OWASP first choice) with library defaults, rehash-on-login if params change.
- JWT HS256, short TTL, iss/aud/exp/iat/sub/jti claims, verified with an
  explicit algorithm allow-list (prevents the classic `alg: none` attack).
"""

import time
import uuid

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError

from .config import get_settings

_ph = PasswordHasher()
AUDIENCE = "ticketrush"
# A real hash of a random string, used so "unknown email" costs the same time
# as "wrong password" (no user enumeration through timing).
_DUMMY_HASH = _ph.hash(uuid.uuid4().hex)


def hash_password(password: str) -> str:
    return _ph.hash(password)


def verify_password(password_hash: str | None, password: str) -> bool:
    try:
        return _ph.verify(password_hash or _DUMMY_HASH, password) and password_hash is not None
    except (VerifyMismatchError, VerificationError, InvalidHashError):
        return False


def needs_rehash(password_hash: str) -> bool:
    return _ph.check_needs_rehash(password_hash)


def issue_token(user_id: str, email: str, name: str) -> str:
    s = get_settings()
    now = int(time.time())
    claims = {
        "sub": user_id,
        "email": email,
        "name": name,
        "iss": s.jwt_issuer,
        "aud": AUDIENCE,
        "iat": now,
        "nbf": now,
        "exp": now + s.jwt_ttl_seconds,
        "jti": uuid.uuid4().hex,
    }
    return jwt.encode(claims, s.jwt_secret, algorithm="HS256")


def decode_token(token: str) -> dict:
    s = get_settings()
    return jwt.decode(
        token,
        s.jwt_secret,
        algorithms=["HS256"],
        audience=AUDIENCE,
        issuer=s.jwt_issuer,
        options={"require": ["exp", "iat", "sub", "iss", "aud"]},
    )
