# GIF Gallery

Multi-user Django app for hosting, tagging, and sharing GIFs.

## Project structure

```
gif/                    # repo root
  pyproject.toml        # uv-managed, deps: django, nanoid, uvicorn, aiofiles, pillow
  Dockerfile            # production container (uvicorn + SQLite on /data volume)
  nginx.conf.example    # production nginx template
  gif/                  # Django root (contains manage.py)
    gif/                # Django project config (settings, urls, wsgi, asgi)
    gallery/            # main app (models, views, templates, static, auth, thumbnails)
    media/              # uploaded GIF files (gitignored)
    staticfiles/        # collectstatic output (gitignored)
  clients/
    GIFKit/             # shared Swift package (API client, models, viewmodel, keychain)
    macos/              # macOS app ("GIF Lobster") — SwiftUI + App Intents
    ios/                # iOS app — SwiftUI + share extension
  .github/workflows/
    docker.yml          # multi-arch Docker build on push to main
    swift.yml           # macOS app build, sign, notarize, DMG on push to main
```

## Commands

All commands run from `gif/gif/` (the directory with `manage.py`):

```bash
uv run uvicorn gif.asgi:application --reload  # dev server (ASGI)
uv run python manage.py test                  # run tests
uv run python manage.py makemigrations        # after model changes
uv run python manage.py migrate               # apply migrations
uv run python manage.py createsuperuser       # create extra superuser accounts
uv run python manage.py collectstatic         # for production
```

Swift client build commands (from `clients/macos/`):
```bash
./build.sh                                    # debug build + ad-hoc sign
./build-release.sh --arch x86_64 --arch arm64 # release build (CI)
```

iOS sideload (from `clients/ios/`):
```bash
export DEVELOPMENT_TEAM=XXXXXXXXXX
./sideload.sh <device-udid>                   # archive + install
```

## Key design decisions

- **Single Django app** (`gallery`) — no need for multiple apps
- **SQLite** database — no concurrency concerns
- **Multi-user**: Each user owns their own GIFs via `Gif.owner` FK. Tags are shared globally. `gallery_view` and `api_list_gifs` filter by `owner=request.user`; GIF-serving endpoints (`/gif/<id>/`, `/thumb/<id>/`) are public (no auth).
- **Nanoid IDs** (12-char) on `Gif` model instead of UUIDs — shorter URLs, uses `nanoid` library
- **Tags**: simple `Tag` model with M2M, not django-taggit — avoids unnecessary dependency
- **Auth**: Django built-in `LoginView` + `/setup/` signup page. On first run (empty user table) `/login/` redirects to `/setup/`, which creates the first account as a superuser and logs in; subsequent signups via `/setup/` create regular users. No separate signup view. Extra superuser accounts via `manage.py createsuperuser`
- **GIF serving** (`/gif/<id>/`): public (no auth), returns `Cache-Control: public, max-age=31536000, immutable`
- **Production hardening is gated on `DJANGO_SECRET_KEY`**: setting it enables Secure cookies, HSTS, and `SECURE_PROXY_SSL_HEADER`; without it the app runs in dev mode with a public fallback key. The Docker container refuses to start without it.
- **Uploads are validated**: GIF magic bytes + `GIF_MAX_UPLOAD_BYTES` size cap, enforced in `upload_view`
- **Bearer-token requests never fall back to session auth** (they're CSRF-exempt, so session fallback would be a CSRF bypass — see `gallery/auth.py`)
- **Async views must resolve `request.user`**: `request.user` is a `SimpleLazyObject` that triggers synchronous DB access when resolved. In async views, use `await request.auser()` or rely on `auth_required` (which sets `request.user = user` for both bearer and session auth). `gallery_view` uses `@login_required` (synchronous) so it manually resolves via `await request.auser()`.
- **CDN assets are version-pinned with SRI hashes** in `base.html`; upgrading requires recomputing the integrity hash
- **Gallery/upload**: requires authentication
- **UI**: DaisyUI v5 + Tailwind CSS v4 via CDN, dark theme (`data-theme="dark"`)
- **No REST API / DRF** — server-rendered templates with minimal vanilla JS
- **API tokens**: Created via `/settings/`, stored as SHA-256 hashes in `APIToken` model. Raw token shown once, then never retrievable. Bearer auth via `Authorization: Bearer <token>` header.

## URL scheme

| URL | Auth | Purpose |
|-----|------|---------|
| `/` | Yes | Gallery with tag filter and search (`?tag=`, `?q=`) |
| `/gif/<id>/` | No | Embed page (public, shows GIF + sharing links) |
| `/gif/<id>.gif` | No | Serve GIF file (public, cached) |
| `/thumb/<id>.gif` | No | Serve thumbnail (public, cached; falls back to full GIF) |
| `/gif/<id>/tags/` | Yes | POST to update tags (JSON response) |
| `/gif/<id>/rename/` | Yes | POST to rename (JSON response) |
| `/gif/<id>/copy/` | Yes | POST to increment copy counter (JSON response) |
| `/gif/<id>/delete/` | Yes | POST to delete GIF (JSON response) |
| `/upload/` | Yes | Multi-file upload with drag-drop |
| `/settings/` | Yes | Change password, create/list/delete API tokens |
| `/settings/password/` | Yes | POST to change password |
| `/settings/tokens/create/` | Yes | POST to create API token |
| `/settings/tokens/<id>/delete/` | Yes | POST to delete API token |
| `/api/gifs/` | Yes | JSON list of GIFs (used by Swift clients; supports `?tag=` and `?q=`) |
| `/login/` | No | Login form (redirects to `/setup/` while no account exists) |
| `/setup/` | No | First-run or signup page (first user becomes superuser, subsequent users are regular) |
| `/logout/` | Yes | Logout |
| `/admin/` | Staff | Django admin |

## Data models

- **Gif**: Nanoid PK, `owner` FK to User, `title`, `file` (FileField), `thumbnail` (FileField, optional), `tags` M2M to Tag, `copy_count`, `created_at`. Ordered by `-copy_count, -created_at`.
- **Tag**: Auto-increment PK, `name` (unique), `slug` (unique). Ordered by `name`.
- **APIToken**: Auto-increment PK, `user` FK, `name` (label), `token_hash` (SHA-256, unique), `created_at`. Raw token is never stored.

## Auth architecture

Two auth paths in `gallery/auth.py`:

1. **Bearer token**: `Authorization: Bearer <token>` header → `_get_bearer_user()` hashes the token and looks up `APIToken` → sets `request.user` directly. CSRF-exempt via middleware.

2. **Session auth**: Fallback when no Bearer header → `await request.auser()` → check `is_authenticated`. Sets `request.user = user` to avoid the lazy object trap.

The `auth_required` decorator is used on all async views that need auth. It returns JSON `{"error": "..."}` with 401, not redirects — the Swift clients use the API endpoints exclusively.

The `@login_required` decorator (sync) is used only on `gallery_view` (server-rendered HTML) and `settings_view`/`change_password_view`/`create_token_view`/`delete_token_view` (sync views). It redirects to `/login/` for unauthenticated users.

## Thumbnails

`gallery/thumbnails.py` generates animated GIF thumbnails using Pillow:
- Max width: 320px (scaled proportionally)
- Frame rate halved (every other frame, durations merged)
- 256-color palette quantization for smaller files
- Generated on upload (in `upload_view`) and via `manage.py generate_thumbnails`

## Swift clients

The shared `GIFKit` package provides:
- `APIClient`: All API calls (list, upload, rename, tag, delete, copy). Uses `URLSession` with a large persistent cache.
- `GalleryViewModel`: `@Observable` view model shared by macOS and iOS apps.
- `KeychainStore`: Stores bearer token in the keychain (not UserDefaults). Supports app group sharing.
- `SharedStore`: App group configuration (server URL, token). On macOS, derives the Team ID from the code signature at runtime.
- `GIFIngest`: Validates GIF magic bytes on incoming share-sheet items before upload.

The macOS app includes App Intents (Shortcuts): Find GIFs, Random GIF, Upload GIFs. The `GIFLobsterIntents.swift` file is duplicated between macOS and iOS (not shared via GIFKit) because App Intents metadata extraction requires the file to be in the app module.