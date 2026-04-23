#!/bin/bash
set -euo pipefail

PROJECT_DIR="/etc/telemt-docker"
LOG_FILE="/root/telemt-update.log"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "Installation directory $PROJECT_DIR not found."
    exit 1
fi

cd "$PROJECT_DIR"

if command -v docker-compose >/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    COMPOSE_CMD="docker compose"
fi

OLD_ID=$(docker inspect --format='{{.Id}}' whn0thacked/telemt-docker:latest 2>/dev/null || echo "")

echo "$(date) - Checking for updates..." >> "$LOG_FILE"
$COMPOSE_CMD pull -q

NEW_ID=$(docker inspect --format='{{.Id}}' whn0thacked/telemt-docker:latest 2>/dev/null || echo "")

if [ "$OLD_ID" != "$NEW_ID" ]; then
    echo "$(date) - New version found. Updating..." >> "$LOG_FILE"
    $COMPOSE_CMD up -d --remove-orphans
    docker image prune -f >/dev/null
    echo "✅ Telemt updated."
else
    echo "No updates found."
fi