# Лаба 2, докер

Сделал вторую лабу на сервисе из лабы 0 (FastAPI + PostgreSQL + одна страница фронта).
Код приложения не трогал, он просто теперь собирается в образы и поднимается через compose.

Репозиторий: `https://github.com/FoXeNe/devops-labs/tree/lab2/lab2`, ветка `lab2`.

## Что где лежит

```
lab2/
  bad/Dockerfile.backend     плохой образ бэкенда
  good/Dockerfile.backend    хороший образ бэкенда
  good/Dockerfile.frontend   фронт на nginx
  good/nginx.conf            конфиг nginx внутри фронт-контейнера
  good/entrypoint.sh         точка входа бэкенда
  docker-compose.yml         основной стек
  docker-compose.bad.yml     тот же стек на плохом образе, для сравнения
  .env.example               переменные для compose
  frontend/index.html        копия фронта, пути к api относительные
  scripts/                   проверки и замер сборки
  docs/                      сюда сохраняются выводы скриптов
```

`.dockerignore` лежит в корне репозитория, потому что образы собираются из корня.

Запуск:

```
cp lab2/.env.example lab2/.env
docker compose --env-file lab2/.env -f lab2/docker-compose.yml up -d --build
```

Фронт на http://localhost:8080, api напрямую на http://localhost:8000/api/items.

## Плохие практики и что с ними стало

В плохом докерфайле специально собрал типичные ошибки, в хорошем их исправил. Вот по пунктам:

| Плохая практика | Чем плоха | Как исправил |
|---|---|---|
| `FROM python:latest`, версия базового образа не зафиксирована | завтра под тем же докерфайлом соберется другой питон и другие пакеты, сборка перестанет повторяться | `FROM python:3.11.9-slim-bookworm`, точный тег. Еще надежнее было бы пиновать по digest `@sha256:...` |
| `ENV DATABASE_URL=...` с паролем от базы прямо в образе | пароль видно в `docker history` и `docker inspect`, он уезжает в registry вместе с образом, а поменять его можно только пересборкой | в образе только дефолт для локального запуска, реальные значения приходят из `environment` в compose. Пароль лежит в `lab2/.env`, а он в `.gitignore` |
| нет multi-stage, в рантайме остаются `build-essential`, `gcc`, `git`, `curl`, `vim`, `postgresql-client` и кеш pip | образ раздувается в разы, внутри лежат компиляторы и утилиты, которые приложению не нужны | сделал два стейджа. Зависимости и сборка asyncpg идут в builder, в финальный образ копируется только готовый `/opt/venv` на slim-базе. Плюс `PIP_NO_CACHE_DIR=1` |
| `COPY . .` стоит до `pip install -r backend/requirements.txt` | правка одной строки кода меняет слой с копированием, за ним инвалидируется установка зависимостей, и пакеты ставятся заново | сначала копируется и ставится только `backend/requirements.txt`, код копируется после отдельным слоем. Правка кода пересобирает только слой с исходниками |
| в контекст сборки попадает все: `.git`, `.venv`, `.pgdata`, `docs`, `*.md` | лишние сотни мегабайт контекста, плюс внутрь образа утекает `.env` и история git | добавил [.dockerignore](../.dockerignore), там `.git`, `.venv`, `.pgdata`, `.env`, чужие лабы и мусор от IDE |
| нет `HEALTHCHECK` | compose не понимает, живой сервис или нет, и `depends_on` не может дождаться готовности | хелсчек дергает реальный `/api/health`, у фронта `/healthz` в nginx |
| `USER` не задан, все работает от root | если в приложении найдут дыру, процесс внутри контейнера будет с uid 0 | завел пользователя `app` (uid 10001), файлы копируются через `COPY --chown=app:app`, дальше `USER app` |
| лишние пакеты в рантайме (`vim`, `git`, `postgresql-client`, `curl`) | размер и лишние CVE, которые потом ловит Trivy в лабе 3 | в рантайме только venv с зависимостями и код приложения |

Еще по мелочи в хорошем варианте:

- [entrypoint.sh](good/entrypoint.sh) с `exec "$@"`, чтобы uvicorn стал pid 1 и нормально ловил
  `SIGTERM` при `docker stop`, и чтобы падал сразу, если не задан `DATABASE_URL`;
- `PYTHONDONTWRITEBYTECODE=1`, чтобы внутри образа не появлялись `__pycache__`;
- чистка `/var/lib/apt/lists/*` в том же слое, где ставились пакеты.

Про зависимости отдельно: базовый образ зафиксирован, а `backend/requirements.txt` из лабы 0
написан диапазонами (`fastapi>=0.115,<1.0`), поэтому версии пакетов между сборками все еще могут
поменяться. Правильно было бы собрать lock-файл и ставить по нему с хешами, но этот
requirements.txt общий с лабой 0, а ее запуск без докера завязан на него. Оставил как есть,
для лабы 3 со сканом Trivy это первое, что стоит доделать.

## Стек поднимается и работает

```
NAME            IMAGE                  STATUS                    PORTS
lab2-backend    notes-backend:good     Up 3 minutes (healthy)    0.0.0.0:8000->8000/tcp
lab2-db         postgres:16.4-alpine   Up 3 minutes (healthy)    5432/tcp
lab2-frontend   notes-frontend:good    Up 15 seconds (healthy)   0.0.0.0:8080->80/tcp
```

<!-- сюда скриншот docker compose ps -->

Три контейнера в статусе healthy, у фронта 8080->80, у бэкенда 8000->8000, а у базы проброса
портов нет вообще.

Первая сборка заняла минуты три, дальше подъем занимает секунды. Одна ошибка тут была: фронт
сначала уходил в Restarting, в логах nginx было `invalid variable name`. Причина в конфиге,
я заэкранировал `$host` как `$$host`, а nginx такого имени переменной не знает. Поменял обратно
на `$host`, после этого все поднялось.

## Размер образов

```
notes-backend:bad    1.87GB
notes-backend:good   331MB
notes-frontend:good  73.1MB
```

Хороший образ бэкенда получился в 5.7 раза меньше плохого. Разница за счет того, что в плохом
остаются `build-essential`, `git`, `vim`, `postgresql-client`, полный python вместо slim, кеш pip
и весь контекст из `COPY . .`. В хорошем только venv с зависимостями на slim-базе.

<!-- сюда скриншот docker images с размерами -->

Команда для проверки:

```
docker images --format "{{.Repository}}:{{.Tag}}  {{.Size}}" | findstr notes
```

## Контейнер работает не от root

```
$ docker exec lab2-backend whoami
app
$ docker exec lab2-backend id -u
10001
```

<!-- сюда скриншот whoami и id -->

В плохом варианте `whoami` вернул бы root, там `USER` не задан.

## Кеш слоев

Замер делает [scripts/measure-build-time.sh](scripts/measure-build-time.sh) (и
[.ps1](scripts/measure-build-time.ps1) для windows): собирает оба образа, потом дописывает одну
строку в `backend/app/main.py` и собирает заново.

```
образ                  без правки    после правки одной строки
notes-backend:bad         1.31 с          16.88 с
notes-backend:good        0.73 с           1.94 с
```

После правки одной строки плохой образ собирается 17 секунд, хороший меньше двух, разница
почти в 9 раз. Без правок оба пересобираются меньше секунды, потому что все слои в кеше.
Цифры немного плавают от прогона к прогону, но соотношение всегда одинаковое.

<!-- сюда скриншот с результатом замера -->

Почему так. В плохом докерфайле порядок такой:

```
COPY . .                                        # любая правка кода меняет этот слой
RUN pip install -r backend/requirements.txt     # слой сломан, пакеты ставятся заново
```

Правка кода меняет папку `backend/`, значит слой с копированием пересобирается, а следующий за ним
`pip install` инвалидируется вместе с ним. В хорошем докерфайле сначала копируется только
`requirements.txt` и ставится отдельным слоем, а код идет после:

```
COPY backend/requirements.txt /tmp/requirements.txt   # меняется редко, слой в кеше
RUN pip install -r /tmp/requirements.txt
COPY --chown=app:app backend/app ./app                # меняется только этот слой
```

Поэтому при правке кода зависимости берутся из кеша и пересобирается только слой с исходниками.

## Compose: стек, том и изоляция

Все поднимается одной командой:

```
docker compose --env-file lab2/.env -f lab2/docker-compose.yml up -d --build
```

`db`, `backend` и `frontend` стартуют вместе. Фронт ходит в бэкенд по имени сервиса, бэкенд в базу
по имени `db` через `DATABASE_URL`. Никаких localhost между контейнерами, только dns compose.

### Данные в именованном томе

Том `lab2-pgdata` примонтирован в `/var/lib/postgresql/data`. Проверял так: добавлял записи,
потом сносил контейнер бэкенда и поднимал заново, записи оставались на месте.

```bash
docker rm -f lab2-backend
docker compose --env-file lab2/.env -f lab2/docker-compose.yml up -d backend

docker exec lab2-db psql -U notes -d notesdb -c "select count(*) from notes;"
docker volume inspect lab2-pgdata --format "{{.Name}} -> {{.Mountpoint}}"
```

<!-- сюда скриншот: записи на месте после удаления контейнера -->

Том переживает и `docker rm` контейнера, и `docker compose down`. Удаляется только вместе с
`docker compose down -v`.

### Фронт не имеет доступа к базе

В compose две сети: `frontend-net` для фронта и бэкенда, и `backend-net` для бэкенда и базы.
База подключена только к `backend-net`, фронт только к `frontend-net`. Плюс у базы нет проброса
порта на хост, а `backend-net` объявлена `internal: true`, то есть наружу из нее выхода нет.

Проверка из фронт-контейнера:

```
$ docker exec lab2-frontend getent hosts db
(пусто, имя не резолвится, контейнер не в этой сети)
$ docker exec lab2-frontend nc -z -w 3 db 5432
nc: bad address 'db'
```

<!-- сюда скриншот: фронт не может достучаться до базы -->

В плохом compose все сервисы попадают в общую сеть, там фронт до базы дотягивается, и вдобавок
порт базы опубликован на хост.

## Хелсчеки, рестарт и лимиты

Это уже необязательная часть, но сделал заодно. В compose:

- у базы хелсчек `pg_isready`, интервал 5 секунд, 10 попыток;
- у бэкенда проверка `/api/health`, интервал 10 секунд;
- у фронта проверка `/healthz`, интервал 10 секунд;
- у всех трех `restart: unless-stopped`;
- `backend` стартует после `db` по условию `service_healthy`, `frontend` после `backend`.

Проверял так: гасил контейнер базы, docker поднимал его обратно по политике рестарта, сайт
продолжал отвечать.

```bash
docker kill lab2-db
docker ps -a --filter name=lab2-db            # Exited, потом снова Up
docker inspect -f '{{.RestartCount}}' lab2-db # счетчик перезапусков больше нуля
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/api/items
```

<!-- сюда скриншот, если делал эту часть -->

Лимиты в compose: у бэкенда `cpus: 1.0` и `memory: 512M`, у фронта `cpus: 0.5` и `memory: 128M`.

## Что проверено

| Требование | Как проверял | Результат |
|---|---|---|
| Плохой докерфайл, минимум три плохие практики | [bad/Dockerfile.backend](bad/Dockerfile.backend), 6 практик с комментариями | ок |
| Хороший докерфайл | [good/Dockerfile.backend](good/Dockerfile.backend) | ок |
| Multi-stage | стейджи builder и runtime | ок |
| Отдельный пользователь | `docker exec lab2-backend whoami` | app, uid 10001 |
| Зафиксированная версия базового образа | `python:3.11.9-slim-bookworm` | ок |
| `.dockerignore` | [.dockerignore](../.dockerignore) | ок |
| `HEALTHCHECK` | в докерфайлах и в compose | ок |
| Порядок слоев под кеш | 1.94 с против 16.88 с после правки строки | ок |
| Хороший образ меньше плохого | 331 МБ против 1.87 ГБ | ок |
| Три сервиса одной командой | `docker compose up` | ок |
| Данные в именованном томе | сносил контейнер, записи остались | ок |
| Фронт не имеет доступа к базе | `nc db 5432` из фронта | соединение не проходит |
| Скриншоты | папка `lab2/docs/` | добавлены |

Автопроверка всех пунктов, вывод складывается в `lab2/docs/verify-output.txt`:

```
bash lab2/scripts/verify.sh
powershell -ExecutionPolicy Bypass -File lab2/scripts/verify.ps1
```

<!-- сюда вывод verify с итогом "пройдено 27, провалено 0" -->
<!-- сюда скриншот фронта в браузере с добавленной записью -->
