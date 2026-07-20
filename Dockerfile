# syntax=docker/dockerfile:1

# GIF Gallery — Django application container.
#
# Uses the official uv image (Python 3.14) to install dependencies from the
# locked pyproject/uv.lock, collects static files, and serves the app over
# ASGI with uvicorn. Persistent data (SQLite DB + uploaded GIFs) is expected
# on a mounted volume via DJANGO_DB_PATH / DJANGO_MEDIA_ROOT.

FROM ghcr.io/astral-sh/uv:python3.14-trixie-slim

# uv/runtime environment:
#  - compile bytecode for faster startup
#  - copy (don't symlink) packages so the venv is self-contained
#  - keep the venv on PATH so `uvicorn`/`python` resolve without `uv run`
#  - never buffer stdout/stderr so container logs appear immediately
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1

WORKDIR /app

RUN apt update && apt -y install gifsicle ffmpeg && apt -y dist-upgrade

# Install dependencies first (without the project source) so this layer is
# cached and only rebuilt when the lockfile changes.
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --frozen --no-install-project --no-dev

# Copy the application source and install the project itself.
COPY . /app
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev

# Collect static assets into STATIC_ROOT (gif/staticfiles). A throwaway
# SECRET_KEY is fine here — collectstatic touches no secrets.
RUN DJANGO_SECRET_KEY=build-only \
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
