#!/bin/bash
set -euo pipefail

PROJECT_DIR="/etc/telemt-docker"
LOG_FILE="/root/telemt-update.log"
MAX_LOG_LINES=1000

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root." >&2
    exit 1
fi

if command -v docker-compose >/dev/null; then
    COMPOSE_CMD="docker-compose"
elif docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
else
    echo "❌ Docker Compose not found" >&2
    exit 1
fi

get_image_id() {
    docker inspect --format='{{.Id}}' "whn0thacked/telemt-docker:latest" 2>/dev/null | sed 's/sha256://'
}

log_single() {
    local msg="$1"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$ts - $msg" >&2
    {
        echo "$ts"
        echo "$msg"
        echo "---"
        echo
    } >> "$LOG_FILE"
}

if ! docker info >/dev/null 2>&1; then
    log_single "❌ Docker daemon is not running"
    exit 1
fi

cd "$PROJECT_DIR" || {
    log_single "❌ Failed to change directory to $PROJECT_DIR"
    exit 1
}

OLD_ID=$(get_image_id)

# Pull тихо
if ! $COMPOSE_CMD pull --quiet >/dev/null 2>&1; then
    log_single "❌ Pull failed"
    exit 2
fi

NEW_ID=$(get_image_id)

# Если старого образа не было (первая установка) — просто поднимаем контейнер без лога
if [ -z "$OLD_ID" ]; then
    $COMPOSE_CMD up -d --remove-orphans >/dev/null 2>&1 || {
        log_single "❌ Container start failed"
        exit 3
    }
    docker image prune -f &>/dev/null || true
    exit 0
fi

# Если ID не изменился — ничего не делаем
if [ "$OLD_ID" = "$NEW_ID" ]; then
    docker image prune -f &>/dev/null || true
    exit 0
fi

# --- Обновление: пишем в лог и консоль ---
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
echo "$TIMESTAMP - 🔄 New version found! Restarting container..." >&2
{
    echo "$TIMESTAMP"
    echo "🔄 New version found! Restarting container..."
} >> "$LOG_FILE"

if $COMPOSE_CMD up -d --remove-orphans >/dev/null 2>&1; then
    echo "$TIMESTAMP - ✅ Telemt successfully updated and restarted" >&2
    echo "✅ Telemt successfully updated and restarted" >> "$LOG_FILE"
    echo "---" >> "$LOG_FILE"
    echo >> "$LOG_FILE"
    docker image prune -f &>/dev/null || true
else
    echo "$TIMESTAMP - ❌ Restart failed" >&2
    echo "❌ Restart failed" >> "$LOG_FILE"
    echo "---" >> "$LOG_FILE"
    echo >> "$LOG_FILE"
    exit 3
fi

# Обрезка лога
if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt "$MAX_LOG_LINES" ]; then
    tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "$LOG_FILE.tmp"
    mv "$LOG_FILE.tmp" "$LOG_FILE"
fi