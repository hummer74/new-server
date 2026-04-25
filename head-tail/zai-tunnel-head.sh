#!/bin/bash
set -euo pipefail

# ============================================================
#  zai-tunnel-head.sh  —  HEAD (Input Node)
#  Receives Amnezia VPN clients, routes their traffic
#  through WireGuard tunnel to TAIL exit node.
# ============================================================

SCRIPT_NAME="tunnel-head"
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
echo "[INFO] Starting HEAD setup script (Input Node)..."
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "=================================================="

# ---- [1/7] Install packages ----
echo ""
echo "[1/7] Installing required packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard iptables iproute2 gawk

# ---- [2/7] Generate/check WireGuard keys ----
echo ""
echo "[2/7] Checking/Generating WireGuard keys..."
mkdir -p /etc/wireguard
PRIV_KEY_FILE="/etc/wireguard/head_private.key"
PUB_KEY_FILE="/etc/wireguard/head_public.key"
if [ ! -f "$PRIV_KEY_FILE" ]; then
    echo "[INFO] Generating new WireGuard key pair..."
    wg genkey | tee "$PRIV_KEY_FILE" | wg pubkey > "$PUB_KEY_FILE"
    chmod 600 "$PRIV_KEY_FILE"
    echo "[INFO] Keys generated."
else
    echo "[INFO] Existing keys found, reusing."
fi
HEAD_PUB_KEY=$(cat "$PUB_KEY_FILE")

echo "--------------------------------------------------"
echo "[PROMPT] Public key of this HEAD server (copy to TAIL):"
echo -e "\e[32m$HEAD_PUB_KEY\e[0m"
echo "--------------------------------------------------"

read -rp "[PROMPT] Enter the IP address of the TAIL server: " TAIL_IP
if [ -z "$TAIL_IP" ]; then echo "[ERROR] TAIL IP cannot be empty."; exit 1; fi
echo "[INFO] TAIL server IP: $TAIL_IP"

read -rp "[PROMPT] Paste the public key of the TAIL server: " TAIL_PUB_KEY
if [ -z "$TAIL_PUB_KEY" ]; then echo "[ERROR] TAIL key cannot be empty."; exit 1; fi
echo "[INFO] TAIL public key received: ${TAIL_PUB_KEY:0:10}...${TAIL_PUB_KEY: -6}"

DEFAULT_PORT=51820
read -rp "[PROMPT] Enter WireGuard port of TAIL server [default: $DEFAULT_PORT]: " WG_PORT
WG_PORT=${WG_PORT:-$DEFAULT_PORT}

# ---- [3/7] Configure routing table ----
echo ""
echo "[3/7] Configuring routing table..."
if ! grep -q "^200 tail_out" /etc/iproute2/rt_tables 2>/dev/null; then
    echo "200 tail_out" >> /etc/iproute2/rt_tables
    echo "[INFO] Added routing table 'tail_out' (id 200)."
else
    echo "[INFO] Routing table 'tail_out' already exists."
fi

# ---- [4/7] Generate wg-up.sh ----
echo ""
echo "[4/7] Generating dynamic routing hooks (fwmark)..."

# Backup existing hooks
for f in wg-up.sh wg-down.sh; do
    if [ -f "/etc/wireguard/$f" ]; then
        cp "/etc/wireguard/$f" "/etc/wireguard/${f}.bak.$(date +%Y%m%d%H%M%S)"
    fi
done

cat > /etc/wireguard/wg-up.sh << 'HOOK_EOF'
#!/bin/bash
# ============================================================
#  wg-up.sh — runs as PostUp when wg0 starts
#  Marks Docker/VPN subnet traffic for policy routing -> wg0
# ============================================================
TABLE="tail_out"
MARK="0x3"

echo "[wg-up] $(date '+%H:%M:%S') Starting routing hooks..."

# --- 1. Setup policy routing table ---
ip route flush table $TABLE 2>/dev/null || true
ip route add default via 10.10.10.1 dev wg0 table $TABLE
echo "[wg-up] Default route via 10.10.10.1 in table $TABLE"

# Remove old fwmark rules safely
while ip rule show | grep -q "fwmark $MARK"; do
    ip rule del fwmark $MARK 2>/dev/null || true
done
ip rule add fwmark $MARK lookup $TABLE priority 1000
echo "[wg-up] Policy rule: fwmark $MARK -> table $TABLE (priority 1000)"

# --- 2. Detect subnets (preserve actual CIDR, NOT forced /24) ---
# Match private-range addresses, exclude WireGuard tunnel (10.10.10.x)
# Output: real CIDR like 172.17.0.1/16, 172.29.172.1/24, 10.8.0.1/24
SUBNETS=$(ip -4 addr show | awk '/inet / {print $2}' | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)' | grep -v "10\.10\.10\." | sort -u)

if [ -z "$SUBNETS" ]; then
    echo "[wg-up] WARNING: No private-range subnets detected!"
    echo "[wg-up] If Docker/Amnezia is not running yet, restart wg0 after starting them:"
    echo "[wg-up]   systemctl restart wg-quick@wg0"
fi

# --- 3. Apply mangle + nat rules for each detected subnet ---
COUNT=0
for entry in $SUBNETS; do
    COUNT=$((COUNT + 1))

    # Exclude traffic destined for private/local networks from marking
    # (Docker internal, LAN, WireGuard management, link-local)
    iptables -t mangle -A PREROUTING -s "$entry" -d 127.0.0.0/8       -j RETURN
    iptables -t mangle -A PREROUTING -s "$entry" -d 169.254.0.0/16    -j RETURN
    iptables -t mangle -A PREROUTING -s "$entry" -d 10.0.0.0/8        -j RETURN
    iptables -t mangle -A PREROUTING -s "$entry" -d 172.16.0.0/12     -j RETURN
    iptables -t mangle -A PREROUTING -s "$entry" -d 192.168.0.0/16    -j RETURN

    # Mark remaining traffic (Internet-bound) with fwmark 0x3
    iptables -t mangle -A PREROUTING -s "$entry" -j MARK --set-mark $MARK

    # Masquerade so TAIL sees traffic from WG IP (10.10.10.2), not Docker IP
    iptables -t nat -A POSTROUTING -s "$entry" -o wg0 -j MASQUERADE

    echo "[wg-up] Subnet #$COUNT: $entry -- marked + masqueraded"
done

# --- 4. Allow forwarded traffic through wg0 ---
# (Docker handles docker0<->eth0; we handle wg0 explicitly)
iptables -I FORWARD -i wg0 -j ACCEPT
iptables -I FORWARD -o wg0 -j ACCEPT
echo "[wg-up] FORWARD rules: allow traffic via wg0"

echo "[wg-up] Done. $COUNT subnet(s) configured."
HOOK_EOF

# ---- [5/7] Generate wg-down.sh ----
cat > /etc/wireguard/wg-down.sh << 'HOOK_EOF'
#!/bin/bash
# ============================================================
#  wg-down.sh — runs as PostDown when wg0 stops
#  Reverses ALL rules added by wg-up.sh
# ============================================================
TABLE="tail_out"
MARK="0x3"

echo "[wg-down] $(date '+%H:%M:%S') Cleaning up routing hooks..."

# Detect same subnets (must match wg-up.sh logic)
SUBNETS=$(ip -4 addr show | awk '/inet / {print $2}' | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)' | grep -v "10\.10\.10\." | sort -u)

# Remove mangle PREROUTING rules (in reverse order)
for entry in $SUBNETS; do
    iptables -t mangle -D PREROUTING -s "$entry" -j MARK --set-mark $MARK        2>/dev/null || true
    iptables -t mangle -D PREROUTING -s "$entry" -d 192.168.0.0/16    -j RETURN 2>/dev/null || true
    iptables -t mangle -D PREROUTING -s "$entry" -d 172.16.0.0/12     -j RETURN 2>/dev/null || true
    iptables -t mangle -D PREROUTING -s "$entry" -d 10.0.0.0/8        -j RETURN 2>/dev/null || true
    iptables -t mangle -D PREROUTING -s "$entry" -d 169.254.0.0/16    -j RETURN 2>/dev/null || true
    iptables -t mangle -D PREROUTING -s "$entry" -d 127.0.0.0/8       -j RETURN 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "$entry" -o wg0 -j MASQUERADE    2>/dev/null || true
done

# Remove FORWARD rules
iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null || true

# Remove policy routing rule
while ip rule show | grep -q "fwmark $MARK"; do
    ip rule del fwmark $MARK 2>/dev/null || true
done
ip route flush table $TABLE 2>/dev/null || true

echo "[wg-down] Cleanup done."
HOOK_EOF

chmod +x /etc/wireguard/wg-up.sh /etc/wireguard/wg-down.sh
echo "[INFO] Hooks written: /etc/wireguard/wg-up.sh, wg-down.sh"

# ---- [6/7] Generate wg0.conf ----
echo ""
echo "[6/7] Generating wg0.conf..."

# Backup existing config
if [ -f /etc/wireguard/wg0.conf ]; then
    cp /etc/wireguard/wg0.conf "/etc/wireguard/wg0.conf.bak.$(date +%Y%m%d%H%M%S)"
    echo "[INFO] Backed up existing wg0.conf."
fi

cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.10.10.2/24
PrivateKey = $(cat "$PRIV_KEY_FILE")
# CRITICAL: Do NOT hijack main routing table.
# Only fwmark-marked packets use the tunnel (via wg-up.sh).
Table = off
MTU = 1280

PostUp = /etc/wireguard/wg-up.sh
PostDown = /etc/wireguard/wg-down.sh

[Peer]
# TAIL Server (Exit Node)
PublicKey = $TAIL_PUB_KEY
Endpoint = $TAIL_IP:$WG_PORT
# CRITICAL: AllowedIPs = 0.0.0.0/0 is the crypto-key routing directive,
# NOT the routing table directive. With Table = off, wg-quick will NOT
# add any routes to the main table. Routing is controlled by fwmark.
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

chmod 600 /etc/wireguard/wg0.conf
echo "[INFO] wg0.conf written."

# ---- [7/7] Start and verify ----
echo ""
echo "[7/7] Starting WireGuard tunnel..."
systemctl daemon-reload
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

echo "[INFO] Waiting 5 seconds for handshake verification..."
sleep 5

echo ""
echo "=== DIAGNOSTICS ==="
echo "--- WireGuard status ---"
wg show wg0 2>/dev/null || echo "[WARN] wg0 not responding"
echo ""
echo "--- Policy routing rules ---"
ip rule show | grep -E "fwmark|lookup" || echo "[WARN] No fwmark rules found"
echo ""
echo "--- Routing table 200 (tail_out) ---"
ip route show table tail_out 2>/dev/null || echo "[WARN] Table 200 empty or missing"
echo ""
echo "--- mangle PREROUTING (fwmark rules) ---"
iptables -t mangle -L PREROUTING -n -v --line-numbers 2>/dev/null | head -30
echo ""
echo "--- nat POSTROUTING (masquerade) ---"
iptables -t nat -L POSTROUTING -n -v --line-numbers 2>/dev/null | head -20
echo ""
echo "--- Detected private subnets ---"
ip -4 addr show | awk '/inet / {print $2}' | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)' | grep -v "10\.10\.10\." | sort -u || echo "[WARN] No private subnets found"
echo ""

HANDSHAKE=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}') || true
NOW=$(date +%s)

if [ -n "$HANDSHAKE" ] && [ $((NOW - HANDSHAKE)) -lt 120 ]; then
    AGE=$((NOW - HANDSHAKE))
    echo "=================================================="
    echo "[SUCCESS] Handshake verified! Tunnel is ACTIVE."
    echo "[SUCCESS] Handshake age: ${AGE}s"
    echo "=================================================="
    TUNNEL_STATUS="ACTIVE"
else
    echo "=================================================="
    echo "[ERROR] Handshake FAILED."
    echo "        Check:"
    echo "          1. Keys match between HEAD and TAIL"
    echo "          2. TAIL IP is reachable: $TAIL_IP"
    echo "          3. TAIL firewall allows UDP $WG_PORT"
    echo "          4. TAIL wg-quick@wg0 is running"
    echo "        Shutting down tunnel to prevent issues."
    echo "=================================================="
    systemctl stop wg-quick@wg0
    TUNNEL_STATUS="FAILED"
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║         HEAD SERVER — CONFIGURATION SUMMARY         ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Date:       $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "║  Role:       HEAD (Input Node)"
echo "║  WG Address: 10.10.10.2/24"
echo "║  WG MTU:     1280"
echo "║  TAIL IP:    $TAIL_IP"
echo "║  TAIL Port:  $WG_PORT/udp"
echo "║  Tunnel:     $TUNNEL_STATUS"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  HEAD Public Key (give to TAIL):"
echo "║  $HEAD_PUB_KEY"
echo "║  TAIL Public Key (received):"
echo "║  $TAIL_PUB_KEY"
echo "╚══════════════════════════════════════════════════════╝"