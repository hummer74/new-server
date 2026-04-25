#!/bin/bash
set -euo pipefail

# --- Configuration ---
SCRIPT_NAME=$(basename "$0" .sh)
LOG_FILE="/root/${SCRIPT_NAME}.log"

# --- Init Logging ---
exec > >(tee -a "$LOG_FILE") 2>&1

# --- Checks ---
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Please run as root (sudo)."
    exit 1
fi

echo "=================================================="
echo "[INFO] Starting TAIL setup script..."
echo "=================================================="

# --- 1. Install packages ---
echo "[1/4] Installing required packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard iptables

# --- 2. Enable Forwarding ---
echo "[2/4] Enabling IPv4 forwarding..."
if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.d/99-tail.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-tail.conf
    sysctl -p /etc/sysctl.d/99-tail.conf > /dev/null
fi

# --- 3. Generate Keys (Idempotent) ---
echo "[3/4] Checking/Generating WireGuard keys..."
PRIV_KEY_FILE="/etc/wireguard/tail_private.key"
PUB_KEY_FILE="/etc/wireguard/tail_public.key"
if [ ! -f "$PRIV_KEY_FILE" ]; then
    wg genkey | tee "$PRIV_KEY_FILE" | wg pubkey > "$PUB_KEY_FILE"
    chmod 600 "$PRIV_KEY_FILE"
fi
TAIL_PUB_KEY=$(cat "$PUB_KEY_FILE")

echo "--------------------------------------------------"
echo "[PROMPT] Public key of this TAIL server (copy to HEAD):"
echo "$TAIL_PUB_KEY"
echo "--------------------------------------------------"

read -rp "[PROMPT] Paste the public key of the HEAD server: " HEAD_PUB_KEY
if [ -z "$HEAD_PUB_KEY" ]; then
    echo "[ERROR] HEAD public key cannot be empty."
    exit 1
fi

DEFAULT_PORT=51820
read -rp "[PROMPT] Enter WireGuard listen port [default: $DEFAULT_PORT]: " WG_PORT
WG_PORT=${WG_PORT:-$DEFAULT_PORT}

# Detect main interface safely
MAIN_IFACE=$(ip -4 route show default | awk '{print $5; exit}') || true
if [ -z "$MAIN_IFACE" ]; then
    echo "[ERROR] Failed to detect the main network interface."
    exit 1
fi
echo "[INFO] Detected main interface: $MAIN_IFACE"

# --- 4. Configure and Start WireGuard ---
echo "[4/4] Generating wg0.conf and starting service..."
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.10.10.1/24
ListenPort = $WG_PORT
PrivateKey = $(cat "$PRIV_KEY_FILE")
PostUp = iptables -t nat -A POSTROUTING -o $MAIN_IFACE -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o $MAIN_IFACE -j MASQUERADE

[Peer]
PublicKey = $HEAD_PUB_KEY
AllowedIPs = 10.10.10.2/32
EOF

systemctl daemon-reload
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

echo "=================================================="
echo "[SUCCESS] TAIL server setup completed successfully."
echo "=================================================="
