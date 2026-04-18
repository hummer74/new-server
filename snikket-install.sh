#!/bin/bash
set -euo pipefail

# ===== НАСТРОЙТЕ ЭТИ ПЕРЕМЕННЫЕ =====
DOMAIN="matrix74.ignorelist.com"          # Ваш основной домен
ADMIN_EMAIL="hummer74rus@gmail.com"       # Email для Let's Encrypt (реальный)
# =====================================

# Проверка, что переменные изменены
if [[ "$DOMAIN" == "snikk.example.com" || "$ADMIN_EMAIL" == "admin@example.com" ]]; then
    echo "ОШИБКА: Измените DOMAIN и ADMIN_EMAIL в начале скрипта!" >&2
    exit 1
fi

echo "=== Установка Snikket ==="

# 1. Определяем реальный порт SSH
SSH_PORT=$(sshd -T | grep -i "^port " | awk '{print $2}' | head -1)
if [ -z "$SSH_PORT" ]; then
    SSH_PORT=22
    echo "SSH порт не найден, использую 22"
else
    echo "Обнаружен SSH порт: $SSH_PORT"
fi

# 2. Обновление списка пакетов и установка зависимостей
apt update && apt upgrade -y
apt install -y curl ufw dnsutils

# 3. Проверка DNS
echo "Проверка DNS записей..."
SERVER_IP=$(curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    echo "Не удалось определить внешний IP сервера. Пропускаем проверку DNS."
else
    check_dns() {
        local sub=$1
        local fqdn="${sub:+$sub.}$DOMAIN"
        local resolved_ip
        resolved_ip=$(dig +short "$fqdn" | tail -n1)
        if [ -z "$resolved_ip" ]; then
            echo "Предупреждение: не удаётся разрешить $fqdn"
        elif [ "$resolved_ip" != "$SERVER_IP" ]; then
            echo "Предупреждение: $fqdn указывает на $resolved_ip, а не на $SERVER_IP"
            echo "Сертификаты Let's Encrypt могут не выдаться до исправления DNS."
            read -p "Продолжить всё равно? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
        else
            echo "OK: $fqdn -> $resolved_ip"
        fi
    }
    check_dns ""
    check_dns "groups"
    check_dns "share"
fi

# 4. Установка Docker и Docker Compose plugin
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update && apt upgrade -y
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker

# 5. Настройка UFW (с учётом двух SSH-портов)
ufw allow 22/tcp comment "SSH (default)"
if [ "$SSH_PORT" != "22" ]; then
    ufw allow "$SSH_PORT/tcp" comment "SSH (alt)"
fi
ufw allow 80/tcp comment "HTTP"
ufw allow 443/tcp comment "HTTPS"
ufw allow 5222/tcp comment "XMPP Client"
ufw allow 5269/tcp comment "XMPP Federation"
ufw allow 5000/tcp comment "File Proxy"
ufw allow 3478/tcp comment "STUN TCP"
ufw allow 3479/tcp comment "STUN TCP alt"
ufw allow 5349/tcp comment "TURN TCP"
ufw allow 5350/tcp comment "TURN TCP alt"
ufw allow 3478/udp comment "STUN UDP"
ufw allow 3479/udp comment "STUN UDP alt"
ufw allow 5349/udp comment "TURN UDP"
ufw allow 5350/udp comment "TURN UDP alt"
ufw allow 49152:65535/udp comment "TURN media"

echo "y" | ufw enable
ufw status verbose

# 6. Подготовка конфигурации Snikket
mkdir -p /etc/snikket
cd /etc/snikket

curl -o docker-compose.yml https://snikket.org/service/resources/docker-compose.yml

# Удаляем устаревшую директиву version (чтобы избежать предупреждений)
sed -i '/^version:/d' docker-compose.yml

# Создаём docker-compose.override.yml для добавления томов
cat > docker-compose.override.yml <<EOF
services:
  snikket_proxy:
    volumes:
      - snikket_acme_challenges:/var/www/.well-known/acme-challenge

volumes:
  # Том уже определён в основном docker-compose.yml, но мы его упоминаем для ясности
  snikket_acme_challenges:
EOF

cat > snikket.conf <<EOF
SNIKKET_DOMAIN=$DOMAIN
SNIKKET_ADMIN_EMAIL=$ADMIN_EMAIL
# SNIKKET_TWEAK_TURNSERVER_PORT_RANGE=60000-61023   # раскомментируйте при необходимости
EOF

echo "Конфигурация создана в /etc/snikket/snikket.conf"

# 7. Запуск Snikket
docker compose up -d

# 8. Ожидание запуска контейнеров (до 30 секунд)
echo "Ожидание запуска контейнеров (до 30 секунд)..."
for i in {1..30}; do
    if docker compose ps | grep -q "Up"; then
        break
    fi
    sleep 1
done

if ! docker compose ps | grep -q "Up"; then
    echo "Ошибка: контейнеры не запустились. Статус:"
    docker compose ps
    echo "Логи:"
    docker compose logs --tail=50
    exit 1
fi

# 9. Определение имени сервиса XMPP и создание приглашения с диагностикой
echo "Определяем имя сервиса XMPP-сервера..."
XMPP_SERVICE=$(docker compose config --services | grep -E '^(snikket|snikket_server)$' | head -1)
if [ -z "$XMPP_SERVICE" ]; then
    echo "Ошибка: не удалось найти сервис XMPP-сервера в docker-compose.yml"
    echo "Доступные сервисы:"
    docker compose config --services
    exit 1
fi
echo "Обнаружен сервис: $XMPP_SERVICE"

echo "Ожидание готовности сервиса и создание приглашения администратора..."
MAX_WAIT=600  # 10 минут
INTERVAL=10
elapsed=0
attempt=0
INVITE=""

while [ $elapsed -lt $MAX_WAIT ]; do
    attempt=$((attempt + 1))
    # Пробуем создать приглашение через docker compose exec
    OUTPUT=$(docker compose exec -T $XMPP_SERVICE create-invite --admin --group default 2>&1) || true
    INVITE=$(echo "$OUTPUT" | grep -Eo 'https?://[^ ]+' | head -1)
    if [ -n "$INVITE" ]; then
        echo "✅ Ссылка-приглашение для администратора получена:"
        echo "$INVITE"
        echo "$INVITE" > /root/snikket_url.txt
        echo "Ссылка сохранена в /root/snikket_url.txt"
        break
    else
        echo "Попытка $attempt: сервис ещё не готов"
        # Каждые 5 попыток выводим диагностику
        if [ $((attempt % 5)) -eq 0 ]; then
            echo "--- Диагностика ---"
            echo "Статус всех контейнеров:"
            docker compose ps
            echo "Последние 10 строк лога $XMPP_SERVICE:"
            docker compose logs --tail=10 $XMPP_SERVICE
            echo "--------------------"
        fi
    fi
    sleep $INTERVAL
    elapsed=$((elapsed + INTERVAL))
done

if [ -z "$INVITE" ]; then
    echo "⚠️ Не удалось создать приглашение автоматически за 10 минут."
    echo "Возможная причина — сбой в контейнере $XMPP_SERVICE. Проверьте его логи:"
    echo "  docker compose logs $XMPP_SERVICE"
    echo "После исправления выполните команду вручную:"
    echo "  docker compose exec $XMPP_SERVICE create-invite --admin --group default"
fi

# 10. Настройка fail2ban (с учётом возможной предустановленной конфигурации)
echo "=== Настройка fail2ban для защиты SSH и веб-интерфейса Snikket ==="

# Устанавливаем fail2ban, если он ещё не установлен
if ! command -v fail2ban-server &> /dev/null; then
    apt install -y fail2ban
    echo "fail2ban установлен."
else
    echo "fail2ban уже установлен. Обновляем конфигурацию."
fi

# Создаём фильтр для snikket-web
cat > /etc/fail2ban/filter.d/snikket-web.conf <<'EOF'
[Definition]
failregex = ^.*Failed password attempt for user .* from <HOST>$
            ^.*Authentication failed for user .* from <HOST>$
ignoreregex =
EOF

# Определяем путь к логам контейнера snikket (используем XMPP_SERVICE)
SNIKKET_CONTAINER_ID=$(docker compose -f /etc/snikket/docker-compose.yml ps -q $XMPP_SERVICE 2>/dev/null || true)
if [ -z "$SNIKKET_CONTAINER_ID" ]; then
    echo "Предупреждение: не удалось определить ID контейнера $XMPP_SERVICE. Путь к логам будет указан приблизительно."
    SNIKKET_LOG_PATH="/var/lib/docker/containers/*snikket*/*.log"
else
    SNIKKET_LOG_PATH="/var/lib/docker/containers/$SNIKKET_CONTAINER_ID/*.log"
fi

# Список доверенных IP (ваши адреса + локальные)
TRUSTED_IPS="176.56.1.165 95.78.162.177 45.86.86.195 46.29.239.23 45.38.143.206 176.125.243.194 194.58.68.23"

# Создаём отдельный файл конфигурации для наших джейлов в /etc/fail2ban/jail.d/
cat > /etc/fail2ban/jail.d/snikket.conf <<EOF
[sshd]
enabled   = true
port      = 22,24940
filter    = sshd
logpath   = /var/log/auth.log
maxretry  = 3
findtime  = 2h
bantime   = 7d
ignoreip  = $TRUSTED_IPS

[snikket-web]
enabled   = true
port      = http,https
filter    = snikket-web
logpath   = $SNIKKET_LOG_PATH
maxretry  = 5
findtime  = 2h
bantime   = 1d
ignoreip  = $TRUSTED_IPS
EOF

echo "Конфигурация fail2ban добавлена в /etc/fail2ban/jail.d/snikket.conf"
echo "Примечание: если у вас уже были настройки для sshd в других файлах, они могут быть переопределены нашей секцией [sshd]."
echo "Проверьте итоговую конфигурацию командой: fail2ban-client -d"

# Перезапускаем fail2ban для применения изменений
systemctl restart fail2ban
systemctl enable fail2ban

echo "fail2ban перезапущен и добавлен в автозагрузку."

# 11. Проверка логов
echo "Последние логи Snikket:"
docker compose logs --tail=20

# 12. Информация о сертификатах
echo "=== Проверка получения сертификатов ==="
echo "Сертификаты Let's Encrypt будут получены автоматически в течение нескольких минут."
echo "Если этого не происходит, выполните вручную внутри контейнера snikket_certs:"
echo "  docker compose exec snikket_certs certbot certonly --webroot -w /var/www/.well-known/acme-challenge --non-interactive --agree-tos --email $ADMIN_EMAIL -d $DOMAIN -d groups.$DOMAIN -d share.$DOMAIN"
echo "После получения сертификатов перезапустите контейнер snikket_server:"
echo "  docker compose restart snikket_server"

echo "=== Установка завершена ==="
echo "Убедитесь, что DNS-записи для домена $DOMAIN и поддоменов groups.$DOMAIN, share.$DOMAIN указывают на IP этого сервера."