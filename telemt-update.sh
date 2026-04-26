#!/bin/bash
# ============================================================
#  telemt-update.sh v2 — Universal MTProto Proxy Updater
#
#  Pulls latest Docker image and recreates container.
#  Works with both docker-compose and docker compose.
# ============================================================
set -euo pipefail

INSTALL_DIR="/etc/telemt-docker"
LOG="/root/telemt-update.log"
IMAGE="whn0thacked/telemt-docker:latest"

if [ ! -d "$INSTALL_DIR" ] || [ ! -f "$INSTALL_DIR/docker-compose.yml" ]; then
    echo "ERROR: Telemt not found at $INSTALL_DIR"
    exit 1
fi

cd "$INSTALL_DIR"

# Detect compose command
if command -v docker-compose >/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    COMPOSE_CMD="docker compose"
fi

# Log
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

log "Checking for updates..."

OLD_ID=$(docker inspect --format='{{.Id}}' "$IMAGE" 2>/dev/null || echo "")

 $COMPOSE_CMD pull -q 2>/dev/null

NEW_ID=$(docker inspect --format='{{.Id}}' "$IMAGE" 2>/dev/null || echo "")

if [ "$OLD_ID" != "$NEW_ID" ] && [ -n "$NEW_ID" ]; then
    log "New image found. Recreating container..."
    $COMPOSE_CMD up -d --force-recreate --remove-orphans 2>/dev/null
    docker image prune -f >/dev/null 2>&1 || true
    
    # Verify
    sleep 2
    if docker ps --filter "name=telemt" --format '{{.Status}}' | grep -q "Up"; then
        log "Updated successfully. Container is running."
    else
        log "ERROR: Container not running after update. Check: docker ps -a"
        exit 1
    fi
else
    log "No updates available. Image is current."
fi