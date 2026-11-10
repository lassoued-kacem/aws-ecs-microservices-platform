"""Runtime configuration. Every value comes from the environment.

In AWS, secrets (DB password, JWT key, cache token) are injected by ECS from
SSM Parameter Store through the task definition `secrets` field, so the code
never talks to SSM and never sees anything that is not already in its env.
"""

from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=None, extra="ignore")

    service_name: str = "ticketing"
    environment: str = "local"

    db_host: str = "localhost"
    db_port: int = 5432
    db_name: str = "ticketrush"
    db_user: str = "ticketrush"
    db_password: str = Field(default="localdev", repr=False)
    # verify-full in AWS (RDS CA bundle baked into the image); disable locally.
    db_sslmode: str = "disable"
    db_sslrootcert: str = "/srv/certs/rds-global-bundle.pem"

    redis_url: str = "redis://localhost:6379/0"
    redis_auth_token: str = Field(default="", repr=False)

    jwt_secret: str = Field(default="local-dev-secret-change-me-32bytes!!", repr=False)
    jwt_issuer: str = "ticketrush-identity"
    jwt_ttl_seconds: int = 3600

    cookie_secure: bool = False
    cookie_name: str = "tr_session"

    aws_region: str = "eu-west-3"
    # Empty = feature disabled locally (no SQS / DynamoDB needed for dev).
    orders_queue_url: str = ""
    tickets_table: str = ""
    aws_endpoint_url: str = ""  # only for local emulators

    max_tickets_per_user_per_event: int = 6
    purchase_max_per_minute: int = 10
    events_cache_ttl_seconds: int = 15
    event_cache_ttl_seconds: int = 5
    metrics_namespace: str = "TicketRush/Business"

    run_migrations: bool = True

    @property
    def database_url(self) -> str:
        return f"postgresql+psycopg://{self.db_user}:{self.db_password}@{self.db_host}:{self.db_port}/{self.db_name}"

    @property
    def connect_args(self) -> dict:
        args = {"sslmode": self.db_sslmode, "connect_timeout": 5}
        if self.db_sslmode in ("verify-ca", "verify-full"):
            args["sslrootcert"] = self.db_sslrootcert
        return args


@lru_cache
def get_settings() -> Settings:
    return Settings()
