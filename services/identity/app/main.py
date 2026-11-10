import logging
import time
import uuid
from contextlib import asynccontextmanager

import jwt
from fastapi import Depends, FastAPI, HTTPException, Request, Response, status
from fastapi.responses import JSONResponse
from sqlalchemy import select, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from . import ratelimit
from .config import get_settings
from .db import engine, get_db
from .logging_setup import setup_logging
from .migrate import run_migrations
from .models import User
from .schemas import LoginIn, RegisterIn, UserOut
from .security import decode_token, hash_password, issue_token, needs_rehash, verify_password
from .telemetry import setup_tracing

setup_logging()
log = logging.getLogger("identity")
settings = get_settings()


@asynccontextmanager
async def lifespan(_: FastAPI):
    if settings.run_migrations:
        run_migrations()
    yield


# Docs are disabled outside local: no free API map for attackers.
app = FastAPI(
    title="TicketRush identity",
    lifespan=lifespan,
    docs_url="/api/auth/docs" if settings.environment == "local" else None,
    openapi_url="/api/auth/openapi.json" if settings.environment == "local" else None,
)
setup_tracing(app, engine)


@app.middleware("http")
async def access_log(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    if request.url.path != "/health":
        log.info(
            "request",
            extra={
                "method": request.method,
                "path": request.url.path,
                "status": response.status_code,
                "duration_ms": round((time.perf_counter() - start) * 1000, 1),
            },
        )
    return response


@app.exception_handler(Exception)
async def unhandled(_: Request, exc: Exception):
    log.exception("unhandled error")
    return JSONResponse(status_code=500, content={"detail": "internal error"})


def _set_session_cookie(response: Response, token: str) -> None:
    # HttpOnly: JS (and any XSS) cannot read the token.
    # SameSite=Strict: the browser never sends it cross-site -> CSRF protection.
    # Secure: HTTPS only (CloudFront). Path=/api: never sent for static assets.
    response.set_cookie(
        settings.cookie_name,
        token,
        max_age=settings.jwt_ttl_seconds,
        httponly=True,
        secure=settings.cookie_secure,
        samesite="strict",
        path="/api",
    )


def current_claims(request: Request) -> dict:
    token = request.cookies.get(settings.cookie_name)
    auth = request.headers.get("authorization", "")
    if not token and auth.lower().startswith("bearer "):
        token = auth[7:]
    if not token:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "not authenticated")
    try:
        return decode_token(token)
    except jwt.PyJWTError:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid or expired session")


@app.get("/health")
def health():
    """Liveness for ALB/ECS: cheap, no dependencies (a DB blip must not kill tasks)."""
    return {"status": "ok", "service": "identity"}


@app.get("/api/auth/health")
def deep_health(db: Session = Depends(get_db)):
    """Readiness through CloudFront: proves the DB path works. Used by the canary."""
    db.execute(text("SELECT 1"))
    return {"status": "ok", "service": "identity", "db": "ok"}


@app.post("/api/auth/register", status_code=201, response_model=UserOut)
def register(body: RegisterIn, response: Response, db: Session = Depends(get_db)):
    user = User(
        id=uuid.uuid4(),
        email=body.email,
        display_name=body.display_name,
        password_hash=hash_password(body.password),
    )
    db.add(user)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status.HTTP_409_CONFLICT, "an account with this email already exists")
    _set_session_cookie(response, issue_token(str(user.id), user.email, user.display_name))
    return UserOut(id=str(user.id), email=user.email, display_name=user.display_name)


@app.post("/api/auth/login", response_model=UserOut)
def login(body: LoginIn, request: Request, response: Response, db: Session = Depends(get_db)):
    if ratelimit.too_many_attempts(body.email):
        raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "too many attempts, try again later")
    user = db.scalar(select(User).where(User.email == body.email))
    # Same message and same work for "no such user" and "bad password".
    if not verify_password(user.password_hash if user else None, body.password):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid email or password")
    ratelimit.reset(body.email)
    if needs_rehash(user.password_hash):
        user.password_hash = hash_password(body.password)
        db.commit()
    _set_session_cookie(response, issue_token(str(user.id), user.email, user.display_name))
    return UserOut(id=str(user.id), email=user.email, display_name=user.display_name)


@app.post("/api/auth/logout", status_code=204)
def logout(response: Response):
    response.delete_cookie(settings.cookie_name, path="/api")
    response.status_code = 204
    return response


@app.get("/api/auth/me", response_model=UserOut)
def me(claims: dict = Depends(current_claims)):
    return UserOut(id=claims["sub"], email=claims["email"], display_name=claims["name"])
