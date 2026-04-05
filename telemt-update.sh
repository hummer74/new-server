#!/bin/bash
set -euo pipefail

# ==============================================
# Telemt update script (whn0thacked/telemt-docker:latest)
# For installation in /etc/telemt-docker
# Logs: /root/telemt-update.log
# ==============================================

PROJECT_DIR="/etc/telemt-docker"
LOG_FILE="/root/telemt-update.log"
MAX_LOG_LINES=600

# Determine docker-compose command
if command -v docker-compose >/dev/null; then
    COMPOSE_CMD="docker-compose"
elif docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
else
    echo "❌ Docker Compose not found" | tee -a "$LOG_FILE"
    exit 1
fi

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Check Docker
if ! docker info >/dev/null 2>&1; then
    log "❌ Docker daemon is not running"
    exit 1
fi

cd "$PROJECT_DIR" || {
    log "❌ Failed to change directory to $PROJECT_DIR"
    exit 1
}

# Save current image ID
OLD_IMAGE_ID=$(docker images --format "{{.ID}}" whn0thacked/telemt-docker:latest 2>/dev/null || echo "")

log "🔍 Checking for updates of whn0thacked/telemt-docker:latest..."

# Download new image
if $COMPOSE_CMD pull --quiet; then
    log "📥 Image downloaded"
else
    log "❌ Pull failed"
    exit 2
fi

# Get new image ID
NEW_IMAGE_ID=$(docker images --format "{{.ID}}" whn0thacked/telemt-docker:latest 2>/dev/null || echo "")

# If image hasn't changed
if [ -n "$OLD_IMAGE_ID" ] && [ "$OLD_IMAGE_ID" == "$NEW_IMAGE_ID" ]; then
    log "🟢 No updates, restart not needed"
    # Clean up old images (optional)
    docker image prune -f &>/dev/null || true
    exit 0
fi

# Image updated — recreate container
log "🔄 New version found! Restarting container..."
if $COMPOSE_CMD up -d --remove-orphans; then
    log "✅ Telemt successfully updated and restarted"
    # Remove old image
    docker image prune -f &>/dev/null || true
else
    log "❌ Restart failed"
    exit 3
fi

# Trim log file
if [ -f "$LOG_FILE" ] && [ $(wc -l < "$LOG_FILE") -gt $MAX_LOG_LINES ]; then
    tail -n $MAX_LOG_LINES "$LOG_FILE" > "$LOG_FILE.tmp"
    mv "$LOG_FILE.tmp" "$LOG_FILE"
    log "✂️ Log trimmed to $MAX_LOG_LINES lines"
fi

