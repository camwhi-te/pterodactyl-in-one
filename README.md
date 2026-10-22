# Pterodactyl Panel: all-in-one image

One container running Pterodactyl Panel plus MariaDB, Redis, NGINX, PHP-FPM, the queue worker and the scheduler (supervisord).

## Quick start

```bash
docker compose up -d --build
```

Open http://localhost:8080 and log in with the `ADMIN_*` credentials from `docker-compose.yml`. Change them first.
Without `ADMIN_*`, create a user with:

```bash
docker exec -it pterodactyl php artisan p:user:make
```

## Persistence

Everything lives in the `/data` volume: `mysql/`, `redis/`, `storage/` and `.env` (which holds the generated `APP_KEY` and DB password).
**Back up `/data/.env`. Losing `APP_KEY` makes encrypted data unrecoverable.**

## Configuration (env vars, applied on every start)

| Variable | Purpose |
|---|---|
| `SERVER_IP`, `SERVER_PORT` | Public IP and port assigned by the platform (aliases `PUBLIC_IP`, `PUBLIC_PORT`). `APP_URL` is built as `http://IP:PORT` (port omitted if 80). If `SERVER_IP` is missing, the container detects its public IP via ipify/ifconfig.me/icanhazip. |
| `APP_URL` | Explicit public URL; overrides the IP/port auto-detection |
| `LISTEN_PORT` | Port NGINX listens on inside the container (default `80`). Set it equal to `SERVER_PORT` if your platform maps the same port inside and out |
| `APP_TIMEZONE` | e.g. `Europe/Berlin` |
| `TRUSTED_PROXIES` | Set (e.g. `*`) when behind a TLS-terminating proxy |
| `MAIL_*` | SMTP settings |
| `ADMIN_EMAIL`, `ADMIN_PASSWORD`, `ADMIN_USERNAME`, `ADMIN_FIRST_NAME`, `ADMIN_LAST_NAME` | First-run admin, created only if there are no users |

## Upgrading

Rebuild with a new `PANEL_VERSION` (or `latest`) and recreate the container. Migrations run on startup and data in `/data` is kept.

## Notes

- NGINX serves plain HTTP on port 80. Terminate TLS with a reverse proxy (Caddy, Traefik, nginx) and set `APP_URL` to the `https://` address and `TRUSTED_PROXIES`.
- **Wings is not included.** It needs direct access to the host's Docker daemon, so run it on your game-server nodes.
- MariaDB and Redis listen on 127.0.0.1 inside the container only.
