"""Stateless JWT verification. Identity issues, ticketing only verifies.

Both share the HS256 key from SSM. Trade-off (documented in DEEP-DIVE): with an
asymmetric key (RS256 + JWKS) ticketing could not mint tokens; HS256 keeps the
moving parts to one secret, acceptable inside one trust boundary.
"""

import uuid

import jwt
from fastapi import HTTPException, Request, status

from .config import get_settings

AUDIENCE = "ticketrush"


def current_user_id(request: Request) -> uuid.UUID:
    s = get_settings()
    token = request.cookies.get(s.cookie_name)
    auth = request.headers.get("authorization", "")
    if not token and auth.lower().startswith("bearer "):
        token = auth[7:]
    if not token:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "not authenticated")
    try:
        claims = jwt.decode(
            token,
            s.jwt_secret,
            algorithms=["HS256"],
            audience=AUDIENCE,
            issuer=s.jwt_issuer,
            options={"require": ["exp", "iat", "sub", "iss", "aud"]},
        )
        return uuid.UUID(claims["sub"])
    except (jwt.PyJWTError, ValueError):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid or expired session")
