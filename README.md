# GIF Gallery

**This repository is mostly vibe-coded. If you feel uneasy about that, please don't use it.** \*

This repository contains a Django application to run on a Linux/UNIX-y system. It provides GIF storage, handling, and distribution. The source code is available here, and binary artifacts are in the Releases page. It also includes a macOS native client with a little bit of extra functionality (for example, it can send GIFs straight to a Discord conversation).

The Django application requires:

- uv
- nginx, Apache, or Caddy to front it

I also put a free Cloudflare account in front of it, for proxying and responsiveness.

## Running with Docker

A `Dockerfile` is included that installs the application and serves it over ASGI
(uvicorn) on port 8000. It works with Docker or Podman (swap `docker` for
`podman` in the commands below).

### Build

From the repository root:

```bash
docker build -t gif-gallery .
```

### Run

Persistent data — the SQLite database and uploaded GIFs — lives under `/data`
inside the container. Mount a volume there so it survives restarts and upgrades:

```bash
docker run -d --name gif \
  -p 8000:8000 \
  -v gif-data:/data \
  -e DJANGO_SECRET_KEY="$(openssl rand -base64 48)" \
  -e DJANGO_ALLOWED_HOSTS="gif.example.com,127.0.0.1" \
  -e DJANGO_CSRF_TRUSTED_ORIGINS="https://gif.example.com" \
  gif-gallery
```

The container runs database migrations automatically on startup and creates the
database on first run if the volume is empty.

### Create a user

Accounts can only be created from the command line (there is no signup page).
After the container is running:

```bash
docker exec -it gif python gif/manage.py createsuperuser
```

### Configuration

The image is configured through environment variables (all optional):

| Variable | Default | Purpose |
|----------|---------|---------|
| `DJANGO_SECRET_KEY` | insecure dev key | Django secret key — **set this in production** |
| `DJANGO_DEBUG` | `False` | Enable debug mode (`true`/`false`) |
| `DJANGO_ALLOWED_HOSTS` | `gif.herko.me,127.0.0.1` | Comma-separated allowed hostnames |
| `DJANGO_CSRF_TRUSTED_ORIGINS` | `https://gif.herko.me` | Comma-separated trusted origins for CSRF |
| `DJANGO_DB_PATH` | `/data/db.sqlite3` | Path to the SQLite database file |
| `DJANGO_MEDIA_ROOT` | `/data/media` | Directory for uploaded GIFs |

### Fronting it

The container serves the app directly, but for production you still want a
reverse proxy (nginx/Caddy/Cloudflare) in front of it — see
`nginx.conf.example`. Static assets are collected into the image at build time;
uploaded GIFs live in the `/data` volume and can be served straight from disk by
the proxy for better performance.

\*I am fluent in Python and Django, have reviewed it, and it's not doing anything weird as far as I can tell
