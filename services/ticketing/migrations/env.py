from alembic import context
from app import models  # noqa: F401  (register tables)
from app.db import SCHEMA, Base

connection = context.config.attributes.get("connection")
if connection is None:
    from app.db import engine

    connection = engine.connect()

context.configure(
    connection=connection,
    target_metadata=Base.metadata,
    version_table_schema=SCHEMA,
    include_schemas=True,
)
with context.begin_transaction():
    context.run_migrations()
