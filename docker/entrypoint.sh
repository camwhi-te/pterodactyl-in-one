#!/bin/sh
set -eu

DATA=/data
APP=/var/www/pterodactyl
ENVF=$DATA/.env
SOCK=/run/mysqld/mysqld.sock
DB_NAME=panel
DB_USER=panel

log() { echo "[entrypoint] $*"; }

mkdir -p "$DATA/mysql" "$DATA/redis" "$DATA/storage" /run/mysqld /run/php

# ---- Persistent storage -----------------------------------------------------
if [ ! -d "$DATA/storage/framework" ]; then
    log "Initialising storage directory"
    cp -a /opt/storage-default/. "$DATA/storage/"
fi

# ---- .env (first run) -------------------------------------------------------
if [ ! -f "$ENVF" ]; then
    log "Generating .env"
    cat > "$ENVF" <<EOF
APP_ENV=production
APP_DEBUG=false
APP_KEY=base64:$(openssl rand -base64 32)
APP_THEME=pterodactyl
APP_TIMEZONE=UTC
APP_URL=http://localhost
APP_ENVIRONMENT_ONLY=false

LOG_CHANNEL=daily
LOG_DEPRECATIONS_CHANNEL=null
LOG_LEVEL=debug

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=$DB_NAME
DB_USERNAME=$DB_USER
DB_PASSWORD=$(openssl rand -hex 24)

REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379

CACHE_DRIVER=redis
QUEUE_CONNECTION=redis
SESSION_DRIVER=redis

HASHIDS_SALT=$(openssl rand -hex 10)
HASHIDS_LENGTH=8

MAIL_MAILER=smtp
MAIL_HOST=localhost
MAIL_PORT=25
MAIL_USERNAME=
MAIL_PASSWORD=
MAIL_ENCRYPTION=
MAIL_FROM_ADDRESS=no-reply@example.com
MAIL_FROM_NAME="Pterodactyl Panel"
EOF
fi

# Update or append KEY="value" in .env
setenv() {
    key=$1
    val=$2
    v=$(printf '%s' "$val" | sed 's/[\\"]/\\&/g')
    s=$(printf '%s' "$v" | sed 's/[&|\\]/\\&/g')
    if grep -q "^$key=" "$ENVF"; then
        sed -i "s|^$key=.*|$key=\"$s\"|" "$ENVF"
    else
        printf '%s="%s"\n' "$key" "$v" >> "$ENVF"
    fi
}

# ---- Public URL / listen port ----------------------------------------------
# The platform assigns one public IP and port. Pass them as SERVER_IP and
# SERVER_PORT (PUBLIC_IP / PUBLIC_PORT also accepted). APP_URL wins if set.
PUB_IP=${SERVER_IP:-${PUBLIC_IP:-}}
PUB_PORT=${SERVER_PORT:-${PUBLIC_PORT:-}}
LISTEN_PORT=${LISTEN_PORT:-80}

if [ -z "${APP_URL:-}" ]; then
    if [ -z "$PUB_IP" ]; then
        for svc in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
            PUB_IP=$(curl -fsS -m 4 "$svc" 2>/dev/null | tr -d '[:space:]') && [ -n "$PUB_IP" ] && break
            PUB_IP=
        done
        [ -n "$PUB_IP" ] && log "Detected public IP $PUB_IP (set SERVER_IP to override)"
    fi
    if [ -n "$PUB_IP" ]; then
        case "$PUB_IP" in *:*) PUB_IP="[$PUB_IP]" ;; esac   # IPv6
        if [ -z "$PUB_PORT" ] || [ "$PUB_PORT" = "80" ]; then
            APP_URL="http://$PUB_IP"
        else
            APP_URL="http://$PUB_IP:$PUB_PORT"
        fi
        export APP_URL
        log "APP_URL set to $APP_URL"
    else
        log "WARNING: no SERVER_IP/APP_URL and IP detection failed; keeping existing APP_URL"
    fi
fi

# NGINX listen port (change if the platform maps the same port inside)
sed "s/__LISTEN_PORT__/$LISTEN_PORT/" /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

# Environment variables override the stored configuration on every start
for k in APP_URL APP_TIMEZONE TRUSTED_PROXIES MAIL_MAILER MAIL_HOST MAIL_PORT \
         MAIL_USERNAME MAIL_PASSWORD MAIL_ENCRYPTION MAIL_FROM_ADDRESS MAIL_FROM_NAME; do
    eval "v=\${$k:-}"
    [ -n "$v" ] && setenv "$k" "$v"
done

DB_PASS=$(grep '^DB_PASSWORD=' "$ENVF" | cut -d= -f2- | tr -d '"')

# ---- Permissions ------------------------------------------------------------
if [ ! -d "$DATA/mysql/mysql" ]; then
    log "Initialising MariaDB data directory"
    chown -R mysql:mysql "$DATA/mysql"
    mariadb-install-db --user=mysql --datadir="$DATA/mysql" --skip-test-db >/dev/null
fi
chown -R mysql:mysql "$DATA/mysql" /run/mysqld
chown -R redis:redis "$DATA/redis"
chown -R nginx:nginx "$DATA/storage" "$APP/bootstrap/cache"
chown nginx:nginx "$ENVF"
chmod 640 "$ENVF"
chown nginx:nginx /run/php

# ---- Bootstrap: migrations, seeding, admin user ----------------------------
log "Starting temporary MariaDB for setup"
su-exec mysql mariadbd --datadir="$DATA/mysql" --bind-address=127.0.0.1 --socket="$SOCK" &
DBPID=$!

i=0
until mariadb-admin --socket="$SOCK" ping >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -gt 60 ]; then log "MariaDB failed to start"; exit 1; fi
    sleep 1
done

mariadb --socket="$SOCK" <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;
CREATE USER IF NOT EXISTS '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
ALTER USER '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'127.0.0.1' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

# Redis isn't running yet, so use file/sync drivers for these commands
artisan() {
    su-exec nginx env CACHE_DRIVER=file SESSION_DRIVER=file QUEUE_CONNECTION=sync \
        php "$APP/artisan" "$@"
}

cd "$APP"
if [ ! -f "$DATA/.seeded" ]; then
    log "Running first-time migrations and seeding"
    artisan migrate --seed --force
    touch "$DATA/.seeded"
else
    artisan migrate --force
fi
artisan config:clear >/dev/null 2>&1 || true
artisan view:clear >/dev/null 2>&1 || true

if [ -n "${ADMIN_EMAIL:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
    USERS=$(mariadb --socket="$SOCK" -N -e "SELECT COUNT(*) FROM \`$DB_NAME\`.users")
    if [ "$USERS" = "0" ]; then
        log "Creating admin user $ADMIN_EMAIL"
        artisan p:user:make \
            --email="$ADMIN_EMAIL" \
            --username="${ADMIN_USERNAME:-admin}" \
            --name-first="${ADMIN_FIRST_NAME:-Admin}" \
            --name-last="${ADMIN_LAST_NAME:-User}" \
            --password="$ADMIN_PASSWORD" \
            --admin=1
    fi
elif [ ! -f "$DATA/.admin-hint" ]; then
    touch "$DATA/.admin-hint"
    log "No admin created. Run: docker exec -it <container> php artisan p:user:make"
fi

mariadb-admin --socket="$SOCK" shutdown
wait "$DBPID" || true

log "Setup complete, starting services"
exec "$@"
