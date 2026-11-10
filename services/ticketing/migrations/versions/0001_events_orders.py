"""events and orders

Revision ID: 0001
Revises:
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "events",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("slug", sa.String(80), nullable=False, unique=True),
        sa.Column("name", sa.String(160), nullable=False),
        sa.Column("artist", sa.String(160), nullable=False),
        sa.Column("venue", sa.String(160), nullable=False),
        sa.Column("city", sa.String(80), nullable=False),
        sa.Column("starts_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("price_cents", sa.Integer, nullable=False),
        sa.Column("capacity", sa.Integer, nullable=False),
        sa.Column("available", sa.Integer, nullable=False),
        sa.Column("hue", sa.Integer, nullable=False, server_default="260"),
        sa.CheckConstraint("available >= 0 AND available <= capacity", name="ck_events_available"),
        schema="ticketing",
    )
    op.create_table(
        "orders",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", UUID(as_uuid=True), nullable=False),
        sa.Column("event_id", UUID(as_uuid=True), sa.ForeignKey("ticketing.events.id"), nullable=False),
        sa.Column("quantity", sa.Integer, nullable=False),
        sa.Column("total_cents", sa.Integer, nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("idempotency_key", sa.String(64), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("quantity > 0", name="ck_orders_quantity"),
        sa.UniqueConstraint("user_id", "idempotency_key", name="uq_orders_user_idem"),
        schema="ticketing",
    )
    op.create_index("ix_orders_user_id", "orders", ["user_id"], schema="ticketing")
    op.create_index("ix_orders_event_id", "orders", ["event_id"], schema="ticketing")


def downgrade() -> None:
    op.drop_table("orders", schema="ticketing")
    op.drop_table("events", schema="ticketing")
