#!/bin/bash
set -euo pipefail

# ===== Удаление Snikket и возврат системы в состояние до установки =====
# Оставляем: UFW (с правилами SSH, HTTP, HTTPS), fail2ban
# Удаляем: контейнеры, тома, конфигурацию, специфичные правила UFW, конфиги fail2ban для snikket
# Опционально: удаление Docker и связанных пакетов

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Проверка, что скрипт запущен от root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Этот скрипт должен запускаться от root (sudo).${NC}" >&2
   exit 1
fi

echo -e "${GREEN}=== Удаление Snikket ===${NC}"
echo "Скрипт удалит компоненты Snikket, но оставит:"
echo "  - UFW с правилами для SSH, HTTP, HTTPS"
echo "  - fail2ban (без конфигурации Snikket)"
echo "  - установленные пакеты curl, ufw, dnsutils (если не ответить 'y' на их удаление)"
echo

read -p "Продолжить удаление? (введите 'yes' для подтверждения): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Отмена."
    exit 0
fi

# 1. Определяем реальный порт SSH (аналогично install-скрипту)
SSH_PORT=$(sshd -T | grep -i "^port " | awk '{print $2}' | head -1)
if [ -z "$SSH_PORT" ]; then
    SSH_PORT=22
    echo -e "${YELLOW}SSH порт не найден, использую 22${NC}"
else
    echo "Обнаружен SSH порт: $SSH_PORT"
fi

# 2. Остановка и удаление контейнеров Snikket
if [ -d "/etc/snikket" ]; then
    echo "Останавливаем и удаляем контейнеры Snikket (включая тома)..."
    cd /etc/snikket
    docker compose down -v 2>/dev/null || echo -e "${YELLOW}Контейнеры не запущены или docker compose недоступен.${NC}"
    cd /
else
    echo -e "${YELLOW}Директория /etc/snikket не найдена, пропускаем.${NC}"
fi

# 3. Удаление конфигурационных файлов Snikket
if [ -d "/etc/snikket" ]; then
    echo "Удаляем /etc/snikket..."
    rm -rf /etc/snikket
else
    echo -e "${YELLOW}/etc/snikket уже отсутствует.${NC}"
fi

# 4. Удаление правил UFW (кроме SSH, HTTP, HTTPS)
echo "Удаление правил UFW, добавленных для Snikket..."

# Список портов/протоколов для удаления (из установочного скрипта)
PORTS_TO_REMOVE=(
    "5222/tcp"
    "5269/tcp"
    "5000/tcp"
    "3478/tcp"
    "3479/tcp"
    "5349/tcp"
    "5350/tcp"
    "3478/udp"
    "3479/udp"
    "5349/udp"
    "5350/udp"
    "49152:65535/udp"
)

for rule in "${PORTS_TO_REMOVE[@]}"; do
    if ufw status numbered 2>/dev/null | grep -q "$rule"; then
        echo "Удаляем правило $rule"
        ufw delete allow "$rule" 2>/dev/null || echo -e "${YELLOW}Не удалось удалить $rule (возможно, уже удалено)${NC}"
    else
        echo "Правило $rule не найдено, пропускаем"
    fi
done

echo "Правила SSH (порт $SSH_PORT), HTTP и HTTPS оставлены."

# 5. Удаление конфигурации fail2ban для snikket
echo "Удаление конфигурации fail2ban для snikket..."
if [ -f "/etc/fail2ban/filter.d/snikket-web.conf" ]; then
    rm -f /etc/fail2ban/filter.d/snikket-web.conf
    echo "Удалён фильтр /etc/fail2ban/filter.d/snikket-web.conf"
fi

if [ -f "/etc/fail2ban/jail.d/snikket.conf" ]; then
    rm -f /etc/fail2ban/jail.d/snikket.conf
    echo "Удалён jail /etc/fail2ban/jail.d/snikket.conf"
fi

# Перезапуск fail2ban для применения изменений
if systemctl is-active --quiet fail2ban; then
    echo "Перезапускаем fail2ban..."
    systemctl restart fail2ban
else
    echo -e "${YELLOW}fail2ban не активен, пропускаем перезапуск.${NC}"
fi

# 6. Удаление сохранённой ссылки-приглашения
if [ -f "/root/snikket_url.txt" ]; then
    rm -f /root/snikket_url.txt
    echo "Удалён /root/snikket_url.txt"
fi

# 7. Опциональное удаление Docker и связанных пакетов
echo -e "${YELLOW}Хотите удалить Docker и связанные пакеты (docker-ce, docker-ce-cli, containerd.io, docker-compose-plugin)?${NC}"
echo "Внимание: это может затронуть другие контейнеры, если они есть."
read -p "Удалить Docker? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Останавливаем все контейнеры и удаляем пакеты Docker..."
    # Останавливаем все запущенные контейнеры
    docker stop $(docker ps -q) 2>/dev/null || true
    # Удаляем все контейнеры, образы, тома (опционально)
    read -p "Удалить все образы, контейнеры и тома Docker? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        docker system prune -a --volumes -f
    fi
    # Удаляем пакеты
    apt remove -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    apt autoremove -y
    # Удаляем репозиторий Docker
    rm -f /etc/apt/sources.list.d/docker.list
    rm -f /usr/share/keyrings/docker-archive-keyring.gpg
    echo "Docker удалён."
else
    echo "Docker оставлен в системе."
fi

# 8. Опциональное удаление пакетов, установленных скриптом (curl, ufw, dnsutils)
echo
echo -e "${YELLOW}Пакеты curl, ufw, dnsutils были установлены скриптом установки.${NC}"
read -p "Удалить их? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    apt remove -y curl ufw dnsutils || echo -e "${YELLOW}Некоторые пакеты не были установлены или уже удалены.${NC}"
    apt autoremove -y
    echo "Пакеты удалены."
else
    echo "Пакеты оставлены."
fi

# 9. Очистка кэша APT (опционально)
read -p "Выполнить очистку кэша APT (apt clean)? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    apt clean
    echo "Кэш APT очищен."
fi

# 10. Завершение
echo -e "${GREEN}=== Удаление Snikket завершено ===${NC}"
echo "Система возвращена в состояние до установки Snikket (оставлены UFW с правилами SSH/HTTP/HTTPS и fail2ban)."
echo "Проверьте список правил UFW: ufw status numbered"
echo "Проверьте статус fail2ban: fail2ban-client status"

read -p "Перезагрузить сервер сейчас? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    reboot
fi