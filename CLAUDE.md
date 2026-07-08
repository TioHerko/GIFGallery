# GIF Gallery

Single-user Django app for hosting, tagging, and sharing GIFs.

## Project structure

```
gif/                    # repo root
  pyproject.toml        # uv-managed, deps: django, nanoid, uvicorn
  nginx.conf.example    # production nginx template
  gif/                  # Django root (contains manage.py)
    gif/                # Django project config (settings, urls, wsgi, asgi)
    gallery/            # main app (models, views, templates, static)
    media/              # uploaded GIF files (gitignored)
    staticfiles/        # collectstatic output (gitignored)
```

## Commands

All commands run from `gif/gif/` (the directory with `manage.py`):

```bash
uv run uvicorn gif.asgi:application --reload  # dev server (ASGI)
uv run python manage.py test             # run tests
uv run python manage.py makemigrations   # after model changes
uv run python manage.py migrate          # apply migrations
uv run python manage.py createsuperuser  # create a user (only way to create accounts)
uv run python manage.py collectstatic    # for production
```

## Key design decisions

- **Single Django app** (`gallery`) — no need for multiple apps
- **SQLite** database — single-user, no concurrency concerns
- **Nanoid IDs** (12-char) on `Gif` model instead of UUIDs — shorter URLs, uses `nanoid` library
- **Tags**: simple `Tag` model with M2M, not django-taggit — avoids unnecessary dependency
- **Auth**: Django built-in `LoginView`, no signup view. Accounts created only via `manage.py createsuperuser`
- **GIF serving** (`/gif/<id>/`): public (no auth), returns `Cache-Control: public, max-age=31536000, immutable`
- **Production hardening is gated on `DJANGO_SECRET_KEY`**: setting it enables Secure cookies, HSTS, and `SECURE_PROXY_SSL_HEADER`; without it the app runs in dev mode with a public fallback key. The Docker container refuses to start without it.
- **Uploads are validated**: GIF magic bytes + `GIF_MAX_UPLOAD_BYTES` size cap, enforced in `upload_view`
- **Bearer-token requests never fall back to session auth** (they're CSRF-exempt, so session fallback would be a CSRF bypass — see `gallery/auth.py`)
- **CDN assets are version-pinned with SRI hashes** in `base.html`; upgrading requires recomputing the integrity hash
- **Gallery/upload**: requires authentication
- **UI**: DaisyUI v5 + Tailwind CSS v4 via CDN, dark theme (`data-theme="dark"`)
- **No REST API / DRF** — server-rendered templates with minimal vanilla JS

## URL scheme

| URL | Auth | Purpose |
|-----|------|---------|
| `/` | Yes | Gallery with tag filter and search (`?tag=`, `?q=`) |
| `/gif/<id>/` | No | Serve GIF file (public, cached) |
| `/gif/<id>/tags/` | Yes | POST to update tags (JSON response) |
| `/upload/` | Yes | Multi-file upload with drag-drop |
| `/login/` | No | Login form |
| `/logout/` | Yes | Logout |
| `/admin/` | Staff | Django admin |
