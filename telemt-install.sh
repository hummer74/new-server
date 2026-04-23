#!/bin/bash
set -euo pipefail

# === Colors and Logging ===
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

SUCCESS=0

# === Rollback Logic ===
rollback() {
    echo ""
    warn "An error occurred. Rolling back..."
    cd /etc/telemt-docker 2>/dev/null || true
    
    if [ -n "${DOCKER_COMPOSE_CMD:-}" ] && command -v ${DOCKER_COMPOSE_CMD%% *} >/dev/null; then
        $DOCKER_COMPOSE_CMD down --rmi local 2>/dev/null || true
    fi

    if [ -f /etc/telemt-docker/ufw_port.txt ]; then
        local PORT
        PORT=$(cat /etc/telemt-docker/ufw_port.txt)
        if command -v ufw >/dev/null; then
            # Удаляем оба возможных варианта правила (глобальное и привязанное к IP)
            if [ "${USE_SPLIT_NETWORK:-false}" == "true" ] && [ -n "${INBOUND_IP:-}" ]; then
                ufw delete allow to "$INBOUND_IP" port "$PORT" proto tcp 2>/dev/null || true
            fi
            ufw delete allow "$PORT/tcp" 2>/dev/null || true
        fi
    fi
    rm -rf /etc/telemt-docker
    rm -f /root/tg-proxy_secret.txt
    error "Rollback complete. System is clean."
}

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

# === STEP 1: Dependencies Check (APT) ===
info "Checking and installing dependencies..."
apt-get update -qq || { error "apt-get update failed"; exit 1; }

# Удалён пакет software-properties-common (не требуется для работы скрипта)
REQUIRED_PKGS="curl openssl xxd ufw ca-certificates gnupg2"
for pkg in $REQUIRED_PKGS; do
    if ! dpkg -s "$pkg" 2>/dev/null | grep -q '^Status: install ok installed'; then
        info "Installing $pkg..."
        apt-get install -y "$pkg" >/dev/null || { error "Failed to install $pkg"; exit 1; }
    fi
done

# === STEP 2: Network Configuration ===
USE_SPLIT_NETWORK="false"
INBOUND_IP=""
OUTBOUND_IP=""

if [ -f /root/.network_config ]; then
    source /root/.network_config
    info "Existing network config loaded (Inbound: $INBOUND_IP)."
else
    warn "No network config found at /root/.network_config."
    read -p "Do you want to use Inbound/Outbound split technology? (Y/N): " choice
    case "$choice" in 
      y|Y ) 
        info "Analyzing network interfaces..."
        # Получаем только глобальные публичные IPv4 адреса
        IPS=($(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true))
        
        if [ ${#IPS[@]} -lt 2 ]; then
            error "Less than 2 global IPv4 addresses found. Falling back to standard mode."
            USE_SPLIT_NETWORK="false"
        else
            echo "Found public IPv4 addresses:"
            for i in "${!IPS[@]}"; do echo "[$i] ${IPS[$i]}"; done
            # Проверка корректности ввода индексов
            while true; do
                read -p "Select index for INBOUND (0-$((${#IPS[@]}-1))): " in_idx
                if [[ "$in_idx" =~ ^[0-9]+$ ]] && [ "$in_idx" -ge 0 ] && [ "$in_idx" -lt ${#IPS[@]} ]; then
                    break
                else
                    warn "Invalid index. Please try again."
                fi
            done
            while true; do
                read -p "Select index for OUTBOUND (0-$((${#IPS[@]}-1))): " out_idx
                if [[ "$out_idx" =~ ^[0-9]+$ ]] && [ "$out_idx" -ge 0 ] && [ "$out_idx" -lt ${#IPS[@]} ]; then
                    break
                else
                    warn "Invalid index. Please try again."
                fi
            done
            INBOUND_IP=${IPS[$in_idx]}
            OUTBOUND_IP=${IPS[$out_idx]}
            USE_SPLIT_NETWORK="true"
        fi
        ;;
      * ) USE_SPLIT_NETWORK="false" ;;
    esac
fi

# === STEP 3: Docker Setup ===
if ! command -v docker >/dev/null; then
    info "Installing Docker Engine..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh >/dev/null 2>&1
    systemctl enable --now docker
    rm get-docker.sh
fi

if command -v docker-compose >/dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
elif docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker compose"
else
    info "Installing Docker Compose..."
    apt-get install -y docker-compose >/dev/null || { error "Failed to install docker-compose"; exit 1; }
    DOCKER_COMPOSE_CMD="docker-compose"
fi

# === STEP 4: Interactive Proxy Configuration ===
info "--- Proxy Configuration ---"
if [ "$USE_SPLIT_NETWORK" == "true" ] && [ -n "$INBOUND_IP" ]; then
    EXTERNAL_IP="$INBOUND_IP"
else
    EXTERNAL_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip)
fi

# Set default values
DEFAULT_PORT=10443
DEFAULT_TLS_DOMAIN="google.com"
DEFAULT_USERNAME="proxy_admin"

# Interactive input with defaults
read -p "Enter proxy port [${DEFAULT_PORT}]: " HOST_PORT
HOST_PORT=${HOST_PORT:-$DEFAULT_PORT}

read -p "Enter TLS masking domain [${DEFAULT_TLS_DOMAIN}]: " TLS_DOMAIN
TLS_DOMAIN=${TLS_DOMAIN:-$DEFAULT_TLS_DOMAIN}

read -p "Enter proxy username [${DEFAULT_USERNAME}]: " USERNAME
USERNAME=${USERNAME:-$DEFAULT_USERNAME}

# === STEP 5: Generate Secrets and Files ===
SECRET=$(openssl rand -hex 16)
TLS_DOMAIN_HEX=$(printf "%s" "$TLS_DOMAIN" | xxd -p -c 1000 | tr -d '\n')
FULL_SECRET="ee${SECRET}${TLS_DOMAIN_HEX}"

INSTALL_DIR="/etc/telemt-docker"
mkdir -p "$INSTALL_DIR/config"
cd "$INSTALL_DIR"

cat > "config/telemt.toml" <<EOF
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

# Защита конфигурационного файла (секретный ключ)
chmod 600 config/telemt.toml

TELEMT_BIND="$HOST_PORT"
if [ "$USE_SPLIT_NETWORK" == "true" ]; then
    TELEMT_BIND="$INBOUND_IP:$HOST_PORT"
fi

cat > docker-compose.yml <<EOF
version: '3.3'
services:
  telemt:
    image: whn0thacked/telemt-docker:latest
    container_name: telemt
    restart: unless-stopped
    ports:
      - "$TELEMT_BIND:$HOST_PORT"
    volumes:
      - "./config:/etc/telemt"
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
EOF

# === STEP 6: Firewall and Execution ===
# Добавляем правило UFW независимо от его активности
if [ "$USE_SPLIT_NETWORK" == "true" ]; then
    info "Opening UFW port $HOST_PORT on Inbound IP $INBOUND_IP..."
    ufw allow to "$INBOUND_IP" port "$HOST_PORT" proto tcp 2>/dev/null || true
else
    info "Opening UFW port $HOST_PORT globally..."
    ufw allow "$HOST_PORT/tcp" 2>/dev/null || true
fi
# Сохраняем порт для возможного отката
echo "$HOST_PORT" > ufw_port.txt

info "Starting Telemt container..."
$DOCKER_COMPOSE_CMD up -d

# Проверка, что контейнер действительно запустился
sleep 3
if docker ps --filter "name=telemt" --format '{{.Status}}' | grep -q "Up"; then
    info "Container telemt is running."
else
    warn "Container telemt might not be running. Check 'docker ps -a'."
fi

# Final Link Generation
LINK="tg://proxy?server=${EXTERNAL_IP}&port=${HOST_PORT}&secret=${FULL_SECRET}"
echo "$LINK" > /root/tg-proxy_secret.txt

SUCCESS=1
echo ""
info "✅ Installation finished successfully!"
info "Proxy User: $USERNAME"
info "Proxy Port: $HOST_PORT"
info "TLS Domain: $TLS_DOMAIN"
info "Connection link saved to /root/tg-proxy_secret.txt"
echo ""
cat /root/tg-proxy_secret.txt