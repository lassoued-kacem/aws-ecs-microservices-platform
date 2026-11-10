import uuid
from datetime import datetime

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, Integer, String, UniqueConstraint, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from .db import SCHEMA, Base


class Event(Base):
    __tablename__ = "events"
    __table_args__ = (
        # The database itself refuses to oversell, whatever the app code does.
        CheckConstraint("available >= 0 AND available <= capacity", name="ck_events_available"),
        {"schema": SCHEMA},
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    slug: Mapped[str] = mapped_column(String(80), unique=True)
    name: Mapped[str] = mapped_column(String(160))
    artist: Mapped[str] = mapped_column(String(160))
    venue: Mapped[str] = mapped_column(String(160))
    city: Mapped[str] = mapped_column(String(80))
    starts_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    price_cents: Mapped[int] = mapped_column(Integer)
    capacity: Mapped[int] = mapped_column(Integer)
    available: Mapped[int] = mapped_column(Integer)
    hue: Mapped[int] = mapped_column(Integer, default=260)  # poster colour for the UI


class Order(Base):
    __tablename__ = "orders"
    __table_args__ = (
        # Idempotency: a retried POST with the same key returns the first order.
        UniqueConstraint("user_id", "idempotency_key", name="uq_orders_user_idem"),
        CheckConstraint("quantity > 0", name="ck_orders_quantity"),
        {"schema": SCHEMA},
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), index=True)
    event_id: Mapped[uuid.UUID] = mapped_column(ForeignKey(f"{SCHEMA}.events.id"), index=True)
    quantity: Mapped[int] = mapped_column(Integer)
    total_cents: Mapped[int] = mapped_column(Integer)
    status: Mapped[str] = mapped_column(String(20), default="CONFIRMED")
    idempotency_key: Mapped[str] = mapped_column(String(64))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
