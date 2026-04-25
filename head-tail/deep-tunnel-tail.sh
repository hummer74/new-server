#!/bin/bash
# tunnel-tail.sh – Configure TAIL server as WireGuard exit node
# Runs on the TAIL (exit) VPS to terminate client traffic from HEAD.

set -euo pipefail

LOG="/root/${0##*/}.log"
exec > >(tee -a "$LOG") 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ---------- Root check ----------
if [[ $EUID -ne 0 ]]; then
    log "This script must be run as root."
    exit 1
fi

install_if_missing() {
    if ! dpkg -s "$1" >/dev/null 2>&1; then
        log "Installing $1..."
        apt-get update -qq && apt-get install -y "$1"
    fi
}

confirm_default() {
    local prompt="$1"; local default="$2"
    read -p "$prompt [$default]: " input
    echo "${input:-$default}"
}

log "=== TAIL exit node setup started ==="

# ---------- Parameters ----------
CLIENT_SUBNET="${1:-$(confirm_default "Amnezia client subnet (same as on HEAD)" "10.8.0.0/24")}"
TUNNEL_IP="${2:-$(confirm_default "TAIL IP inside tunnel (with prefix)" "10.9.0.2/30")}"
PORT="${3:-$(confirm_default "WireGuard listen port" "51820")}"

# Detect default public interface (no ICMP)
DEFAULT_IFACE=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' || ip route show default | awk '{print $5; exit}')
IFACE="${4:-$(confirm_default "Public interface" "${DEFAULT_IFACE:-eth0}")}"

CONF="/etc/wireguard/wg0.conf"

# ---------- Install packages ----------
install_if_missing wireguard
install_if_missing iptables

# ---------- Idempotency check ----------
if [ -f "$CONF" ]; then
    log "WireGuard configuration $CONF already exists."
    PUBKEY=$(wg show wg0 public-key 2>/dev/null || cat /etc/wireguard/public.key 2>/dev/null || echo "unknown")
    log "Current TAIL public key: $PUBKEY"
    log "To recreate the tunnel remove $CONF manually and re-run the script."
    exit 0
fi

# ---------- Generate keys ----------
mkdir -p /etc/wireguard
if [ ! -f /etc/wireguard/private.key ]; then
    wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
    chmod 600 /etc/wireguard/private.key
    log "Keys generated for TAIL."
fi
PRIVKEY=$(cat /etc/wireguard/private.key)
PUBKEY=$(cat /etc/wireguard/public.key)

# ---------- Create WireGuard config ----------
cat > "$CONF" <<EOF
[Interface]
Address = $TUNNEL_IP
PrivateKey = $PRIVKEY
ListenPort = $PORT

# NAT for Amnezia clients arriving from HEAD
PostUp = iptables -t nat -C POSTROUTING -s $CLIENT_SUBNET -o $IFACE -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $CLIENT_SUBNET -o $IFACE -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s $CLIENT_SUBNET -o $IFACE -j MASQUERADE 2>/dev/null || true
EOF

log "Configuration file $CONF written."

# ---------- Enable IP forwarding ----------
if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p
    log "IP forwarding enabled."
fi

# ---------- Start WireGuard ----------
systemctl enable --now wg-quick@wg0
log "WireGuard interface wg0 started on TAIL."

# ---------- Output information ----------
TAIL_EXTERNAL_IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
log ""
log "TAIL exit node configured successfully."
log "TAIL public key: $PUBKEY"
log "TAIL external IP: $TAIL_EXTERNAL_IP"
log "Tunnel subnet: $TUNNEL_IP (TAIL side is ${TUNNEL_IP%/*})"
log "Listen port: $PORT"
log "Client subnet: $CLIENT_SUBNET"
log ""
log "Provide these values to the HEAD setup script:"
log "  TAIL external IP: $TAIL_EXTERNAL_IP"
log "  TAIL public key: $PUBKEY"
log "  Port: $PORT"
log "  Client subnet: $CLIENT_SUBNET"