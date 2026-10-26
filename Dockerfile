# syntax=docker/dockerfile:1

# GIF Gallery — Django application container.
#
# Uses the official Python 3.14 image, installs dependencies with Poetry from
# the locked pyproject/poetry.lock, collects static files, and serves the app
# over ASGI with uvicorn. Persistent data (SQLite DB + uploaded GIFs) is
# expected on a mounted volume via DJANGO_DB_PATH / DJANGO_MEDIA_ROOT.

FROM python:3.14-slim-trixie

# Poetry/runtime environment:
#  - Poetry lives in its own venv under /opt/poetry, separate from the app
#  - the app venv is created in-project at /app/.venv
#  - keep the venv on PATH so `uvicorn`/`python` resolve without `poetry run`
#  - never buffer stdout/stderr so container logs appear immediately
ENV POETRY_HOME=/opt/poetry \
    POETRY_VIRTUALENVS_IN_PROJECT=1 \
    POETRY_NO_INTERACTION=1 \
    POETRY_CACHE_DIR=/root/.cache/pypoetry \
    PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1

WORKDIR /app

RUN apt update && apt -y install gifsicle ffmpeg && apt -y dist-upgrade

# Install Poetry into an isolated venv so its own dependencies never mix with
# the app's. Pinned to the version the lockfile was generated with.
RUN python -m venv "$POETRY_HOME" \
    && "$POETRY_HOME/bin/pip" install --no-cache-dir poetry==2.4.1

# Install dependencies from the lockfile before copying the source so this
# layer is cached and only rebuilt when the lockfile changes. Poetry refuses
# to install from a lockfile that is out of date with pyproject.toml, so a
# stale lock fails the build rather than silently re-resolving. --compile
# precompiles bytecode for faster startup. The project itself is never
# installed (package-mode = false), so no second install step is needed.
RUN --mount=type=cache,target=/root/.cache/pypoetry \
    --mount=type=bind,source=poetry.lock,target=poetry.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    "$POETRY_HOME/bin/poetry" install --only main --compile

# Copy the application source.
COPY . /app

# Collect static assets into STATIC_ROOT (gif/staticfiles). A throwaway
# SECRET_KEY is fine here — collectstatic touches no secrets.
RUN DJANGO_SECRET_KEY=build-only-not-a-real-secret-0123456789abcdefghijklmnop \
    python gif/manage.py collectstatic --noinput

# Persistent data lives here by default; mount a volume to keep it.
ENV DJANGO_DB_PATH=/data/db.sqlite3 \
    DJANGO_MEDIA_ROOT=/data/media
RUN mkdir -p /data/media
VOLUME ["/data"]

# Run as a non-root user that owns the data directory.
RUN useradd --create-home --uid 10001 app \
    && chown -R app:app /app /data
USER app

EXPOSE 8000

# Apply migrations, then serve. The database is created on first run if the
# mounted volume is empty. Refuse to start without a real DJANGO_SECRET_KEY —
# the in-repo fallback key is public, and providing one is also what enables
# the app's HTTPS hardening. Generate one with:
#   python3 -c 'import secrets; print(secrets.token_urlsafe(50))'
CMD ["sh", "-c", ": \"${DJANGO_SECRET_KEY:?Set DJANGO_SECRET_KEY to a real secret (see README)}\" && python gif/manage.py migrate --noinput && uvicorn --app-dir gif gif.asgi:application --host 0.0.0.0 --port 8000"]
