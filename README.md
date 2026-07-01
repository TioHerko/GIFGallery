# GIF Gallery

**This repository is mostly vibe-coded. If you feel uneasy about that, please don't use it.** \*

This repository contains a Django application to run on a Linux/UNIX-y system. It provides GIF storage, handling, and distribution. The source code is available here, and binary artifacts are in the Releases page. It also includes a macOS native client with a little bit of extra functionality (for example, it can send GIFs straight to a Discord conversation).

The Django application requires:

- uv
- nginx, Apache, or Caddy to front it

I also put a free Cloudflare account in front of it, for proxying and responsiveness.

\*I am fluent in Python and Django, have reviewed it, and it's not doing anything weird as far as I can tell

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

| Variable                      | Default                  | Purpose                                        |
| ----------------------------- | ------------------------ | ---------------------------------------------- |
| `DJANGO_SECRET_KEY`           | insecure dev key         | Django secret key — **set this in production** |
| `DJANGO_DEBUG`                | `False`                  | Enable debug mode (`true`/`false`)             |
| `DJANGO_ALLOWED_HOSTS`        | `gif.herko.me,127.0.0.1` | Comma-separated allowed hostnames              |
| `DJANGO_CSRF_TRUSTED_ORIGINS` | `https://gif.herko.me`   | Comma-separated trusted origins for CSRF       |
| `DJANGO_DB_PATH`              | `/data/db.sqlite3`       | Path to the SQLite database file               |
| `DJANGO_MEDIA_ROOT`           | `/data/media`            | Directory for uploaded GIFs                    |

### Fronting it

The container serves the app directly, but for production you still want a
reverse proxy (nginx/Caddy/Cloudflare) in front of it — see
`nginx.conf.example`. Static assets are collected into the image at build time;
uploaded GIFs live in the `/data` volume and can be served straight from disk by
the proxy for better performance.

## Deploying to production with Docker

### Get the image

Every push to `main` builds a multi-arch (`amd64` + `arm64`) image and pushes it
to Docker Hub via the `Build and push Docker image` workflow. Pull it instead of
building locally:

```bash
docker pull tioherko/gifgallery:latest
```

(Replace `<your-dockerhub-username>` with the account configured in the
`DOCKERHUB_USERNAME` repository variable. If you'd rather build on the server,
`docker build -t gifgallery .` from a checkout works too.)

### docker compose

The recommended way to run it in production is Docker Compose, with an nginx
container terminating TLS in front of the app. Create a `docker-compose.yml`:

```yaml
services:
  app:
    image: tioherko/gifgallery:latest
    restart: unless-stopped
    environment:
      DJANGO_SECRET_KEY: "change-me-to-a-long-random-string"
      DJANGO_ALLOWED_HOSTS: "gifs.example.com"
      DJANGO_CSRF_TRUSTED_ORIGINS: "https://gifs.example.com"
    volumes:
      - data:/data # SQLite DB + uploaded GIFs
      - static:/app/gif/staticfiles # collected static assets (admin CSS, etc.)
    expose:
      - "8000"

  nginx:
    image: nginx:stable
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - static:/srv/static:ro # same volume the app populates
      - data:/srv/data:ro # to serve /media/ straight from disk
      - /etc/letsencrypt:/etc/letsencrypt:ro
    depends_on:
      - app

volumes:
  data:
  static:
```

Notes:

- `DJANGO_SECRET_KEY` **must** be set to a long random value in production. Generate
  one with `openssl rand -base64 48`.
- The `static` named volume is populated from the image the first time it's
  mounted, so nginx and the app share the same files. After upgrading the image,
  refresh it with
  `docker compose run --rm app python gif/manage.py collectstatic --noinput`.
- The `data` volume holds everything worth backing up (see below).

### Reverse proxy config

Point the proxy at the `app` container over TCP (port 8000) instead of the unix
socket in `nginx.conf.example`. A minimal `nginx.conf` for the Compose setup
above:

```nginx
server {
    listen 80;
    server_name gifs.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name gifs.example.com;

    ssl_certificate     /etc/letsencrypt/live/gifs.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/gifs.example.com/privkey.pem;

    client_max_body_size 50m;   # allow reasonably large GIF uploads

    # Static assets (mainly the Django admin) — served from the shared volume.
    location /static/ {
        alias /srv/static/;
        expires 30d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    # Uploaded GIFs on disk (the app also serves these via /gif/<id>/).
    location /media/ {
        alias /srv/data/media/;
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    location / {
        proxy_pass http://app:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

The main UI loads Tailwind/DaisyUI from a CDN, so it renders fine even without
the `/static/` mapping — that block exists mostly so the `/admin/` panel is
styled. If you'd rather ship a single fully self-contained container (no shared
static volume, no nginx `/static/` block), add
[WhiteNoise](https://whitenoise.readthedocs.io/) so the app serves its own static
files — ask and I can wire it in.

### First run

Start it, then create your account (there is no signup page):

```bash
docker compose up -d
docker compose exec app python gif/manage.py createsuperuser
```

Migrations run automatically on every startup, so an empty `data` volume is
initialized on first boot.

### Upgrades

```bash
docker compose pull
docker compose up -d      # runs pending migrations on startup
```

### Backups

Everything stateful lives in the `data` volume (`db.sqlite3` + `media/`). Back it
up by archiving the volume:

```bash
docker run --rm -v gif_data:/data -v "$PWD":/backup alpine \
  tar czf /backup/gif-backup.tar.gz -C /data .
```

(Adjust `gif_data` to match your Compose project's volume name — check
`docker volume ls`.)

### TLS / Cloudflare

TLS can be terminated at nginx (as above, e.g. with Let's Encrypt certs) or at a
proxy in front of it. A free Cloudflare account works well for proxying and
caching — if you use it, keep `DJANGO_CSRF_TRUSTED_ORIGINS` set to your public
`https://` origin.
