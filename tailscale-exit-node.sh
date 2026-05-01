#!/usr/bin/env bash
# setup-tailscale-exit-node.sh
# Установка Tailscale и настройка сервера как Exit Node

set -euo pipefail

echo "=== Настройка сервера как Tailscale Exit Node ==="

# --- Шаг 1: Установка Tailscale ---
echo ">>> Установка Tailscale..."
if ! command -v tailscale &> /dev/null; then
    bash -c "$(curl -L https://raw.githubusercontent.com/hummer74/new-server/main/tailscale-insall.sh)"
    sleep 2
else
    echo "Tailscale уже установлен."
fi

# --- Шаг 2: Включение IP-форвардинга ---
echo ">>> Активация IP-форвардинга..."

if ! grep -q "^net.ipv4.ip_forward\s*=\s*1" /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.conf > /dev/null
    echo "Добавлен параметр: net.ipv4.ip_forward = 1"
else
    echo "Параметр net.ipv4.ip_forward уже активен."
fi

if ! grep -q "^net.ipv6.conf.all.forwarding\s*=\s*1" /etc/sysctl.conf; then
    echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.conf > /dev/null
    echo "Добавлен параметр: net.ipv6.conf.all.forwarding = 1 (может не поддерживаться ядром)"
fi

sudo sysctl -p > /dev/null 2>&1 || echo "   (Некоторые параметры не применились – это нормально, если IPv6 отключён)"

# --- Шаг 3: Подключение и объявление Exit Node ---
echo ">>> Подключение к Tailscale и объявление Exit Node..."
sudo tailscale up --advertise-exit-node

echo ">>> Ожидание применения сетевых настроек..."
sleep 3

# --- Шаг 4: Автозапуск и статус ---
echo ">>> Включение автозапуска tailscaled..."
sudo systemctl enable tailscaled &> /dev/null || true

echo ">>> Текущий статус службы:"
sudo systemctl status tailscaled --no-pager

echo ""
echo "=== Готово! ==="
echo "Сервер анонсирует себя как Exit Node."
echo "IP-адрес сервера в сети Tailscale:"
tailscale ip -4 2>/dev/null || echo "  (уточните командой tailscale ip -4)"
echo ""
echo "⚠️  Не забудьте зайти в Admin Console и утвердить этот сервер как Exit Node:"
echo "    https://login.tailscale.com/admin/machines"
echo "    Найдите машину, откройте 'Edit route settings' и поставьте галочку 'Use as exit node'."
