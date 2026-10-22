FROM alpine:3.20

ARG PANEL_VERSION=latest

RUN apk add --no-cache \
        nginx mariadb mariadb-client redis supervisor \
        curl tar openssl su-exec tzdata ca-certificates \
        php83 php83-fpm php83-bcmath php83-ctype php83-curl php83-dom \
        php83-fileinfo php83-gd php83-iconv php83-intl php83-mbstring \
        php83-mysqlnd php83-openssl php83-pcntl php83-pdo php83-pdo_mysql \
        php83-phar php83-posix php83-redis php83-session php83-simplexml \
        php83-sodium php83-tokenizer php83-xml php83-xmlwriter php83-zip \
    && ln -sf /usr/bin/php83 /usr/bin/php

ENV APP_DIR=/var/www/pterodactyl
WORKDIR /var/www/pterodactyl

# Download the panel release (ships with vendor/ already built)
RUN if [ "$PANEL_VERSION" = "latest" ]; then \
        URL="https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz"; \
    else \
        URL="https://github.com/pterodactyl/panel/releases/download/${PANEL_VERSION}/panel.tar.gz"; \
    fi \
    && curl -fsSL "$URL" | tar -xz -C "$APP_DIR" \
    && chmod -R 755 storage bootstrap/cache \
    # storage and .env live on the persistent volume
    && mv storage /opt/storage-default \
    && ln -s /data/storage storage \
    && ln -s /data/.env .env \
    && chown -R nginx:nginx "$APP_DIR" /opt/storage-default

COPY docker/nginx.conf.template /etc/nginx/nginx.conf.template
COPY docker/php-fpm.conf /etc/php83/php-fpm.d/www.conf
COPY docker/php.ini /etc/php83/conf.d/99-pterodactyl.ini
COPY docker/supervisord.conf /etc/supervisord.conf
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
    && echo '* * * * * cd /var/www/pterodactyl && php artisan schedule:run >> /dev/null 2>&1' > /etc/crontabs/nginx

VOLUME /data
EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD curl -fs -o /dev/null "http://127.0.0.1:${LISTEN_PORT:-80}/auth/login" || exit 1

ENTRYPOINT ["/entrypoint.sh"]
CMD ["supervisord", "-n", "-c", "/etc/supervisord.conf"]
