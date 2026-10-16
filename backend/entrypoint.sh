#!/bin/sh
# точка входа бэкенда. exec нужен чтобы uvicorn стал pid 1 и нормально
# отрабатывал docker stop, а не умирал по таймауту
set -eu

if [ -z "${DATABASE_URL:-}" ]; then
    echo "entrypoint: DATABASE_URL не задан" >&2
    exit 1
fi

exec "$@"
