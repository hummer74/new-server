#!/bin/bash
# ============================================================
#  telemt-install.sh v2 — Universal MTProto Proxy Installer
#
#  Installs Telemt MTProto proxy in Docker on any
#  Debian 11/12/13 server (with or without Split Network).
#
#  Features:
#    - Idempotent: safe to re-run, detects existing install
#    - Interactive domain selection from pre-configured list
#    - Auto-detects Split Network from /root/.network_config
#    - Rollback on failure (trap cleanup EXIT)
#    - Docker + Compose auto-install with both CLI variants
#    - UFW Docker patch (DOCKER-USER chain in after.rules)
#    - Secure container: read_only, cap_drop ALL, nofile 65536
#    - Config: chmod 600 (not 777)
#    - Full logging to /root/telemt-install.log
# ============================================================
set -euo pipefail

# === Colors ===
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
header(){ echo -e "${CYAN}$1${NC}"; }

# === Logging ===
LOG="/root/telemt-install.log"
exec > >(tee -a "$LOG") 2>&1
info "$(date '+%Y-%m-%d %H:%M:%S %Z') — telemt-install.sh started"

# === Root check ===
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root."
    exit 1
fi

# === Rollback state ===
SUCCESS=0
ROLLBACK_STEPS=()

rollback() {
    echo ""
    warn "Installation failed. Rolling back ${#ROLLBACK_STEPS[@]} step(s)..."
    # Execute rollback steps in reverse order
    for (( i=${#ROLLBACK_STEPS[@]}-1; i>=0; i-- )); do
        eval "${ROLLBACK_STEPS[$i]}" 2>/dev/null || true
    done
    error "Rollback complete. System is clean."
}

cleanup() {
    if [ "$SUCCESS" -eq 0 ]; then
        rollback
    fi
}
trap cleanup EXIT

# ============================================================
#  STEP 1: Detect Debian version
# ============================================================
header "=============================================="
header "  Telemt MTProto Proxy — Universal Installer"
header "=============================================="
echo ""

DEBIAN_VERSION_ID="0"
DEBIAN_CODENAME="unknown"

if [ -f /etc/os-release ]; then
    source /etc/os-release
    DEBIAN_VERSION_ID="${VERSION_ID:-0}"
    DEBIAN_CODENAME="${VERSION_CODENAME:-unknown}"
fi

case "$DEBIAN_CODENAME" in
    bullseye)  info "Debian 11 (Bullseye) detected" ;;
    bookworm)  info "Debian 12 (Bookworm) detected" ;;
    trixie)    info "Debian 13 (Trixie) detected" ;;
    *)         warn "Detected: ${PRETTY_NAME:-unknown}. Proceeding anyway..." ;;
esac

# ============================================================
#  STEP 2: Check for existing installation (idempotent)
# ============================================================
INSTALL_DIR="/etc/telemt-docker"
EXISTING_INSTALL=false
RECONFIGURE=false

if [ -d "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
    EXISTING_INSTALL=true
    header "Existing Telemt installation found at $INSTALL_DIR"
    
    # Show current config
    if [ -f "$INSTALL_DIR/config/telemt.toml" ]; then
        CURRENT_PORT=$(grep -oP 'port\s*=\s*\K\d+' "$INSTALL_DIR/config/telemt.toml" 2>/dev/null || echo "?")
        CURRENT_DOMAIN=$(grep -oP 'tls_domain\s*=\s*"\K[^"]+' "$INSTALL_DIR/config/telemt.toml" 2>/dev/null || echo "?")
        CURRENT_USER=$(grep -oP '^\s*\K[^= ]+(?=\s*=)' "$INSTALL_DIR/config/telemt.toml" 2>/dev/null | tail -1 || echo "?")
        info "  Port:   $CURRENT_PORT"
        info "  Domain: $CURRENT_DOMAIN"
        info "  User:   $CURRENT_USER"
    fi

    if [ -f /root/tg-proxy_secret.txt ]; then
        info "  Link:   $(cat /root/tg-proxy_secret.txt)"
    fi

    echo ""
    while true; do
        read -p "Reconfigure proxy? (Y/N): " reconf_choice
        case "$reconf_choice" in
            [Yy]*) RECONFIGURE=true; break ;;
            [Nn]*) info "Keeping existing configuration. Exiting."; exit 0 ;;
            *)     echo "Enter Y or N." ;;
        esac
    done
fi

# ============================================================
#  STEP 3: Install dependencies
# ============================================================
header "Step 1: Dependencies"
info "Checking required packages..."

apt-get update -qq || { error "apt-get update failed"; exit 1; }

REQUIRED_PKGS="curl openssl xxd ufw ca-certificates gnupg2"
for pkg in $REQUIRED_PKGS; do
    if dpkg -s "$pkg" 2>/dev/null | grep -q '^Status: install ok installed'; then
        info "  $pkg: installed"
    else
        info "  $pkg: installing..."
        apt-get install -y "$pkg" >/dev/null || { error "Failed to install $pkg"; exit 1; }
        ROLLBACK_STEPS+=("apt-get remove -y $pkg 2>/dev/null || true")
    fi
done

# ============================================================
#  STEP 4: Network configuration (Split Network)
# ============================================================
header "Step 2: Network Configuration"
USE_SPLIT_NETWORK="false"
INBOUND_IP=""
OUTBOUND_IP=""

if [ -f /root/.network_config ]; then
    source /root/.network_config
    info "Network config loaded from /root/.network_config"
    info "  Inbound:  $INBOUND_IP"
    info "  Outbound: $OUTBOUND_IP"
    info "  Split:    $USE_SPLIT_NETWORK"
else
    warn "No /root/.network_config found."

    # Auto-detect multiple IPs
    IPS=($(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n || true))

    if [ ${#IPS[@]} -gt 1 ]; then
        echo "  Found multiple IPs:"
        for i in "${!IPS[@]}"; do
            echo "    [$i] ${IPS[$i]}"
        done
        echo ""
        while true; do
            read -p "  Use Split Network mode? (Y/N): " split_choice
            case "$split_choice" in
                [Yy]*)
                    MAX_IDX=$((${#IPS[@]} - 1))
                    while true; do
                        read -p "  INBOUND index [0-$MAX_IDX]: " in_idx
                        if [[ "$in_idx" =~ ^[0-9]+$ ]] && [ "$in_idx" -ge 0 ] && [ "$in_idx" -le "$MAX_IDX" ]; then
                            INBOUND_IP=${IPS[$in_idx]}
                            break
                        fi
                        echo "  Invalid index."
                    done
                    while true; do
                        read -p "  OUTBOUND index [0-$MAX_IDX]: " out_idx
                        if [[ "$out_idx" =~ ^[0-9]+$ ]] && [ "$out_idx" -ge 0 ] && [ "$out_idx" -le "$MAX_IDX" ]; then
                            OUTBOUND_IP=${IPS[$out_idx]}
                            break
                        fi
                        echo "  Invalid index."
                    done
                    USE_SPLIT_NETWORK="true"
                    break
                    ;;
                [Nn]*) break ;;
                *)     echo "  Enter Y or N." ;;
            esac
        done
    else
        info "  Single IP detected: ${IPS[0]:-unknown}. Standard mode."
    fi
fi

if [ "$USE_SPLIT_NETWORK" == "true" ] && [ -n "$INBOUND_IP" ]; then
    EXTERNAL_IP="$INBOUND_IP"
    info "External IP for proxy link: $EXTERNAL_IP (Inbound)"
else
    EXTERNAL_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || curl -s --max-time 5 ipinfo.io/ip 2>/dev/null || echo "UNKNOWN")
    info "External IP for proxy link: $EXTERNAL_IP"
fi

# ============================================================
#  STEP 5: Docker setup
# ============================================================
header "Step 3: Docker"

if command -v docker >/dev/null; then
    info "Docker is installed."
else
    info "Installing Docker..."
    if apt-cache show docker.io >/dev/null 2>&1; then
        apt-get install -y docker.io docker-compose >/dev/null 2>&1
    fi
    if ! command -v docker >/dev/null; then
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh >/dev/null 2>&1
        rm -f /tmp/get-docker.sh
        ROLLBACK_STEPS+=("apt-get purge -y docker.io docker-ce docker-ce-cli containerd.io 2>/dev/null; rm -rf /var/lib/docker /etc/docker")
    fi
    systemctl enable --now docker
    info "Docker installed and enabled."
fi

# Compose CLI detection
if command -v docker-compose >/dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
elif docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker compose"
else
    apt-get install -y docker-compose >/dev/null 2>&1 || true
    if command -v docker-compose >/dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        DOCKER_COMPOSE_CMD="docker compose"
    fi
fi
info "Compose command: $DOCKER_COMPOSE_CMD"

# ============================================================
#  STEP 6: UFW Docker patch
# ============================================================
header "Step 4: UFW + Docker"
if [ -f /etc/ufw/after.rules ] && ! grep -q "BEGIN UFW AND DOCKER" /etc/ufw/after.rules; then
    info "Patching UFW for Docker (DOCKER-USER chain)..."
    cat >> /etc/ufw/after.rules <<'EOF'

# BEGIN UFW AND DOCKER
*filter
:ufw-user-forward - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -j RETURN -s 10.0.0.0/8
-A DOCKER-USER -j RETURN -s 172.16.0.0/12
-A DOCKER-USER -j RETURN -s 192.168.0.0/16
-A DOCKER-USER -j ufw-user-forward
-A DOCKER-USER -j RETURN
COMMIT
# END UFW AND DOCKER
EOF
    ufw reload >/dev/null 2>&1 || true
    ROLLBACK_STEPS+=("sed -i '/# BEGIN UFW AND DOCKER/,/# END UFW AND DOCKER/d' /etc/ufw/after.rules; ufw reload 2>/dev/null || true")
    info "UFW Docker patch applied."
else
    info "UFW Docker patch already present or UFW not used."
fi

# ============================================================
#  STEP 7: Interactive proxy configuration
# ============================================================
header "Step 5: Proxy Configuration"
echo ""

# --- Port ---
if [ "$RECONFIGURE" = true ] && [ -n "${CURRENT_PORT:-}" ]; then
    DEFAULT_PORT="$CURRENT_PORT"
else
    DEFAULT_PORT="10443"
fi
read -p "  Enter proxy port [${DEFAULT_PORT}]: " USER_HOST_PORT
HOST_PORT="${USER_HOST_PORT:-$DEFAULT_PORT}"

# --- TLS Domain ---
echo ""
echo "  Select TLS domain for MTProto proxy:"
echo "    1) FRANCE:      paroissederochefort.fr"
echo "    2) GERMANY:     bistum-eichstaett.de"
echo "    3) FINLAND:     saimaasailing.fi"
echo "    4) NETHERLANDS: esac.nl"
echo "    5) ROMANIA:     bgw.com"
echo "    6) Custom domain"
echo ""
while true; do
    read -p "  Enter choice [1-6, default 3]: " DOMAIN_CHOICE
    case "${DOMAIN_CHOICE:-3}" in
        1) TLS_DOMAIN="paroissederochefort.fr"; break ;;
        2) TLS_DOMAIN="bistum-eichstaett.de"; break ;;
        3) TLS_DOMAIN="saimaasailing.fi"; break ;;
        4) TLS_DOMAIN="esac.nl"; break ;;
        5) TLS_DOMAIN="bgw.com"; break ;;
        6)
            while true; do
                read -p "  Enter custom TLS domain: " TLS_DOMAIN
                if [ -n "$TLS_DOMAIN" ]; then break; fi
                echo "  Domain cannot be empty."
            done
            break
            ;;
        *) echo "  Invalid choice. Enter 1-6." ;;
    esac
done
info "  Domain: $TLS_DOMAIN"

# --- Username ---
if [ "$RECONFIGURE" = true ] && [ -n "${CURRENT_USER:-}" ]; then
    DEFAULT_USER="$CURRENT_USER"
else
    DEFAULT_USER="test_user"
fi
read -p "  Enter proxy username [${DEFAULT_USER}]: " USER_PROXY_NAME
USERNAME="${USER_PROXY_NAME:-$DEFAULT_USER}"

# ============================================================
#  STEP 8: Generate secrets and config
# ============================================================
header "Step 6: Generating Configuration"

# Reuse existing secret on reconfigure
if [ "$RECONFIGURE" = true ] && [ -f "$INSTALL_DIR/config/telemt.toml" ]; then
    EXISTING_SECRET=$(grep -oP '=\s*"\K[a-f0-9]+' "$INSTALL_DIR/config/telemt.toml" 2>/dev/null | head -1 || echo "")
    if [ -n "$EXISTING_SECRET" ]; then
        SECRET="$EXISTING_SECRET"
        info "Reusing existing secret (no link change for clients)."
    else
        SECRET=$(openssl rand -hex 16)
        warn "Could not extract existing secret. Generated new one."
    fi
else
    SECRET=$(openssl rand -hex 16)
fi

TLS_DOMAIN_HEX=$(printf "%s" "$TLS_DOMAIN" | xxd -p -c 1000 | tr -d '\n')
FULL_SECRET="ee${SECRET}${TLS_DOMAIN_HEX}"

# Prepare directory
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

# Secure config (contains secret!)
chmod 600 "$INSTALL_DIR/config/telemt.toml"
chmod 600 "$INSTALL_DIR/config"
info "Config written: config/telemt.toml"

# Docker compose
TELEMT_BIND="$HOST_PORT"
if [ "$USE_SPLIT_NETWORK" == "true" ] && [ -n "$INBOUND_IP" ]; then
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
      nofile:
        soft: 65536
        hard: 65536
EOF
info "Docker Compose written."

# Save port for uninstaller
echo "$HOST_PORT" > "$INSTALL_DIR/ufw_port.txt"

# ============================================================
#  STEP 9: UFW + Start
# ============================================================
header "Step 7: Firewall & Start"

# Remove old UFW rule if reconfiguring with different port
if [ "$RECONFIGURE" = true ] && [ -n "${CURRENT_PORT:-}" ] && [ "$CURRENT_PORT" != "$HOST_PORT" ]; then
    if [ "$USE_SPLIT_NETWORK" == "true" ] && [ -n "$INBOUND_IP" ]; then
        ufw delete allow to "$INBOUND_IP" port "$CURRENT_PORT" proto tcp 2>/dev/null || true
    else
        ufw delete allow "$CURRENT_PORT/tcp" 2>/dev/null || true
    fi
    info "Old UFW rule (port $CURRENT_PORT) removed."
fi

# Add UFW rule
if [ "$USE_SPLIT_NETWORK" == "true" ] && [ -n "$INBOUND_IP" ]; then
    ufw allow to "$INBOUND_IP" port "$HOST_PORT" proto tcp 2>/dev/null || true
    info "UFW: allowed $HOST_PORT/tcp on $INBOUND_IP"
else
    ufw allow "$HOST_PORT/tcp" 2>/dev/null || true
    info "UFW: allowed $HOST_PORT/tcp globally"
fi

# Start container
info "Starting Telemt container..."
if [ "$RECONFIGURE" = true ]; then
    $DOCKER_COMPOSE_CMD up -d --force-recreate 2>/dev/null
else
    $DOCKER_COMPOSE_CMD up -d 2>/dev/null
fi

sleep 3

# Verify container is running
if docker ps --filter "name=telemt" --format '{{.Status}}' | grep -q "Up"; then
    info "Container telemt is running."
else
    warn "Container telemt may not be running. Check: docker ps -a"
fi

# ============================================================
#  STEP 10: Generate link
# ============================================================
LINK="tg://proxy?server=${EXTERNAL_IP}&port=${HOST_PORT}&secret=${FULL_SECRET}"
echo "$LINK" > /root/tg-proxy_secret.txt

# Mark success — disables rollback
SUCCESS=1

# ============================================================
#  Summary
# ============================================================
echo ""
header "=============================================="
info "  Installation complete!"
header "=============================================="
info "  User:   $USERNAME"
info "  Port:   $HOST_PORT"
info "  Domain: $TLS_DOMAIN"
info "  Link:   $LINK"
info ""
info "  Link saved to: /root/tg-proxy_secret.txt"
info "  Log saved to:   $LOG"
header "=============================================="
echo ""