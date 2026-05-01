#!/usr/bin/env bash
# setup-tailscale-exit-node-socks5.sh
# Универсальный скрипт: установка Tailscale, настройка Exit Node и SOCKS5-прокси (порт 20160)

set -euo pipefail

echo "=== Настройка сервера как Tailscale Exit Node + SOCKS5 Proxy ==="

# --- Шаг 1: Установка Tailscale ---
echo ">>> Установка Tailscale..."
if ! command -v tailscale &> /dev/null; then
    bash -c "$(curl -L https://raw.githubusercontent.com/hummer74/new-server/main/tailscale-insall.sh)"
    sleep 2
else
    echo "Tailscale уже установлен."
fi

# --- Шаг 2: Включение IP-форвардинга (необходим для Exit Node) ---
echo ">>> Активация IP-форвардинга..."

if ! grep -q "^net.ipv4.ip_forward\s*=\s*1" /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.conf > /dev/null
    echo "Добавлен параметр: net.ipv4.ip_forward = 1"
else
    echo "Параметр net.ipv4.ip_forward уже активен."
fi

if ! grep -q "^net.ipv6.conf.all.forwarding\s*=\s*1" /etc/sysctl.conf; then
    echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.conf > /dev/null
    echo "Добавлен параметр: net.ipv6.conf.all.forwarding = 1"
else
    echo "Параметр net.ipv6.conf.all.forwarding уже активен."
fi

sudo sysctl -p > /dev/null

# --- Шаг 3: Первый вход в Tailscale и объявление узла ---
echo ">>> Подключение к Tailscale и объявление Exit Node..."
sudo tailscale up --advertise-exit-node

echo ">>> Ожидание применения сетевых настроек..."
sleep 3

# --- Шаг 4: Настройка SOCKS5-прокси через systemd override ---
SOCKS_PORT="20160"
TAILSCALED_BIN="/usr/sbin/tailscaled"
STATE_FILE="/var/lib/tailscale/tailscaled.state"
SOCKET_FILE="/run/tailscale/tailscaled.sock"
PORT="41641"   # стандартный порт из вашего /etc/default/tailscaled

echo ">>> Создание systemd override для SOCKS5-прокси на порту $SOCKS_PORT..."

sudo mkdir -p /etc/systemd/system/tailscaled.service.d
sudo tee /etc/systemd/system/tailscaled.service.d/socks5.conf > /dev/null << EOF
[Service]
ExecStart=
ExecStart=${TAILSCALED_BIN} --state=${STATE_FILE} --socket=${SOCKET_FILE} --port=${PORT} --socks5-server=0.0.0.0:${SOCKS_PORT}
EOF

sudo systemctl daemon-reload
sudo systemctl restart tailscaled

# Проверка, что порт слушается
sleep 2
if ss -tlnp | grep -q ":${SOCKS_PORT}"; then
    echo "✅ SOCKS5-прокси успешно запущен на порту $SOCKS_PORT"
else
    echo "❌ Не удалось запустить SOCKS5-прокси, проверьте логи: journalctl -u tailscaled -n 20"
fi

# --- Шаг 5: Убедимся, что служба в автозапуске ---
sudo systemctl enable tailscaled &> /dev/null || true

echo ""
echo "=== Готово! ==="
echo "Сервер анонсирует себя как Exit Node."
echo "SOCKS5-прокси доступен на всех интерфейсах внутри Tailnet."
echo "IP-адрес сервера в сети Tailscale:"
tailscale ip -4 2>/dev/null || echo "  (уточните командой tailscale ip -4)"
echo ""
echo "⚠️  Не забудьте зайти в Admin Console и утвердить этот сервер как Exit Node:"
echo "    https://login.tailscale.com/admin/machines"
echo "    Найдите машину, откройте 'Edit route settings' и поставьте галочку 'Use as exit node'."
