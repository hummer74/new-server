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
echo "[INFO] Starting HEAD setup script..."
echo "=================================================="

# --- 1. Install packages ---
echo "[1/8] Installing required packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard iptables

# --- 2. Generate Keys (Idempotent) ---
echo "[2/8] Checking/Generating WireGuard keys..."
PRIV_KEY_FILE="/etc/wireguard/head_private.key"
PUB_KEY_FILE="/etc/wireguard/head_public.key"
if [ ! -f "$PRIV_KEY_FILE" ]; then
    wg genkey | tee "$PRIV_KEY_FILE" | wg pubkey > "$PUB_KEY_FILE"
    chmod 600 "$PRIV_KEY_FILE"
fi
HEAD_PUB_KEY=$(cat "$PUB_KEY_FILE")

echo "--------------------------------------------------"
echo "[PROMPT] Public key of this HEAD server (copy to TAIL):"
echo "$HEAD_PUB_KEY"
echo "--------------------------------------------------"

read -rp "[PROMPT] Enter the IP address of the TAIL server: " TAIL_IP
if [ -z "$TAIL_IP" ]; then
    echo "[ERROR] TAIL IP address cannot be empty."
    exit 1
fi

read -rp "[PROMPT] Paste the public key of the TAIL server: " TAIL_PUB_KEY
if [ -z "$TAIL_PUB_KEY" ]; then
    echo "[ERROR] TAIL public key cannot be empty."
    exit 1
fi

DEFAULT_PORT=51820
read -rp "[PROMPT] Enter WireGuard port of TAIL server [default: $DEFAULT_PORT]: " WG_PORT
WG_PORT=${WG_PORT:-$DEFAULT_PORT}

# --- 3. System Auto-Discovery ---
echo "[3/8] Auto-detecting system parameters..."

MAIN_IFACE=$(ip -4 route show default | awk '{print $5; exit}') || true
if [ -z "$MAIN_IFACE" ]; then
    echo "[ERROR] Failed to detect the main network interface."
    exit 1
fi

# Detect SSH port safely (fallback to 22)
SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | rev | cut -d: -f1 | rev | head -n 1) || true
if [ -z "$SSH_PORT" ]; then
    SSH_PORT=22
fi
echo "[INFO] Detected/Sets SSH port to: $SSH_PORT"

# Detect AmneziaWG interface (Broader search, non-fatal)
AWG_IFACE=$(ip -br link show 2>/dev/null | grep -iE 'awg|amneziawg' | awk '{print $1; exit}') || true
if [ -n "$AWG_IFACE" ]; then
    echo "[INFO] Found AmneziaWG interface: $AWG_IFACE"
else
    echo "[WARN] AmneziaWG interface not found via standard names."
fi

echo "[INFO] Proceeding with universal Catch-All routing (Rule 40). This will route ANY outbound traffic from this server to TAIL."

# --- 4. Setup Routing Table ---
echo "[4/8] Configuring routing table..."
if ! grep -q "^200 tail_out" /etc/iproute2/rt_tables 2>/dev/null; then
    echo "200 tail_out" >> /etc/iproute2/rt_tables
fi

# --- 5. Generate Routing Hooks ---
echo "[5/8] Generating OS-level routing hooks..."
cat > /etc/wireguard/wg-up.sh << 'EOF_BASE_HOOK'
#!/bin/bash
ip route flush table tail_out 2>/dev/null || true
ip rule del pref 10 2>/dev/null || true
ip rule del pref 20 2>/dev/null || true
ip rule del pref 30 2>/dev/null || true
ip rule del pref 40 2>/dev/null || true
iptables -t mangle -D OUTPUT -j TAIL_MARK 2>/dev/null || true
iptables -t mangle -F TAIL_MARK 2>/dev/null || true
iptables -t mangle -X TAIL_MARK 2>/dev/null || true

ip route add 10.10.10.0/24 dev wg0 src 10.10.10.2 table tail_out
ip route add default via 10.10.10.1 table tail_out

# pref 10: Protect tunnel response traffic
ip rule add pref 10 from 10.10.10.2 lookup main
# pref 20: Exceptions (marked 0x2 go to main)
ip rule add pref 20 fwmark 0x2 lookup main
EOF_BASE_HOOK

# Dynamically add AWG rule if detected
if [ -n "$AWG_IFACE" ]; then
    echo "ip rule add pref 30 iif $AWG_IFACE lookup tail_out" >> /etc/wireguard/wg-up.sh
fi

cat >> /etc/wireguard/wg-up.sh << EOF_EXCL_HOOK
# pref 40: Catch-all (local server traffic, including Xray, goes to tail_out)
ip rule add pref 40 lookup tail_out

iptables -t mangle -N TAIL_MARK
# Protect SSH: mark BOTH outgoing connections (--dport) AND responses to incoming connections (--sport)
iptables -t mangle -A TAIL_MARK -p tcp --dport $SSH_PORT -j MARK --set-mark 0x2
iptables -t mangle -A TAIL_MARK -p tcp --sport $SSH_PORT -j MARK --set-mark 0x2
# Protect DNS: mark queries and responses
iptables -t mangle -A TAIL_MARK -p udp --dport 53 -j MARK --set-mark 0x2
iptables -t mangle -A TAIL_MARK -p udp --sport 53 -j MARK --set-mark 0x2
iptables -t mangle -A TAIL_MARK -p tcp --dport 53 -j MARK --set-mark 0x2
iptables -t mangle -A TAIL_MARK -p tcp --sport 53 -j MARK --set-mark 0x2
# Protect the WireGuard tunnel itself
iptables -t mangle -A TAIL_MARK -o $MAIN_IFACE -d $TAIL_IP -p udp --dport $WG_PORT -j MARK --set-mark 0x2
iptables -t mangle -A OUTPUT -j TAIL_MARK
EOF_EXCL_HOOK

cat > /etc/wireguard/wg-down.sh << 'EOF_DOWN_HOOK'
#!/bin/bash
ip rule del pref 10 2>/dev/null || true
ip rule del pref 20 2>/dev/null || true
ip rule del pref 30 2>/dev/null || true
ip rule del pref 40 2>/dev/null || true
ip route flush table tail_out 2>/dev/null || true
iptables -t mangle -D OUTPUT -j TAIL_MARK 2>/dev/null || true
iptables -t mangle -F TAIL_MARK 2>/dev/null || true
iptables -t mangle -X TAIL_MARK 2>/dev/null || true
EOF_DOWN_HOOK

chmod +x /etc/wireguard/wg-up.sh /etc/wireguard/wg-down.sh

# --- 6. Generate WG Config ---
echo "[6/8] Generating wg0.conf..."
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.10.10.2/24
PrivateKey = $(cat "$PRIV_KEY_FILE")
PostUp = /etc/wireguard/wg-up.sh
PostDown = /etc/wireguard/wg-down.sh

[Peer]
PublicKey = $TAIL_PUB_KEY
Endpoint = $TAIL_IP:$WG_PORT
AllowedIPs = 10.10.10.1/32
PersistentKeepalive = 25
EOF

# --- 7. Start and Verify Tunnel ---
echo "[7/8] Starting WireGuard tunnel..."
systemctl daemon-reload
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

echo "[INFO] Waiting 5 seconds for cryptographic handshake..."
sleep 5

HANDSHAKE=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}') || true
NOW=$(date +%s)

if [ -n "$HANDSHAKE" ] && [ $((NOW - HANDSHAKE)) -lt 120 ]; then
    echo "[SUCCESS] WireGuard Handshake received successfully."
else
    echo "[ERROR] Handshake FAILED."
    echo "[DEBUG] Possible causes:"
    echo "  1. Incorrect TAIL IP address."
    echo "  2. Public keys do not match."
    echo "  3. Port $WG_PORT is blocked by TAIL firewall."
    systemctl stop wg-quick@wg0
    exit 1
fi

# --- 8. Final ---
echo "[8/8] Setup finalized."
echo "=================================================="
echo "[SUCCESS] HEAD server setup completed successfully."
echo "[INFO] Universal Catch-All routing applied. All outbound traffic will go to TAIL."
echo "=================================================="