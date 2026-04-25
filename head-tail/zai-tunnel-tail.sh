#!/bin/bash
set -euo pipefail

SCRIPT_NAME="tunnel-tail"
LOG_FILE="/root/${SCRIPT_NAME}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Please run as root."
    exit 1
fi

echo "=================================================="
echo "[INFO] Starting TAIL setup script (Exit Node)..."
echo "=================================================="

echo "[1/5] Installing required packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard iptables iproute2 ufw

echo "[2/5] Enabling IPv4 forwarding..."
if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.d/99-tail.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-tail.conf
    sysctl -p /etc/sysctl.d/99-tail.conf > /dev/null
fi

echo "[3/5] Checking/Generating WireGuard keys..."
mkdir -p /etc/wireguard
PRIV_KEY_FILE="/etc/wireguard/tail_private.key"
PUB_KEY_FILE="/etc/wireguard/tail_public.key"
if [ ! -f "$PRIV_KEY_FILE" ]; then
    wg genkey | tee "$PRIV_KEY_FILE" | wg pubkey > "$PUB_KEY_FILE"
    chmod 600 "$PRIV_KEY_FILE"
fi
TAIL_PUB_KEY=$(cat "$PUB_KEY_FILE")

echo "--------------------------------------------------"
echo "[PROMPT] Public key of this TAIL server (copy to HEAD):"
echo -e "\e[32m$TAIL_PUB_KEY\e[0m"
echo "--------------------------------------------------"

read -rp "[PROMPT] Paste the public key of the HEAD server: " HEAD_PUB_KEY
if [ -z "$HEAD_PUB_KEY" ]; then echo "[ERROR] HEAD key cannot be empty."; exit 1; fi

DEFAULT_PORT=51820
read -rp "[PROMPT] Enter WireGuard listen port [default: $DEFAULT_PORT]: " WG_PORT
WG_PORT=${WG_PORT:-$DEFAULT_PORT}

MAIN_IFACE=$(ip -4 route show default | awk '{print $5; exit}') || true
if [ -z "$MAIN_IFACE" ]; then echo "[ERROR] Main interface not found."; exit 1; fi
echo "[INFO] Detected main interface: $MAIN_IFACE"

echo "[4/5] Checking UFW status..."
UFW_ACTIVE=false
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    UFW_ACTIVE=true
    echo "[INFO] UFW is active. Allowing WireGuard port $WG_PORT/udp..."
    ufw allow "$WG_PORT"/udp comment "WireGuard TAIL Tunnel" >/dev/null 2>&1 || true
    ufw reload >/dev/null 2>&1 || true
fi

echo "[5/5] Generating wg0.conf and starting service..."
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.10.10.1/24
ListenPort = $WG_PORT
PrivateKey = $(cat "$PRIV_KEY_FILE")

# Masquerade traffic leaving the tunnel to the internet
PostUp = iptables -t nat -A POSTROUTING -o $MAIN_IFACE -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o $MAIN_IFACE -j MASQUERADE

[Peer]
# HEAD Server
PublicKey = $HEAD_PUB_KEY
AllowedIPs = 10.10.10.2/32
EOF

systemctl daemon-reload
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

echo "=================================================="
echo "[SUCCESS] TAIL server setup completed successfully."
echo "=================================================="