# Лаба 2, докер

Упаковываем сервис из лабы 0 в образы и поднимаем стек через docker compose.

## Что в папке

```
lab2/
  bad/Dockerfile.backend     # плохой образ, для сравнения
  good/Dockerfile.backend    # хороший образ
  good/Dockerfile.frontend   # статика фронта
  good/nginx.conf            # конфиг nginx внутри фронт-контейнера
  good/entrypoint.sh         # точка входа бэкенда
  docker-compose.yml         # основной стек: db + backend + frontend
  docker-compose.bad.yml     # тот же стек на плохом образе, для сравнения
  .env.example               # переменные для compose
  frontend/index.html        # копия фронта, пути к api относительные
  scripts/                   # проверки и замер времени сборки
  docs/                      # сюда сохраняются выводы скриптов и скриншоты
  REPORT.md                  # отчёт по лабе
```

`.dockerignore` лежит в корне репозитория, потому что образы собираются из корня.

Код приложения из лабы 0 не переписывал: в образы уезжает тот же `backend/app` и тот же
фронт, просто теперь они запускаются в контейнерах.

## Запуск

Нужен Docker Desktop (или docker engine с compose v2).

```
cd <корень репозитория>

# переменные окружения, там пароль к базе
cp lab2/.env.example lab2/.env

# собираем и поднимаем все три сервиса
docker compose --env-file lab2/.env -f lab2/docker-compose.yml up -d --build

# смотрим, что поднялось
docker compose --env-file lab2/.env -f lab2/docker-compose.yml ps
```

Дальше фронт на http://localhost:8080, api напрямую на http://localhost:8000/api/items,
схема на http://localhost:8000/docs. База на хост не опубликована, снаружи к ней не достучаться.

Остановить: `docker compose --env-file lab2/.env -f lab2/docker-compose.yml down`
Если добавить `-v`, вместе с контейнерами уедет том с заметками.

## Как проверить

```
# linux, macos или git bash
bash lab2/scripts/verify.sh

# windows
powershell -ExecutionPolicy Bypass -File lab2/scripts/verify.ps1
```

Скрипт сам поднимает стек и проверяет по пунктам: контейнеры живы, whoami не root,
запись ложится в базу и остается после пересоздания контейнера, фронт не видит базу,
хороший образ меньше плохого. Вывод сохраняется в `lab2/docs/verify-output.txt`.

Замер кеша слоев (пересобирает оба образа после правки одной строки кода):

```
bash lab2/scripts/measure-build-time.sh
powershell -ExecutionPolicy Bypass -File lab2/scripts/measure-build-time.ps1
```

Разбор плохого и хорошего вариантов по пунктам в [`REPORT.md`](REPORT.md).
