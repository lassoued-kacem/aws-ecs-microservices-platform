from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, sessionmaker

from .config import get_settings

SCHEMA = "identity"


class Base(DeclarativeBase):
    pass


_settings = get_settings()
# pool_pre_ping: survives RDS Multi-AZ failover (stale connections are recycled
# instead of surfacing as 500s). Small pool: one Fargate task = one process.
engine = create_engine(
    _settings.database_url,
    connect_args=_settings.connect_args,
    pool_size=5,
    max_overflow=5,
    pool_pre_ping=True,
    pool_recycle=300,
)
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
