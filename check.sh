#!/bin/bash
# check.sh - проверки лабы 1 (nginx)
# Запускать из ~/coud-labs. Требует запущенный nginx и два бэкенда.

HOST="local.project"
SECOND="second.project"
ADMIN_USER="admin"
ADMIN_PASS="admin123"

CURL="curl -k -s"


echo "Лаба 1 - проверки nginx"

echo "1. HTTP -> HTTPS редирект"
curl -s -o /dev/null -w "Код: %{http_code} | Location: %{redirect_url}\n" http://$HOST/

echo ""
echo " 2. Балансировка /api"
for i in 1 2 3 4 5 6; do
  $CURL https://$HOST/api/health
  echo ""
done

echo "3. /admin без пароля"
curl -k -s -o /dev/null -w "Код: %{http_code}\n" https://$HOST/admin/


echo " 4. /admin с паролем"
curl -k -s -o /dev/null -w "Код: %{http_code}\n" -u $ADMIN_USER:$ADMIN_PASS https://$HOST/admin/


echo "5. /docs"
$CURL https://$HOST/docs/ | head -2


echo "6. Кастомная 404 "
$CURL https://$HOST/такой-страницы-нет

echo ""
echo "7. Второй виртуальный хост second.project"
$CURL https://$SECOND/

echo ""
echo "=== 8. Чужой контент не отдаётся ==="
$CURL https://$HOST/ | grep -qi "второй проект" && echo "ПРОБЛЕМА: local отдаёт second" || echo "OK: контент не пересекается"

echo ""
echo "Ждём 7 секунд, чтобы rate limit сбросился"
sleep 7
echo "9. Rate limit "
for i in {1..15}; do
  curl -k -s -o /dev/null -w "%{http_code} " https://$HOST/api/health
done
echo ""

echo ""
echo "10. Отказоустойчивость "
echo " Останови один из backend и нажми Enter"
read

echo "Запросы после падения одного backend :"
for i in 1 2 3 4 5 6; do
  $CURL https://$HOST/api/health
  echo ""
done

echo ""
echo "Проверки завершены"
