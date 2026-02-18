#!/bin/bash

# Проверка, что скрипт запущен от root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)." >&2
    exit 1
fi

echo "Starting system update and cleanup..."

# Обновление списков пакетов и системы
apt clean -y
rm -rf /var/lib/apt/lists/*
apt update -y
apt full-upgrade -y
apt autoremove -y
apt autoclean -y
# Очистка конфигов удалённых пакетов
apt autoremove --purge -y

# Если всё прошло успешно
if [ $? -eq 0 ]; then
    echo "Update completed successfully. Rebooting in 15 seconds (Ctrl+C to cancel)..."
    sleep 15
    reboot now
else
    echo "Update failed. Reboot aborted." > ~/auto-update.log
    exit 2
fi
