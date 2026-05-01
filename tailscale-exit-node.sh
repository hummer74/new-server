#!/usr/bin/env bash
# setup-tailscale-exit-node.sh
# Установка Tailscale, настройка Exit Node и автофиксация исходящего IP

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

# --- Шаг 4: Определение исходящего IP сервера ---
echo ">>> Определяем исходящий IP-адрес сервера..."
# Пробуем получить IP через ifconfig.me, если curl доступен
if command -v curl &> /dev/null; then
    OUTBOUND_IP=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || true)
fi

# Если не получилось через curl, пытаемся через ip route
if [ -z "${OUTBOUND_IP:-}" ]; then
    OUTBOUND_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)
fi

if [ -z "${OUTBOUND_IP:-}" ]; then
    echo "❌ Не удалось определить исходящий IP. Пропускаем настройку SNAT."
    OUTBOUND_IP=""
else
    echo "   Исходящий IP сервера: $OUTBOUND_IP"
fi

# --- Шаг 5: Настройка SNAT для трафика Exit Node ---
if [ -n "$OUTBOUND_IP" ]; then
    echo ">>> Настройка правила iptables для Exit Node на IP $OUTBOUND_IP..."

    # Проверяем, существует ли уже цепочка ts-postrouting (должна быть после tailscale up)
    if sudo iptables -t nat -L ts-postrouting &>/dev/null; then
        # Удаляем старое правило MASQUERADE с маркером, если есть
        sudo iptables -t nat -D ts-postrouting -m mark --mark 0x40000/0xff0000 -j MASQUERADE 2>/dev/null || true
        # Добавляем SNAT на нужный IP
        sudo iptables -t nat -A ts-postrouting -m mark --mark 0x40000/0xff0000 -j SNAT --to-source "$OUTBOUND_IP"
        echo "   Правило добавлено немедленно."
    else
        echo "   Цепочка ts-postrouting пока недоступна, правило будет применено при старте."
    fi

    # --- Шаг 6: Создание systemd-сервиса для автоприменения после перезагрузок ---
    echo ">>> Создание systemd-сервиса fix-exit-node-ip..."
    sudo tee /etc/systemd/system/fix-exit-node-ip.service > /dev/null << EOF
[Unit]
Description=Fix Exit Node SNAT IP to $OUTBOUND_IP
After=tailscaled.service
Requires=tailscaled.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'iptables -t nat -D ts-postrouting -m mark --mark 0x40000/0xff0000 -j MASQUERADE 2>/dev/null; iptables -t nat -A ts-postrouting -m mark --mark 0x40000/0xff0000 -j SNAT --to-source $OUTBOUND_IP'

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable fix-exit-node-ip.service
    echo "   Сервис fix-exit-node-ip.service создан и включен в автозагрузку."
fi

# --- Шаг 7: Убедимся, что tailscaled в автозапуске ---
echo ">>> Включение автозапуска tailscaled..."
sudo systemctl enable tailscaled &> /dev/null || true

echo ""
echo "=== Готово! ==="
echo "Сервер анонсирует себя как Exit Node."
if [ -n "$OUTBOUND_IP" ]; then
    echo "Трафик Exit Node будет выходить с IP: $OUTBOUND_IP"
else
    echo "Трафик Exit Node будет использовать стандартный IP (MASQUERADE)."
fi
echo "IP-адрес сервера в сети Tailscale:"
tailscale ip -4 2>/dev/null || echo "  (уточните командой tailscale ip -4)"
echo ""
echo "⚠️  Не забудьте зайти в Admin Console и утвердить этот сервер как Exit Node:"
echo "    https://login.tailscale.com/admin/machines"
echo "    Найдите машину, откройте 'Edit route settings' и поставьте галочку 'Use as exit node'."
