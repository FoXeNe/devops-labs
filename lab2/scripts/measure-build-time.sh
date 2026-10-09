#!/usr/bin/env bash
# замер времени пересборки после правки одной строки кода.
# собирает плохой и хороший образы и сравнивает, как работает кеш слоев.
# запускать из корня репозитория:
#   bash lab2/scripts/measure-build-time.sh
# вывод дублируется в lab2/docs/build-timing.txt
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR="lab2/docs"
OUT_FILE="$OUT_DIR/build-timing.txt"
mkdir -p "$OUT_DIR"
exec > >(tee "$OUT_FILE") 2>&1

if ! docker info >/dev/null 2>&1; then
    echo "docker недоступен, запусти Docker Desktop"
    exit 2
fi

now() { date +%s.%N 2>/dev/null || echo "$SECONDS"; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", b - a }'; }

build() { # build <tag> <dockerfile>
    local tag="$1" df="$2"
    local t0 t1
    t0="$(now)"
    docker build -q --progress=plain -f "$df" -t "$tag" . >/dev/null 2>&1
    local rc=$?
    t1="$(now)"
    if [ $rc -ne 0 ]; then
        echo "  сборка упала: $tag ($df)"
        return 1
    fi
    echo "$(elapsed "$t0" "$t1")"
}

echo "время пересборки после правки одной строки кода"
echo "дата: $(date -Iseconds 2>/dev/null || date)"
echo "docker: $(docker --version)"
echo

echo "=== Шаг 1. Холодная сборка обоих образов, --no-cache ==="
docker build --no-cache -f lab2/bad/Dockerfile.backend  -t notes-backend:bad  . >/dev/null 2>&1 \
    && echo "  notes-backend:bad собран" || echo "  notes-backend:bad НЕ собран"
docker build --no-cache -f lab2/good/Dockerfile.backend -t notes-backend:good . >/dev/null 2>&1 \
    && echo "  notes-backend:good собран" || echo "  notes-backend:good НЕ собран"
echo

echo "=== Шаг 2. Пересборка без правок, все должно взяться из кеша ==="
warm_bad="$(build notes-backend:bad lab2/bad/Dockerfile.backend)"
warm_good="$(build notes-backend:good lab2/good/Dockerfile.backend)"
echo "  плохой:  ${warm_bad} с"
echo "  хороший: ${warm_good} с"
echo

echo "=== Шаг 3. Меняем одну строку кода и пересобираем ==="
APP_FILE="backend/app/main.py"
cp "$APP_FILE" "$APP_FILE.lab2bak"
restore() { [ -f "$APP_FILE.lab2bak" ] && mv -f "$APP_FILE.lab2bak" "$APP_FILE"; }
trap restore EXIT
# дописываем комментарий в конец файла, для кеша это обычная правка кода
printf '\n# lab2: метка для замера кеша слоев %s\n' "$(date +%s)" >> "$APP_FILE"
echo "  изменен файл: $APP_FILE"
echo

rebuild_bad="$(build notes-backend:bad lab2/bad/Dockerfile.backend)"
rebuild_good="$(build notes-backend:good lab2/good/Dockerfile.backend)"
echo "  плохой:  ${rebuild_bad} с"
echo "  хороший: ${rebuild_good} с"
restore
trap - EXIT
echo "  файл кода вернули как был"
echo

echo "=== Итог ==="
printf '  %-28s %-12s %-12s\n' "образ" "без правки" "после правки"
printf '  %-28s %-12s %-12s\n' "notes-backend:bad"  "${warm_bad} с"  "${rebuild_bad} с"
printf '  %-28s %-12s %-12s\n' "notes-backend:good" "${warm_good} с" "${rebuild_good} с"
echo
if [ -n "$rebuild_bad" ] && [ -n "$rebuild_good" ]; then
    echo "  разница: $(awk -v a="$rebuild_bad" -v b="$rebuild_good" 'BEGIN { printf "%.2f", a - b }') с"
    echo "  хороший быстрее в $(awk -v a="$rebuild_bad" -v b="$rebuild_good" 'BEGIN { if (b+0 == 0) print "n/a"; else printf "%.1f", a / b }') раз"
fi
echo
echo "  почему так:"
echo "   - в плохом Dockerfile сначала COPY . . и только потом pip install, поэтому правка"
echo "     кода сбрасывает слой и зависимости ставятся заново;"
echo "   - в хорошем сначала копируется requirements.txt и ставится отдельным слоем, а код"
echo "     копируется после, поэтому пересобирается только слой с исходниками."
echo
echo "  размеры образов:"
docker images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' | grep -E 'notes-backend' || true
echo "вывод сохранен в $OUT_FILE"
