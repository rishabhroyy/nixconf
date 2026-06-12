#!/bin/ash
set -eu

kernel=/app/app/Http/Kernel.php
middleware=/app/app/Http/Middleware/AuthentikSso.php

test -r "$kernel"
test -r "$middleware"

if [ "$(grep -c 'AuthentikSso::class' "$kernel")" -eq 0 ]; then
  sed -i '/^[[:space:]]*StartSession::class,$/a\            \\Pterodactyl\\Http\\Middleware\\AuthentikSso::class,' "$kernel"
fi

count="$(grep -c 'AuthentikSso::class' "$kernel")"
if [ "$count" -ne 1 ]; then
  echo "Expected AuthentikSso middleware exactly once in $kernel; found $count" >&2
  exit 1
fi

php artisan optimize:clear
exec supervisord -n -c /etc/supervisord.conf
