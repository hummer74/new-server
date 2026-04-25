#!/bin/bash
set -euo pipefail

# ============================================================
#  zai-tunnel-tail.sh  —  TAIL (Exit Node)
#  WireGuard tunnel: receives traffic from HEAD, forwards to Internet
# ============================================================

SCRIPT_NAME="tunnel-tail"
LOG_FILE="/root/${SCRIPT_NAME}.log"

# Rotate log: keep last run only
if [ -f "$LOG_FILE" ]; then
    mv "$LOG_FILE" "${LOG_FILE}.prev"
fi

exec > >(tee -a "$LOG_FILE") 2>&1

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Please run as root."
    exit 1
fi

echo "=================================================="
echo "[INFO] Starting TAIL setup script (Exit Node)..."
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "=================================================="

# ---- [1/7] Install packages ----
echo ""
echo "[1/7] Installing required packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard iptables iproute2

# ---- [2/7] Enable IPv4 forwarding ----
echo ""
echo "[2/7] Enabling IPv4 forwarding..."
if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.d/99-tail.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-tail.conf
    sysctl -p /etc/sysctl.d/99-tail.conf > /dev/null
fi
CURRENT_FWD=$(sysctl -n net.ipv4.ip_forward)
echo "[INFO] net.ipv4.ip_forward = $CURRENT_FWD"

# ---- [3/7] Generate/check WireGuard keys ----
echo ""
echo "[3/7] Checking/Generating WireGuard keys..."
mkdir -p /etc/wireguard
PRIV_KEY_FILE="/etc/wireguard/tail_private.key"
PUB_KEY_FILE="/etc/wireguard/tail_public.key"
if [ ! -f "$PRIV_KEY_FILE" ]; then
    echo "[INFO] Generating new WireGuard key pair..."
    wg genkey | tee "$PRIV_KEY_FILE" | wg pubkey > "$PUB_KEY_FILE"
    chmod 600 "$PRIV_KEY_FILE"
    echo "[INFO] Keys generated."
else
    echo "[INFO] Existing keys found, reusing."
fi
TAIL_PUB_KEY=$(cat "$PUB_KEY_FILE")

echo "--------------------------------------------------"
echo "[PROMPT] Public key of this TAIL server (copy to HEAD):"
echo -e "\e[32m$TAIL_PUB_KEY\e[0m"
echo "--------------------------------------------------"

read -rp "[PROMPT] Paste the public key of the HEAD server: " HEAD_PUB_KEY
if [ -z "$HEAD_PUB_KEY" ]; then echo "[ERROR] HEAD key cannot be empty."; exit 1; fi
echo "[INFO] HEAD public key received: ${HEAD_PUB_KEY:0:10}...${HEAD_PUB_KEY: -6}"

DEFAULT_PORT=51820
read -rp "[PROMPT] Enter WireGuard listen port [default: $DEFAULT_PORT]: " WG_PORT
WG_PORT=${WG_PORT:-$DEFAULT_PORT}

# ---- [4/7] Detect main interface ----
echo ""
echo "[4/7] Detecting network configuration..."
MAIN_IFACE=$(ip -4 route show default | awk '{print $5; exit}') || true
if [ -z "$MAIN_IFACE" ]; then echo "[ERROR] Main interface not found."; exit 1; fi
MAIN_IP=$(ip -4 addr show dev "$MAIN_IFACE" | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
echo "[INFO] Main interface: $MAIN_IFACE ($MAIN_IP)"

# ---- [5/7] Configure UFW ----
echo ""
echo "[5/7] Configuring UFW..."
UFW_ACTIVE=false
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    UFW_ACTIVE=true
    echo "[INFO] UFW is ACTIVE."
    echo "[INFO] Allowing WireGuard port $WG_PORT/udp..."
    ufw allow "$WG_PORT"/udp comment "WireGuard TAIL Tunnel" >/dev/null 2>&1 || true
    echo "[INFO] UFW rules reloaded."
    ufw reload >/dev/null 2>&1 || true
else
    echo "[INFO] UFW is not active. Skipping UFW configuration."
fi

# ---- [6/7] Generate wg0.conf ----
echo ""
echo "[6/7] Generating wg0.conf..."

# Backup existing config
if [ -f /etc/wireguard/wg0.conf ]; then
    cp /etc/wireguard/wg0.conf "/etc/wireguard/wg0.conf.bak.$(date +%Y%m%d%H%M%S)"
    echo "[INFO] Backed up existing wg0.conf."
fi

# CRITICAL: FORWARD rules — without them UFW (DEFAULT_FORWARD_POLICY="DROP")
# silently drops all forwarded traffic and clients lose internet.
#
# IMPORTANT: wg-quick executes each PostUp line via cmd "$value".
# This does NOT split on semicolons. We must use SEPARATE PostUp lines
# for each command. Multiple PostUp lines are supported (appended to array).
#
# Note: PostDown commands use "bash -c" wrapper because individual
# PostDown lines fail silently on error (wg-quick ignores them).
# Wrapping in bash -c gives us "|| true" error suppression.

cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.10.10.1/24
ListenPort = $WG_PORT
PrivateKey = $(cat "$PRIV_KEY_FILE")
MTU = 1280

# --- PostUp: FORWARD + NAT ---
# 1) Allow all traffic arriving from wg0 to be forwarded
# 2) Allow established/related return traffic back to wg0
# 3) Masquerade WireGuard subnet -> main interface (exit to Internet)
PostUp = iptables -I FORWARD -i wg0 -j ACCEPT
PostUp = iptables -I FORWARD -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o $MAIN_IFACE -j MASQUERADE

# --- PostDown: cleanup (mirror of PostUp) ---
PostDown = bash -c 'iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true'
PostDown = bash -c 'iptables -D FORWARD -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true'
PostDown = bash -c 'iptables -t nat -D POSTROUTING -s 10.10.10.0/24 -o $MAIN_IFACE -j MASQUERADE 2>/dev/null || true'

[Peer]
# HEAD Server (Input Node)
PublicKey = $HEAD_PUB_KEY
AllowedIPs = 10.10.10.2/32
EOF

chmod 600 /etc/wireguard/wg0.conf
echo "[INFO] wg0.conf written."

# ---- [7/7] Start and verify ----
echo ""
echo "[7/7] Starting WireGuard tunnel..."
systemctl daemon-reload
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

sleep 3

echo ""
echo "=== DIAGNOSTICS ==="
echo "--- WireGuard status ---"
wg show wg0 2>/dev/null || echo "[WARN] wg0 not responding"
echo ""
echo "--- iptables FORWARD chain (filter) ---"
iptables -L FORWARD -n -v --line-numbers 2>/dev/null | head -20
echo ""
echo "--- iptables nat POSTROUTING ---"
iptables -t nat -L POSTROUTING -n -v --line-numbers 2>/dev/null | head -20
echo ""
echo "--- Routing table ---"
ip route show
echo ""

HANDSHAKE=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}') || true
NOW=$(date +%s)

if [ -n "$HANDSHAKE" ] && [ $((NOW - HANDSHAKE)) -lt 180 ]; then
    AGE=$((NOW - HANDSHAKE))
    echo "=================================================="
    echo "[SUCCESS] Handshake verified! Tunnel is ACTIVE."
    echo "[SUCCESS] Handshake age: ${AGE}s"
    echo "=================================================="
    TUNNEL_STATUS="ACTIVE"
else
    echo "=================================================="
    echo "[WARN] No recent handshake. This is OK if HEAD is"
    echo "       not configured yet. Tunnel will activate when"
    echo "       HEAD connects."
    echo "=================================================="
    TUNNEL_STATUS="WAITING_FOR_HEAD"
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║         TAIL SERVER — CONFIGURATION SUMMARY         ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Date:       $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "║  Role:       TAIL (Exit Node)"
echo "║  Interface:  $MAIN_IFACE ($MAIN_IP)"
echo "║  WG Address: 10.10.10.1/24"
echo "║  WG Port:    $WG_PORT/udp"
echo "║  WG MTU:     1280"
echo "║  UFW:        $UFW_ACTIVE"
echo "║  Tunnel:     $TUNNEL_STATUS"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  TAIL Public Key (give to HEAD):"
echo "║  $TAIL_PUB_KEY"
echo "║  HEAD Public Key (received):"
echo "║  $HEAD_PUB_KEY"
echo "╚══════════════════════════════════════════════════════╝"