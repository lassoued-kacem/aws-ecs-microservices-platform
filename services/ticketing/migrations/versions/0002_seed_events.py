"""seed demo events (idempotent: ON CONFLICT DO NOTHING)

Revision ID: 0002
Revises: 0001
"""

import uuid
from datetime import UTC, datetime, timedelta

import sqlalchemy as sa
from alembic import op

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None

NS = uuid.UUID("6f1c2b8e-3f43-4a6e-9a51-6c1d7b3e0a11")  # stable ids across rebuilds
EVENTS = [
    ("neon-tide-paris", "Neon Tide: World Tour", "Neon Tide", "Accor Arena", "Paris", 89_00, 500, 290),
    ("desert-echo-tunis", "Desert Echo Live", "Desert Echo", "Théâtre de Carthage", "Tunis", 45_00, 300, 30),
    ("kernel-panic-berlin", "Kernel Panic (Techno Night)", "Kernel Panic", "Tresor", "Berlin", 35_00, 200, 200),
    ("sre-summit-lyon", "SRE Summit 2027", "Speakers: various", "Centre de Congrès", "Lyon", 120_00, 150, 160),
    ("aurora-strings-dubai", "Aurora Strings Orchestra", "Aurora Strings", "Coca-Cola Arena", "Dubai", 75_00, 400, 50),
    ("flash-drop-only-10", "Flash Drop: 10 Seats Only", "Mystery Headliner", "Le Petit Bain", "Paris", 15_00, 10, 340),
    ("latency-blues-london", "Latency Blues", "The p99s", "Roundhouse", "London", 55_00, 250, 10),
    ("zero-downtime-madrid", "Zero Downtime Festival", "Various artists", "IFEMA", "Madrid", 99_00, 800, 120),
]


def upgrade() -> None:
    now = datetime.now(UTC).replace(hour=20, minute=0, second=0, microsecond=0)
    events = sa.table(
        "events",
        sa.column("id"),
        sa.column("slug"),
        sa.column("name"),
        sa.column("artist"),
        sa.column("venue"),
        sa.column("city"),
        sa.column("starts_at"),
        sa.column("price_cents"),
        sa.column("capacity"),
        sa.column("available"),
        sa.column("hue"),
        schema="ticketing",
    )
    rows = [
        dict(
            id=uuid.uuid5(NS, slug),
            slug=slug,
            name=name,
            artist=artist,
            venue=venue,
            city=city,
            starts_at=now + timedelta(days=14 + 9 * i),
            price_cents=price,
            capacity=cap,
            available=cap,
            hue=hue,
        )
        for i, (slug, name, artist, venue, city, price, cap, hue) in enumerate(EVENTS)
    ]
    from sqlalchemy.dialects.postgresql import insert

    op.get_bind().execute(insert(events).values(rows).on_conflict_do_nothing(index_elements=["slug"]))


def downgrade() -> None:
    op.get_bind().execute(sa.text("DELETE FROM ticketing.events WHERE slug = ANY(:slugs)"), {"slugs": [e[0] for e in EVENTS]})
