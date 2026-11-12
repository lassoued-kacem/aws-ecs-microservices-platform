# syntax=docker/dockerfile:1.7
# ---------- build stage: compile/download wheels, never shipped ----------
FROM python:3.14-slim-bookworm AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
# Compiler only in the build stage: used solely if a dependency has no prebuilt
# wheel for this CPU/Python. The runtime image never contains it.
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY requirements.txt .
RUN python -m venv /opt/venv \
 && /opt/venv/bin/pip install --upgrade pip \
 && /opt/venv/bin/pip install -r requirements.txt
# RDS CA bundle so Postgres connections use sslmode=verify-full (no MITM).
ADD --chmod=0444 https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /build/certs/rds-global-bundle.pem

# ---------- runtime stage: small, non-root, read-only friendly ----------
FROM python:3.14-slim-bookworm AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    PORT=8000
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app
WORKDIR /srv
COPY --from=build /opt/venv /opt/venv
COPY --from=build /build/certs /srv/certs
COPY alembic.ini ./
COPY migrations ./migrations
COPY app ./app
USER 10001:10001
EXPOSE 8000
# Container-level health check (ECS also defines one; this one helps local runs).
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health',timeout=2).status==200 else 1)"
# exec form -> uvicorn is PID 1 and receives SIGTERM from ECS for graceful drain.
CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips", "*", "--timeout-graceful-shutdown", "20"]
