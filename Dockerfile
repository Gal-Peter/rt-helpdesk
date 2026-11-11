# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Stage "base": everything both the runtime and test images share.
# Dependencies are installed BEFORE the app source is copied, so a source-only
# change reuses the cached dependency layer.
# ---------------------------------------------------------------------------
FROM python:3.12-slim-bookworm AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Fixed, non-login user and group (UID/GID 10001) for running the app.
RUN groupadd --gid 10001 app \
 && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin app

# Dependency layer: only requirements.txt is copied here.
COPY requirements.txt ./
RUN python -m pip install --no-cache-dir -r requirements.txt

# Application source and server config. Owned by root and read-only to the app
# user, so the container also works with a read-only root filesystem.
COPY app/ ./app/
COPY gunicorn.conf.py ./

# ---------------------------------------------------------------------------
# Stage "test": runtime contents + test dependencies + tests.
# Not last, so it is never the default build result.
# ---------------------------------------------------------------------------
FROM base AS test

COPY requirements-dev.txt pytest.ini ./
COPY tests/ ./tests/
# Installing packages needs root, so USER is set only afterwards.
RUN python -m pip install --no-cache-dir -r requirements-dev.txt

USER 10001:10001
CMD ["python", "-m", "pytest", "-q", "-p", "no:cacheprovider"]

# ---------------------------------------------------------------------------
# Stage "runtime": the web application image. It is the LAST stage, so a plain
# `docker build` (no --target) produces this image. No pytest, no tests.
# ---------------------------------------------------------------------------
FROM base AS runtime

# Release version, baked into the image. Not a secret.
ARG APP_VERSION=local
ENV APP_VERSION=${APP_VERSION}

USER 10001:10001
EXPOSE 8000

# Exec (JSON) form: gunicorn runs as PID 1 and receives SIGTERM on container
# stop. Compose overrides this for the one-time init-db step.
CMD ["gunicorn", "--config", "gunicorn.conf.py", "app:create_app()"]
