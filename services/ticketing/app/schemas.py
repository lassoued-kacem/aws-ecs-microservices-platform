from datetime import datetime

from pydantic import BaseModel, Field


class EventOut(BaseModel):
    id: str
    slug: str
    name: str
    artist: str
    venue: str
    city: str
    starts_at: datetime
    price_cents: int
    capacity: int
    available: int
    hue: int


class OrderIn(BaseModel):
    event_id: str = Field(pattern=r"^[0-9a-fA-F-]{36}$")
    quantity: int = Field(ge=1, le=6)


class OrderOut(BaseModel):
    id: str
    event_id: str
    event_name: str | None = None
    quantity: int
    total_cents: int
    status: str
    created_at: datetime


class TicketOut(BaseModel):
    ticket_id: str
    order_id: str
    event_id: str
    event_name: str
    seat_code: str
    issued_at: str
