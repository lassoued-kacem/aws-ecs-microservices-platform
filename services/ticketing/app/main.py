import logging
import time
import uuid
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Header, HTTPException, Request, status
from fastapi.responses import JSONResponse
from sqlalchemy import func, select, text, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from . import aws, cache
from .auth import current_user_id
from .config import get_settings
from .db import engine, get_db
from .logging_setup import setup_logging
from .migrate import run_migrations
from .models import Event, Order
from .schemas import EventOut, OrderIn, OrderOut, TicketOut
from .telemetry import setup_tracing

setup_logging()
log = logging.getLogger("ticketing")
settings = get_settings()

EVENTS_KEY = "ticketing:events:v1"


def event_key(event_id: str) -> str:
    return f"ticketing:event:v1:{event_id}"


@asynccontextmanager
async def lifespan(_: FastAPI):
    if settings.run_migrations:
        run_migrations()
    yield


app = FastAPI(
    title="TicketRush ticketing",
    lifespan=lifespan,
    docs_url="/api/docs" if settings.environment == "local" else None,
    openapi_url="/api/openapi.json" if settings.environment == "local" else None,
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


def _event_out(e: Event) -> dict:
    return EventOut(
        id=str(e.id),
        slug=e.slug,
        name=e.name,
        artist=e.artist,
        venue=e.venue,
        city=e.city,
        starts_at=e.starts_at,
        price_cents=e.price_cents,
        capacity=e.capacity,
        available=e.available,
        hue=e.hue,
    ).model_dump(mode="json")


def _parse_uuid(value: str) -> uuid.UUID:
    try:
        return uuid.UUID(value)
    except ValueError:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "event not found")


@app.get("/health")
def health():
    return {"status": "ok", "service": "ticketing"}


@app.get("/api/health")
def deep_health(db: Session = Depends(get_db)):
    db.execute(text("SELECT 1"))
    cache_ok = True
    try:
        cache.client().ping()
    except Exception:
        cache_ok = False
    return {"status": "ok", "service": "ticketing", "db": "ok", "cache": "ok" if cache_ok else "degraded"}


@app.get("/api/events", response_model=list[EventOut])
def list_events(db: Session = Depends(get_db)):
    cached = cache.get_json(EVENTS_KEY)
    if cached is not None:
        aws.emit_metric("CacheHit", 1, Resource="events")
        return cached
    aws.emit_metric("CacheMiss", 1, Resource="events")
    rows = db.scalars(select(Event).order_by(Event.starts_at)).all()
    data = [_event_out(e) for e in rows]
    cache.set_json(EVENTS_KEY, data, settings.events_cache_ttl_seconds)
    return data


@app.get("/api/events/{event_id}", response_model=EventOut)
def get_event(event_id: str, db: Session = Depends(get_db)):
    eid = _parse_uuid(event_id)
    cached = cache.get_json(event_key(str(eid)))
    if cached is not None:
        return cached
    e = db.get(Event, eid)
    if e is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "event not found")
    data = _event_out(e)
    cache.set_json(event_key(str(eid)), data, settings.event_cache_ttl_seconds)
    return data


@app.post("/api/orders", status_code=201, response_model=OrderOut)
def create_order(
    body: OrderIn,
    user_id: uuid.UUID = Depends(current_user_id),
    idempotency_key: str = Header(..., alias="Idempotency-Key", min_length=8, max_length=64),
    db: Session = Depends(get_db),
):
    if cache.rate_limited(f"ticketing:rl:{user_id}", settings.purchase_max_per_minute, 60):
        raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "slow down")

    # Replay: same user + same key -> same order, no second charge.
    existing = db.scalar(select(Order).where(Order.user_id == user_id, Order.idempotency_key == idempotency_key))
    if existing:
        return _order_out(existing)

    eid = _parse_uuid(body.event_id)
    # Serialise purchases of ONE user for ONE event (per-user cap), without
    # blocking other buyers of the same event. Released at commit/rollback.
    db.execute(
        text("SELECT pg_advisory_xact_lock(hashtextextended(:k, 0))"),
        {"k": f"{user_id}:{eid}"},
    )
    already = db.scalar(select(func.coalesce(func.sum(Order.quantity), 0)).where(Order.user_id == user_id, Order.event_id == eid))
    if already + body.quantity > settings.max_tickets_per_user_per_event:
        db.rollback()
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"limit is {settings.max_tickets_per_user_per_event} tickets per person for this event",
        )

    # THE anti-oversell statement: one atomic conditional decrement. Under any
    # concurrency, Postgres row locking guarantees `available` never goes < 0.
    row = db.execute(
        update(Event)
        .where(Event.id == eid, Event.available >= body.quantity)
        .values(available=Event.available - body.quantity)
        .returning(Event.price_cents, Event.name)
    ).first()
    if row is None:
        db.rollback()
        exists = db.get(Event, eid) is not None
        aws.emit_metric("SoldOutRejections", 1)
        if not exists:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "event not found")
        raise HTTPException(status.HTTP_409_CONFLICT, "not enough tickets left")

    order = Order(
        id=uuid.uuid4(),
        user_id=user_id,
        event_id=eid,
        quantity=body.quantity,
        total_cents=row.price_cents * body.quantity,
        status="CONFIRMED",
        idempotency_key=idempotency_key,
    )
    db.add(order)
    try:
        db.commit()
    except IntegrityError:
        # Two concurrent requests with the same key: the loser returns the winner.
        db.rollback()
        existing = db.scalar(select(Order).where(Order.user_id == user_id, Order.idempotency_key == idempotency_key))
        if existing:
            return _order_out(existing)
        raise

    cache.delete(EVENTS_KEY, event_key(str(eid)))
    aws.emit_metric("TicketsSold", body.quantity)
    aws.emit_metric("Revenue", order.total_cents / 100, unit="None")
    aws.publish_order_confirmed(
        {
            "type": "order.confirmed",
            "order_id": str(order.id),
            "user_id": str(user_id),
            "event_id": str(eid),
            "event_name": row.name,
            "quantity": order.quantity,
        }
    )
    return _order_out(order, row.name)


def _order_out(o: Order, event_name: str | None = None) -> OrderOut:
    return OrderOut(
        id=str(o.id),
        event_id=str(o.event_id),
        event_name=event_name,
        quantity=o.quantity,
        total_cents=o.total_cents,
        status=o.status,
        created_at=o.created_at,
    )


@app.get("/api/orders", response_model=list[OrderOut])
def my_orders(user_id: uuid.UUID = Depends(current_user_id), db: Session = Depends(get_db)):
    rows = db.execute(
        select(Order, Event.name)
        .join(Event, Event.id == Order.event_id)
        .where(Order.user_id == user_id)
        .order_by(Order.created_at.desc())
        .limit(100)
    ).all()
    return [_order_out(o, name) for o, name in rows]


@app.get("/api/tickets", response_model=list[TicketOut])
def my_tickets(user_id: uuid.UUID = Depends(current_user_id)):
    return [TicketOut(**{k: str(item.get(k, "")) for k in TicketOut.model_fields}) for item in aws.list_tickets(str(user_id))]
