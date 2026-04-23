#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root."
    exit 1
fi

INSTALL_DIR="/etc/telemt-docker"

if [ -d "$INSTALL_DIR" ]; then
    cd "$INSTALL_DIR"
    
    # Identify IP for UFW cleanup
    INBOUND_IP=""
    if [ -f /root/.network_config ]; then
        source /root/.network_config
    fi

    # UFW Cleanup
    if [ -f ufw_port.txt ]; then
        PORT=$(cat ufw_port.txt)
        if command -v ufw >/dev/null && ufw status | grep -q active; then
            if [ -n "$INBOUND_IP" ]; then
                ufw delete allow to "$INBOUND_IP" port "$PORT" proto tcp 2>/dev/null || true
            fi
            ufw delete allow "$PORT/tcp" 2>/dev/null || true
        fi
    fi

    # Docker Cleanup
    if command -v docker-compose >/dev/null; then
        docker-compose down --rmi local 2>/dev/null || true
    elif docker compose version >/dev/null 2>&1; then
        docker compose down --rmi local 2>/dev/null || true
    else
        docker stop telemt 2>/dev/null || true
        docker rm telemt 2>/dev/null || true
    fi

    rm -rf "$INSTALL_DIR"
    rm -f /root/tg-proxy_secret.txt
    info "✅ Uninstalled successfully."
else
    echo "Installation not found."
fi