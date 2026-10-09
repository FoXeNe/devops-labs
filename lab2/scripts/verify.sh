#!/usr/bin/env bash
# проверка всех пунктов лабы 2. запускать из корня репозитория:
#   bash lab2/scripts/verify.sh
# вывод дублируется в lab2/docs/verify-output.txt
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

ENV_FILE="lab2/.env"
COMPOSE="docker compose --env-file $ENV_FILE -f lab2/docker-compose.yml"
OUT_DIR="lab2/docs"
OUT_FILE="$OUT_DIR/verify-output.txt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$OUT_DIR"
# вывод идет и на экран, и в файл
exec > >(tee "$OUT_FILE") 2>&1

PASS=0
FAIL=0
ok()   { echo "  [OK]   $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
step() { echo; echo "=== $* ==="; }

if ! command -v docker >/dev/null 2>&1; then
    echo "docker не найден в PATH, сначала поставь и запусти Docker Desktop"
    exit 2
fi
if [ ! -f "$ENV_FILE" ]; then
    echo "нет $ENV_FILE, копирую из lab2/.env.example"
    cp lab2/.env.example "$ENV_FILE"
fi
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
BACKEND_PORT="${BACKEND_PORT:-8000}"
FRONTEND_PORT="${FRONTEND_PORT:-8080}"

echo "проверка стека лабы 2"
echo "дата: $(date -Iseconds 2>/dev/null || date)"
echo "docker: $(docker --version)"
echo "compose: $(docker compose version 2>/dev/null | head -1 || echo '?')"

# --- 1. конфиг compose корректен --------------------------------------------
step "1. Валидация compose-файла"
if $COMPOSE config -q; then ok "docker-compose.yml валиден"; else bad "docker-compose.yml невалиден"; fi

# --- 2. поднимаем стек -------------------------------------------------------
step "2. docker compose up (три сервиса одной командой)"
$COMPOSE up -d --build
UP_RC=$?
[ $UP_RC -eq 0 ] && ok "up выполнен без ошибок" || bad "up вернул код $UP_RC"

sleep 5
RUNNING="$($COMPOSE ps --status running --services 2>/dev/null | tr -d '\r')"
echo "  запущены: $(echo "$RUNNING" | tr '\n' ' ')"
for svc in db backend frontend; do
    if echo "$RUNNING" | grep -qx "$svc"; then ok "сервис $svc запущен"; else bad "сервис $svc не запущен"; fi
done

step "2b. docker ps"
docker ps --filter "name=lab2" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | tee "$TMP/ps.txt"

# --- 3. все контейнеры должны быть healthy ----------------------------------
step "3. Healthcheck-статусы"
sleep 10
for c in lab2-db lab2-backend lab2-frontend; do
    st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || echo missing)"
    case "$st" in
        healthy) ok "$c: healthy" ;;
        none)    bad "$c: healthcheck не задан" ;;
        missing) bad "$c: контейнера нет" ;;
        *)       bad "$c: статус $st" ;;
    esac
done

# --- 4. фронт отвечает, api ходит через nginx -------------------------------
step "4. Фронт и api"
front_code="$(curl -s -o "$TMP/index.html" -w '%{http_code}' "http://localhost:${FRONTEND_PORT}/" || echo 000)"
[ "$front_code" = "200" ] && ok "GET / -> 200" || bad "GET / -> $front_code"
grep -q "Notes" "$TMP/index.html" && ok "в html есть разметка фронта" || bad "html не похож на наш фронт"

api_code="$(curl -s -o "$TMP/items_before.json" -w '%{http_code}' "http://localhost:${FRONTEND_PORT}/api/items" || echo 000)"
[ "$api_code" = "200" ] && ok "GET /api/items через nginx -> 200" || bad "GET /api/items через nginx -> $api_code"

direct_code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${BACKEND_PORT}/api/health" || echo 000)"
[ "$direct_code" = "200" ] && ok "GET :${BACKEND_PORT}/api/health напрямую -> 200" || bad "backend health -> $direct_code"

# --- 5. запись реально ложится в базу ---------------------------------------
step "5. Запись в базу и чтение из нее"
MARK="verify-$(date +%s)"
post_code="$(curl -s -o "$TMP/post.json" -w '%{http_code}' -X POST "http://localhost:${FRONTEND_PORT}/api/items" \
    -H 'Content-Type: application/json' -d "{\"text\":\"$MARK\"}" || echo 000)"
[ "$post_code" = "201" ] && ok "POST /api/items -> 201" || bad "POST /api/items -> $post_code"
grep -q "$MARK" "$TMP/post.json" && ok "сервер вернул созданную запись" || bad "в ответе нет текста записи"

curl -s "http://localhost:${FRONTEND_PORT}/api/items" | grep -q "$MARK" \
    && ok "запись видна в GET /api/items" || bad "запись не видна в списке"

db_rows="$(docker exec lab2-db psql -U "${POSTGRES_USER:-notes}" -d "${POSTGRES_DB:-notesdb}" -tAc \
    "select count(*) from notes where text = '$MARK';" 2>/dev/null | tr -d '[:space:]')"
[ "$db_rows" = "1" ] && ok "строка есть в postgres, select вернул 1" || bad "в postgres строк не найдено, вернулось '$db_rows'"

# --- 6. данные переживают удаление контейнера -------------------------------
step "6. Именованный том: удаляем контейнер и поднимаем заново"
docker rm -f lab2-backend >/dev/null 2>&1 && ok "контейнер backend удален" || bad "не удалось удалить контейнер"
$COMPOSE up -d backend >/dev/null 2>&1 || true
for i in $(seq 1 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${FRONTEND_PORT}/api/items" || echo 000)"
    [ "$code" = "200" ] && break
    sleep 2
done
curl -s "http://localhost:${FRONTEND_PORT}/api/items" | grep -q "$MARK" \
    && ok "после пересоздания запись '$MARK' на месте" \
    || bad "после пересоздания запись пропала"

echo "  том: $(docker volume inspect lab2-pgdata --format '{{.Name}} -> {{.Mountpoint}}' 2>/dev/null || echo 'не найден')"

# --- 7. контейнер работает не от root ---------------------------------------
step "7. Пользователь внутри контейнера"
who="$(docker exec lab2-backend whoami 2>/dev/null | tr -d '\r')"
if [ -n "$who" ] && [ "$who" != "root" ]; then ok "docker exec lab2-backend whoami -> $who"; else bad "whoami -> '$who', ожидался не root"; fi
uid="$(docker exec lab2-backend id -u 2>/dev/null | tr -d '\r')"
[ "$uid" = "10001" ] && ok "uid внутри контейнера 10001" || bad "uid внутри контейнера '$uid'"

# --- 8. фронт не имеет доступа к базе ---------------------------------------
step "8. Сетевая изоляция"
resolve="$(docker exec lab2-frontend getent hosts db 2>&1 || true)"
if echo "$resolve" | grep -qi "db"; then bad "фронт резолвит имя db: $resolve"; else ok "фронт не резолвит имя db, ответ: $(echo "$resolve" | head -1)"; fi

conn="$(docker exec lab2-frontend sh -c 'nc -z -w 3 db 5432 && echo CONNECTED || echo FAILED' 2>&1 || echo "nc недоступен")"
echo "  попытка соединения фронта с db:5432 -> $conn"
case "$conn" in
    FAILED*|*not found*|*nc недоступен*) ok "соединение фронта с базой невозможно" ;;
    CONNECTED*) bad "фронт подключился к базе, изоляции нет" ;;
    *) bad "непонятный результат: $conn" ;;
esac

nets_front="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' lab2-frontend | tr -d '\r')"
nets_db="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' lab2-db | tr -d '\r')"
echo "  сети frontend: $nets_front"
echo "  сети db:       $nets_db"
echo "$nets_front" | grep -q "backend-net" && bad "фронт подключен к backend-net" || ok "фронт не в сети базы"
echo "$nets_db" | grep -q "frontend-net" && bad "база подключена к frontend-net" || ok "база не в сети фронта"

if ss -ltn 2>/dev/null | grep -q ':5432 '; then bad "порт 5432 слушается на хосте, база опубликована"; else ok "порт 5432 на хост не опубликован"; fi

# --- 9. размеры образов ------------------------------------------------------
step "9. Размеры образов"
docker images --format '{{.Repository}}:{{.Tag}}|{{.Size}}' | grep -E 'notes-(backend|frontend)' | tee "$TMP/sizes.txt" || echo "  образы не найдены"
bad_size="$(docker image inspect notes-backend:bad --format '{{.Size}}' 2>/dev/null || echo '')"
good_size="$(docker image inspect notes-backend:good --format '{{.Size}}' 2>/dev/null || echo '')"
if [ -n "$bad_size" ] && [ -n "$good_size" ]; then
    echo "  плохой backend:  $((bad_size/1024/1024)) МБ"
    echo "  хороший backend: $((good_size/1024/1024)) МБ"
    [ "$good_size" -lt "$bad_size" ] && ok "хороший образ меньше плохого" || bad "хороший образ не меньше плохого"
else
    echo "  оба образа не собраны, их собирает lab2/scripts/measure-build-time.sh"
fi

# --- 10. итоговое состояние --------------------------------------------------
step "10. Итоговое состояние стека"
$COMPOSE ps

echo
echo "итого: пройдено $PASS, провалено $FAIL"
echo "вывод сохранен в $OUT_FILE"
[ "$FAIL" -eq 0 ] || exit 1
