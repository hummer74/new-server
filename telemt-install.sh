#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

SUCCESS=0

rollback() {
    echo ""
    warn "An error occurred. Rolling back..."
    cd /etc/telemt-docker 2>/dev/null || true
    
    # Use the detected command if possible, otherwise fallback to docker
    if [ -n "${DOCKER_COMPOSE_CMD:-}" ] && command -v ${DOCKER_COMPOSE_CMD%% *} >/dev/null; then
        $DOCKER_COMPOSE_CMD down --rmi local 2>/dev/null || true
    fi

    if [ -f /etc/telemt-docker/ufw_port.txt ]; then
        local PORT=$(cat /etc/telemt-docker/ufw_port.txt)
        if command -v ufw >/dev/null && ufw status | grep -q active; then
            ufw delete allow "$PORT/tcp" 2>/dev/null || true
        fi
        rm -f /etc/telemt-docker/ufw_port.txt
    fi
    rm -rf /etc/telemt-docker
    rm -f /root/tg-proxy_secret.txt
    error "Rollback complete. System is clean."
}

# Clean cleanup logic: only rollback if SUCCESS is 0
cleanup() {
    if [ "$SUCCESS" -eq 0 ]; then
        rollback
    fi
}

trap cleanup EXIT

if [ "$EUID" -ne 0 ]; then
    error "Please run as root (sudo)"
    exit 1
fi

# Check if Docker Engine is installed
if ! command -v docker >/dev/null; then
    warn "Docker Engine not found. Installing..."
    apt-get update
    apt-get install -y docker.io
    systemctl enable --now docker
    info "Docker Engine installed and started."
fi

# Ensure docker daemon is actually running
if ! docker info >/dev/null 2>&1; then
    error "Docker daemon is not running. Please start it with: systemctl start docker"
    exit 1
fi

# Determine Docker Compose command (Supports V1 and V2)
if command -v docker-compose >/dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
    info "Using Docker Compose: $DOCKER_COMPOSE_CMD"
elif docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker compose"
    info "Using Docker Compose: $DOCKER_COMPOSE_CMD"
else
    warn "Docker Compose not found. Installing..."
    apt-get update
    apt-get install -y docker-compose
    DOCKER_COMPOSE_CMD="docker-compose"
    info "Docker Compose installed: $DOCKER_COMPOSE_CMD"
fi

# Install dependencies
command -v apparmor_parser >/dev/null || { apt-get update && apt-get install -y apparmor; }
command -v openssl >/dev/null || { apt-get update && apt-get install -y openssl; }
command -v xxd >/dev/null || { apt-get update && apt-get install -y xxd; }
command -v curl >/dev/null || { apt-get update && apt-get install -y curl; }
if ! command -v ufw >/dev/null; then
    warn "UFW not found. Installing..."
    apt-get update && apt-get install -y ufw
fi

info "Determining external IP..."
EXTERNAL_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || curl -s icanhazip.com)
if [ -z "$EXTERNAL_IP" ]; then
    warn "Could not automatically determine external IP"
    read -p "Enter external IP manually: " EXTERNAL_IP
    [ -z "$EXTERNAL_IP" ] && { error "No IP provided"; exit 1; }
fi
info "External IP: $EXTERNAL_IP"

DEFAULT_PORT=8443
DEFAULT_TLS_DOMAIN="github.com"
DEFAULT_USERNAME="proxy_user"

read -p "External proxy port (both container and host) [${DEFAULT_PORT}]: " HOST_PORT
HOST_PORT=${HOST_PORT:-$DEFAULT_PORT}

read -p "TLS masking domain [${DEFAULT_TLS_DOMAIN}]: " TLS_DOMAIN
TLS_DOMAIN=${TLS_DOMAIN:-$DEFAULT_TLS_DOMAIN}

read -p "Username [${DEFAULT_USERNAME}]: " USERNAME
USERNAME=${USERNAME:-$DEFAULT_USERNAME}

info "Generating secret..."
SECRET=$(openssl rand -hex 16)
info "Secret: $SECRET"

TLS_DOMAIN_HEX=$(printf "%s" "$TLS_DOMAIN" | xxd -p -c 1000 | tr -d '\n')
info "Domain hex: $TLS_DOMAIN_HEX"

FULL_SECRET="ee${SECRET}${TLS_DOMAIN_HEX}"
info "Full secret: $FULL_SECRET"

INSTALL_DIR="/etc/telemt-docker"
CONFIG_DIR="$INSTALL_DIR/config"
mkdir -p "$CONFIG_DIR"
cd "$INSTALL_DIR"
info "Working directory: $INSTALL_DIR"

cat > "$CONFIG_DIR/telemt.toml" <<EOF
[general]
use_middle_proxy = false
[general.modes]
classic = false
secure = false
tls = true
[server]
port = $HOST_PORT
[server.api]
enabled = true
listen = "127.0.0.1:9091"
[censorship]
tls_domain = "$TLS_DOMAIN"
[access.users]
$USERNAME = "$SECRET"
EOF

chmod -R 777 "$CONFIG_DIR"

# version: '3.3' is used for maximum compatibility with old and new engines
cat > docker-compose.yml <<EOF
version: '3.3'
services:
  telemt:
    image: whn0thacked/telemt-docker:latest
    container_name: telemt
    restart: unless-stopped
    ports:
      - "$HOST_PORT:$HOST_PORT"
    environment:
      RUST_LOG: info
    volumes:
      - "$CONFIG_DIR:/etc/telemt"
    command: ["/etc/telemt/telemt.toml"]
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    tmpfs:
      - /tmp:rw,nosuid,nodev,noexec,size=16m
    ulimits:
      nofile: 65536
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

if ufw status | grep -q active; then
    info "UFW is active. Opening port $HOST_PORT/tcp..."
    ufw allow "$HOST_PORT/tcp"
    echo "$HOST_PORT" > "$INSTALL_DIR/ufw_port.txt"
else
    warn "UFW is not active. Port $HOST_PORT will not be opened automatically."
    echo "$HOST_PORT" > "$INSTALL_DIR/ufw_port.txt"
fi

info "Starting telemt with $DOCKER_COMPOSE_CMD..."
$DOCKER_COMPOSE_CMD up -d

info "Waiting for container to be ready (up to 30 sec)..."
for i in {1..30}; do
    if docker ps --format '{{.Names}}' | grep -q "^telemt$"; then
        break
    fi
    sleep 1
done

if ! docker ps --format '{{.Names}}' | grep -q "^telemt$"; then
    error "Container telemt failed to start. Check logs: docker logs telemt"
    exit 1
fi

LINK="tg://proxy?server=${EXTERNAL_IP}&port=${HOST_PORT}&secret=${FULL_SECRET}"
echo "$LINK" > /root/tg-proxy_secret.txt
info "✅ Link saved to /root/tg-proxy_secret.txt"
cat /root/tg-proxy_secret.txt

SUCCESS=1
echo ""
info "✅ Deployment complete!"
echo "Proxy is available on port $HOST_PORT (TCP only, UDP is not used by MTProxy)"
echo "To view logs: cd $INSTALL_DIR && $DOCKER_COMPOSE_CMD logs -f"
echo "To stop: cd $INSTALL_DIR && $DOCKER_COMPOSE_CMD down"