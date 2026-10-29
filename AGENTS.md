# GIF Gallery

Multi-user Django app for hosting, tagging, and sharing GIFs.

## Project structure

```
gif/                    # repo root
  pyproject.toml        # Poetry-managed, deps: django, nanoid, uvicorn, aiofiles, pillow
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
poetry run uvicorn gif.asgi:application --reload  # dev server (ASGI)
poetry run python manage.py test                  # run tests
poetry run python manage.py makemigrations        # after model changes
poetry run python manage.py migrate               # apply migrations
poetry run python manage.py createsuperuser       # create extra superuser accounts
poetry run python manage.py collectstatic         # for production
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
- **Sorting**: `gallery_view` accepts `?sort=` from the `GALLERY_SORTS` whitelist in `views.py` (`newest` — the default — `oldest`, `az`, `za`, `most_used`, `least_used`), remembers it in the session (async `session.aget`/`aset`), and ignores unknown values. Titles sort through `Lower()` since SQLite compares text binary; the usage sorts tiebreak on `-created_at`. Cards show `copy_count` only under `most_used`/`least_used`. The Swift clients re-sort the fetched list in `GalleryViewModel` via `GallerySort` (raw values match the server's keys), so sorting there costs no round trip and `/api/gifs/` needs no `?sort=`.
- **Auth**: Django built-in `LoginView` + `/setup/` signup page. On first run (empty user table) `/login/` redirects to `/setup/`, which creates the first account as a superuser and logs in; subsequent signups via `/setup/` create regular users. No separate signup view. Extra superuser accounts via `manage.py createsuperuser`
- **GIF serving** (`/gif/<id>/`): public (no auth), returns `Cache-Control: public, max-age=31536000, immutable`
- **Production hardening is gated on `DJANGO_SECRET_KEY`**: setting it enables Secure cookies, HSTS, and `SECURE_PROXY_SSL_HEADER`; without it the app runs in dev mode with a public fallback key. The Docker container refuses to start without it.
- **Uploads are validated**: GIF magic bytes + `GIF_MAX_UPLOAD_BYTES` size cap, enforced in `upload_view`
- **Upload title/tag suggestions are Swift-client-only**: the clients propose a title and tags per file on-device (Vision OCR of a few frames + filename words, fed to the Foundation Models LLM). The server is unchanged — the client applies per-file titles/tags after `/upload/` via the rename and tags endpoints. See "Swift clients" below.
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
| `/` | Yes | Gallery with tag filter, search and sort (`?tag=`, `?q=`, `?sort=`) |
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

- **Gif**: Nanoid PK, `owner` FK to User, `title`, `file` (FileField), `thumbnail` (FileField, optional), `tags` M2M to Tag, `copy_count`, `created_at`. Ordered by `-created_at` (newest first).
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
- `GalleryViewModel`: `@Observable` view model shared by macOS and iOS apps. Holds the `sortOrder` (persisted in the shared defaults suite) and exposes `sortedGIFs`; views iterate that, not `gifs`.
- `GallerySort`: The six sort strategies, with raw values matching the server's `?sort=` keys. Sorting happens locally over the fetched list, so switching order needs no refetch. Named `GallerySort` because Foundation already has a `SortOrder`. `showsUsageCount` drives the count badge on `GIFGridItem`.
- `KeychainStore`: Stores bearer token in the keychain (not UserDefaults). Supports app group sharing.
- `SharedStore`: App group configuration (server URL, token). On macOS, derives the Team ID from the code signature at runtime.
- `GIFIngest`: Validates GIF magic bytes on incoming share-sheet items before upload.
- `UploadSuggester`: Proposes a title and tags for a file being uploaded. OCRs up to six frames (Vision `RecognizeTextRequest`), extracts words from the filename (generated names like `IMG_1234`, `photo-3` or UUIDs are dropped), and asks the on-device Foundation Models LLM for a `@Generable` title + tags, passing existing tag names so it reuses them. Returns nil when the model is unavailable (before macOS/iOS 26, Apple Intelligence off, model downloading), when there's no text to go on, or when the model declines. FoundationModels is weak-linked, so the apps still launch on older OSes. Logs under subsystem `me.herko.gif`, category `suggestions`.
- `UploadDetails` / `UploadItemFields`: Per-file title/tag state and fields for the upload sheets (macOS, iOS, both share extensions). Analyzes files one at a time and only fills fields the user hasn't typed into. Queued ids are tracked apart from field contents, because macOS writes a field's binding back as soon as it takes focus. `APIClient.upload(..., details:)` applies them after the upload — `/upload/` returns ids in upload order — best-effort, so a failed rename never prompts a duplicate upload. The fields are hidden where suggestions are unavailable.

`GIFKit` has a test target (`cd clients/GIFKit && swift test`), run in CI before the macOS build.

The macOS app includes App Intents (Shortcuts): Find GIFs, Random GIF, Upload GIFs. The `GIFLobsterIntents.swift` file is duplicated between macOS and iOS (not shared via GIFKit) because App Intents metadata extraction requires the file to be in the app module.