#!/bin/sh
# Add a "Run on falconhosting.co.uk" credit under the copyright line in the
# admin footer. Idempotent; safe to run after every panel (re)install.
F=/var/www/pterodactyl/resources/views/layouts/admin.blade.php

if [ ! -f "$F" ]; then
    echo "[patch-panel] WARNING: $F not found, footer credit not added"
    exit 0
fi

grep -q 'falconhosting.co.uk' "$F" && exit 0

sed -i 's|\(Pterodactyl Software</a>\.\)|\1<br />Run on <a href="https://falconhosting.co.uk" target="_blank" rel="noopener">falconhosting.co.uk</a>|' "$F"

if grep -q 'falconhosting.co.uk' "$F"; then
    echo "[patch-panel] Footer credit added"
else
    echo "[patch-panel] WARNING: copyright line not found in admin layout, footer credit not added"
fi
