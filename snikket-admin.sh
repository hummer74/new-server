#!/bin/bash
set -euo pipefail

cd /etc/snikket || { echo "Ошибка: /etc/snikket не найдена. Убедитесь, что Snikket установлен."; exit 1; }

echo "Создание приглашения администратора для Snikket..."
INVITE=$(docker compose exec snikket_server create-invite --admin --group default 2>&1 | grep -Eo 'https?://[^ ]+' | head -1)

if [ -n "$INVITE" ]; then
    echo "✅ Ссылка-приглашение для администратора:"
    echo "$INVITE"
    echo "$INVITE" > /root/snikket_url.txt
    echo "Ссылка сохранена в /root/snikket_url.txt"
else
    echo "⚠️ Не удалось получить ссылку. Проверьте, запущен ли контейнер snikket_server."
    echo "Выполните: docker compose exec snikket_server create-invite --admin --group default"
fi