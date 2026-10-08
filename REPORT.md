# Лаба 1 - Nginx

## Цель

Настроить nginx как точку входа перед сервисом из Лабы 0 (FastAPI + PostgreSQL).
Обеспечить отказоустойчивость: сайт должен работать, даже если половина бэкендов упала.

## Что сделано

- HTTP (80) → HTTPS (443) через 301, самоподписанный сертификат.
- Фронтенд отдаётся статикой из `/var/www/coud-labs/frontend`.
- `/api/` проксируется на upstream из двух бэкендов (round-robin).
- `/docs` отдаётся из отдельной папки через `alias`.
- Второй виртуальный хост `second.project` на том же сервере.
- `limit_req` на `/api` - 1 req/s на IP, ответ 429.
- Кастомные страницы 404 и 50x.
- `/admin` закрыт Basic Auth (htpasswd).
- Отказоустойчивость: при падении одного бэкенда nginx уводит трафик на живой.

## Стек

- FastAPI + SQLAlchemy + asyncpg + PostgreSQL
- Uvicorn (ASGI-сервер)
- Nginx 1.28

## Как запускать

### PostgreSQL

```bash
sudo systemctl start postgresql
```

### Бэкенды (в двух отдельных окнах)

```bash
cd ~/coud-labs/backend
source .venv/bin/activate
INSTANCE_ID=backend-1 uvicorn app.main:app --host 127.0.0.1 --port 8080
```

```bash
cd ~/coud-labs/backend
source .venv/bin/activate
INSTANCE_ID=backend-2 uvicorn app.main:app --host 127.0.0.1 --port 8081
```

### Nginx

```bash
sudo systemctl start nginx
```

### Проверки

```bash
cd ~/coud-labs
./check.sh
```

## Конфиг nginx

Основной конфиг: `nginx/coud-labs.conf`.

В `/etc/nginx/nginx.conf` выставлено `worker_processes 1;` для наглядной
проверки round-robin (иначе 12 воркеров ведут собственные очереди,
и один curl-сеанс всегда попадает в один апстрим).

## Проверки (`check.sh`)

Вывод - в файле `check_output.txt`.

Все проверки прошли:

1. HTTP → HTTPS: **301** на `https://local.project/`.
2. Балансировка `/api`: чередование `backend-1` и `backend-2`.
3. `/admin` без пароля: **401**.
4. `/admin` с паролем: **404** (auth пройдена, эндпоинта нет - норма).
5. `/docs`: кастомный HTML из отдельной папки (alias).
6. Кастомная 404: `<h1>404 - страница не найдена (кастомная)</h1>`.
7. Второй хост `second.project`: свой HTML, не пересекается с `local`.
8. Rate limit: `200 200 200 200 200 200 429 429 ...`.
9. Отказоустойчивость: убиваем backend-2, сайт продолжает отдавать `backend-1`.

## Демонстрация отказоустойчивости

1. Оба бэкенда живы - чередование через nginx:

```
{"status":"ok","instance":"backend-1"}
{"status":"ok","instance":"backend-2"}
{"status":"ok","instance":"backend-1"}
{"status":"ok","instance":"backend-2"}
```

2. Убиваем backend-2:

```bash
pkill -f "port 8081"
```

3. Сайт продолжает отвечать через живой backend-1:

```
{"status":"ok","instance":"backend-1"}
{"status":"ok","instance":"backend-1"}
{"status":"ok","instance":"backend-1"}
```

Это главный результат лабы: **сайт пережил падение половины бэкендов**.

## Сложности и решения

- **Nginx не балансировал** - из-за `worker_processes auto` (12 воркеров).
  Round-robin считается отдельно в каждом воркере, поэтому один curl-сеанс
  всегда попадал на один и тот же апстрим. Решение: `worker_processes 1;`.
- **`limit_req` возвращал 503 вместо 429** - по умолчанию nginx использует
  503. Добавили `limit_req_status 429;`.
- **Кастомная 404 не срабатывала** - `try_files ... /index.html` перехватывал
  любой путь. Заменили на `=404`.

## Скриншоты

См. папку `screenshots/`.
