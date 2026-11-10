import os
import time
import uuid

os.environ.setdefault("DB_HOST", "localhost")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379/2")

import jwt  # noqa: E402
import pytest  # noqa: E402
from app.config import get_settings  # noqa: E402
from app.main import app  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402


def make_token(user_id: str | None = None) -> str:
    s = get_settings()
    now = int(time.time())
    return jwt.encode(
        {
            "sub": user_id or str(uuid.uuid4()),
            "email": "t@example.com",
            "name": "T",
            "iss": s.jwt_issuer,
            "aud": "ticketrush",
            "iat": now,
            "nbf": now,
            "exp": now + 600,
        },
        s.jwt_secret,
        algorithm="HS256",
    )


@pytest.fixture(scope="session")
def client():
    with TestClient(app) as c:
        yield c


@pytest.fixture
def auth():
    return {"Authorization": f"Bearer {make_token()}"}
