"""Run Alembic migrations safely when several tasks start at once.

A Postgres advisory lock serialises migrations: the first task migrates, the
others wait then find nothing to do. No separate migration job needed.
"""

import logging
from pathlib import Path

from alembic import command
from alembic.config import Config
from sqlalchemy import text

from .db import SCHEMA, engine

log = logging.getLogger(__name__)
LOCK_ID = 7_301_002  # arbitrary, unique per service


def run_migrations() -> None:
    cfg = Config(str(Path(__file__).resolve().parent.parent / "alembic.ini"))
    with engine.begin() as conn:
        conn.execute(text("SELECT pg_advisory_lock(:id)"), {"id": LOCK_ID})
        try:
            conn.execute(text(f'CREATE SCHEMA IF NOT EXISTS "{SCHEMA}"'))
            cfg.attributes["connection"] = conn
            command.upgrade(cfg, "head")
            log.info("migrations up to date")
        finally:
            conn.execute(text("SELECT pg_advisory_unlock(:id)"), {"id": LOCK_ID})
