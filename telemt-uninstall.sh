#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    error "Please run as root (sudo)"
    exit 1
fi

# Determine Docker Compose command (Same logic as install script)
if command -v docker-compose >/dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
elif docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker compose"
else
    DOCKER_COMPOSE_CMD=""
    warn "Docker Compose not found. Manual cleanup will be attempted."
fi

INSTALL_DIR="/etc/telemt-docker"

if [ -d "$INSTALL_DIR" ]; then
    info "Found installation at $INSTALL_DIR. Starting cleanup..."

    # Remove UFW rule if it was created
    if [ -f "$INSTALL_DIR/ufw_port.txt" ]; then
        PORT=$(cat "$INSTALL_DIR/ufw_port.txt")
        if command -v ufw >/dev/null && ufw status | grep -q active; then
            info "Closing port $PORT in UFW..."
            ufw delete allow "$PORT/tcp" 2>/dev/null || true
        fi
        rm -f "$INSTALL_DIR/ufw_port.txt"
    fi

    # Stop and remove containers
    cd "$INSTALL_DIR"
    if [ -n "$DOCKER_COMPOSE_CMD" ]; then
        info "Stopping services with $DOCKER_COMPOSE_CMD..."
        $DOCKER_COMPOSE_CMD down --rmi local 2>/dev/null || true
    elif command -v docker >/dev/null; then
        warn "Using manual docker commands to stop container..."
        docker stop telemt 2>/dev/null || true
        docker rm telemt 2>/dev/null || true
    fi
    
    cd /
    info "Removing installation directory $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"
else
    warn "Installation directory $INSTALL_DIR not found. Skipping folder cleanup."
fi

# Remove secret link file
if [ -f /root/tg-proxy_secret.txt ]; then
    info "Removing secret file /root/tg-proxy_secret.txt..."
    rm -f /root/tg-proxy_secret.txt
fi

# Cleanup Docker resources if docker is present
if command -v docker >/dev/null; then
    info "Removing unused Docker data (images, containers, volumes)..."
    docker system prune --volumes -f
    docker image prune -a -f
else
    warn "Docker command not found, skipping Docker prune."
fi

echo ""
info "✅ Uninstall complete. System is clean."