# GIF Gallery

Multi-user Django app for hosting, tagging, and sharing GIFs.

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
uv run python manage.py createsuperuser  # create extra accounts (first one comes from /setup/)
uv run python manage.py collectstatic    # for production
```

## Key design decisions

- **Single Django app** (`gallery`) — no need for multiple apps
- **SQLite** database — single-user, no concurrency concerns
- **Multi-user**: Each user owns their own GIFs via `Gif.owner` FK. Tags are shared globally. The `gallery_view` and `api_list_gifs` views filter by `owner=request.user`; GIF-serving endpoints (`/gif/<id>/`, `/thumb/<id>/`) are public (no auth).
- **Nanoid IDs** (12-char) on `Gif` model instead of UUIDs — shorter URLs, uses `nanoid` library
- **Tags**: simple `Tag` model with M2M, not django-taggit — avoids unnecessary dependency
- **Auth**: Django built-in `LoginView` + `/setup/` signup page. On first run (empty user table) `/login/` redirects to `/setup/`, which creates the first account as a superuser and logs in; subsequent signups via `/setup/` create regular users. No separate signup view. Extra superuser accounts via `manage.py createsuperuser`
- **GIF serving** (`/gif/<id>/`): public (no auth), returns `Cache-Control: public, max-age=31536000, immutable`
- **Production hardening is gated on `DJANGO_SECRET_KEY`**: setting it enables Secure cookies, HSTS, and `SECURE_PROXY_SSL_HEADER`; without it the app runs in dev mode with a public fallback key. The Docker container refuses to start without it.
- **Uploads are validated**: GIF magic bytes + `GIF_MAX_UPLOAD_BYTES` size cap, enforced in `upload_view`
- **Video uploads** (mp4/mov/mkv): `upload_view` accepts short clips (`VIDEO_MAX_DURATION_SECONDS`, default 10s, surfaced in the upload UI) and transcodes them to GIF with ffmpeg (`gallery/video.py`), preserving source framerate and downscaling to at most `VIDEO_MAX_WIDTH` px wide (default 640; aspect ratio preserved, narrower clips untouched), then runs the result through gifsicle. The movie is written to a temp dir (never MEDIA_ROOT), probed with ffprobe for duration, converted, and deleted — only the produced GIF is stored. ffmpeg/ffprobe calls are bounded by `FFMPEG_TIMEOUT_SECONDS`. Requires the `ffmpeg` package (installed in the Dockerfile; bundles ffprobe).
- **Bearer-token requests never fall back to session auth** (they're CSRF-exempt, so session fallback would be a CSRF bypass — see `gallery/auth.py`)
- **Async views must resolve `request.user`**: `request.user` is a `SimpleLazyObject` that triggers synchronous DB access when resolved. In async views, use `await request.auser()` or rely on `auth_required` (which sets `request.user = user` for both bearer and session auth). `gallery_view` uses `@login_required` (synchronous) so it manually resolves via `await request.auser()`.
- **CDN assets are version-pinned with SRI hashes** in `base.html`; upgrading requires recomputing the integrity hash
- **Gallery/upload**: requires authentication
- **UI**: DaisyUI v5 + Tailwind CSS v4 via CDN, dark theme (`data-theme="dark"`)
- **No REST API / DRF** — server-rendered templates with minimal vanilla JS

## URL scheme

| URL | Auth | Purpose |
|-----|------|---------|
| `/` | Yes | Gallery with tag filter and search (`?tag=`, `?q=`) |
| `/api/config/` | Yes | Upload limits (video max duration/width, max bytes, video extensions) as JSON — clients validate before uploading |
| `/gif/<id>/` | No | Serve GIF file (public, cached) |
| `/gif/<id>/tags/` | Yes | POST to update tags (JSON response) |
| `/upload/` | Yes | Multi-file upload with drag-drop |
| `/settings/` | Yes | Change password, create/list/delete API tokens |
| `/login/` | No | Login form (redirects to `/setup/` while no account exists) |
| `/setup/` | No | First-run or signup page (first user becomes superuser, subsequent users are regular) |
| `/logout/` | Yes | Logout |
| `/admin/` | Staff | Django admin |
