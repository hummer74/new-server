#!/bin/bash
# ============================================================
#  telemt-uninstall.sh v2 — Universal MTProto Proxy Remover
#
#  Stops container, removes Docker image, cleans UFW rules,
#  removes config directory and secret link.
#  Works with both docker-compose and docker compose.
# ============================================================
set -euo pipefail

INSTALL_DIR="/etc/telemt-docker"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root."
    exit 1
fi

if [ ! -d "$INSTALL_DIR" ]; then
    warn "Telemt not installed at $INSTALL_DIR. Nothing to remove."
    exit 0
fi

cd "$INSTALL_DIR"

# Detect compose command
if command -v docker-compose >/dev/null; then
    COMPOSE_CMD="docker-compose"
elif docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD=""  # fallback to raw docker
fi

# Confirm
while true; do
    read -p "Remove Telemt MTProto proxy? (Y/N): " confirm
    case "$confirm" in
        [Yy]*) break ;;
        [Nn]*) echo "Cancelled."; exit 0 ;;
        *)     echo "Enter Y or N." ;;
    esac
done

# --- Detect port for UFW cleanup ---
PORT=""
INBOUND_IP=""
if [ -f "$INSTALL_DIR/ufw_port.txt" ]; then
    PORT=$(cat "$INSTALL_DIR/ufw_port.txt")
fi
if [ -f /root/.network_config ]; then
    source /root/.network_config
fi

# --- Stop and remove container ---
info "Stopping container..."
if [ -n "$COMPOSE_CMD" ]; then
    $COMPOSE_CMD down --rmi local 2>/dev/null || true
else
    docker stop telemt 2>/dev/null || true
    docker rm telemt 2>/dev/null || true
fi

# --- Remove Docker image ---
info "Removing Docker image..."
docker image rm whn0thacked/telemt-docker:latest 2>/dev/null || true

# --- Clean UFW rules ---
if [ -n "$PORT" ] && command -v ufw >/dev/null; then
    info "Cleaning UFW rules (port $PORT)..."
    if [ "$USE_SPLIT_NETWORK" = "true" ] && [ -n "$INBOUND_IP" ]; then
        ufw delete allow to "$INBOUND_IP" port "$PORT" proto tcp 2>/dev/null || true
    fi
    ufw delete allow "$PORT/tcp" 2>/dev/null || true
fi

# --- Remove files ---
info "Removing $INSTALL_DIR..."
rm -rf "$INSTALL_DIR"

if [ -f /root/tg-proxy_secret.txt ]; then
    rm -f /root/tg-proxy_secret.txt
    info "Removed /root/tg-proxy_secret.txt"
fi

if [ -f /root/telemt-install.log ]; then
    rm -f /root/telemt-install.log
fi

info "Telemt removed successfully."