#!/bin/bash
set -euo pipefail

SCRIPT_NAME="tunnel-head"
LOG_FILE="/root/${SCRIPT_NAME}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Please run as root."
    exit 1
fi

echo "=================================================="
echo "[INFO] Starting HEAD setup script (Input Node)..."
echo "=================================================="

echo "[1/6] Installing required packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard iptables iproute2 gawk

echo "[2/6] Checking/Generating WireGuard keys..."
mkdir -p /etc/wireguard
PRIV_KEY_FILE="/etc/wireguard/head_private.key"
PUB_KEY_FILE="/etc/wireguard/head_public.key"
if [ ! -f "$PRIV_KEY_FILE" ]; then
    wg genkey | tee "$PRIV_KEY_FILE" | wg pubkey > "$PUB_KEY_FILE"
    chmod 600 "$PRIV_KEY_FILE"
fi
HEAD_PUB_KEY=$(cat "$PUB_KEY_FILE")

echo "--------------------------------------------------"
echo "[PROMPT] Public key of this HEAD server (copy to TAIL):"
echo -e "\e[32m$HEAD_PUB_KEY\e[0m"
echo "--------------------------------------------------"

read -rp "[PROMPT] Enter the IP address of the TAIL server: " TAIL_IP
if [ -z "$TAIL_IP" ]; then echo "[ERROR] TAIL IP cannot be empty."; exit 1; fi

read -rp "[PROMPT] Paste the public key of the TAIL server: " TAIL_PUB_KEY
if [ -z "$TAIL_PUB_KEY" ]; then echo "[ERROR] TAIL key cannot be empty."; exit 1; fi

DEFAULT_PORT=51820
read -rp "[PROMPT] Enter WireGuard port of TAIL server [default: $DEFAULT_PORT]: " WG_PORT
WG_PORT=${WG_PORT:-$DEFAULT_PORT}

echo "[3/6] Configuring routing table..."
if ! grep -q "^200 tail_out" /etc/iproute2/rt_tables 2>/dev/null; then
    echo "200 tail_out" >> /etc/iproute2/rt_tables
fi

echo "[4/6] Generating dynamic routing hooks (fwmark)..."
# --- UP HOOK ---
cat > /etc/wireguard/wg-up.sh << 'EOF'
#!/bin/bash
TABLE="tail_out"
MARK="0x3"

# Clean table and add default route via tunnel
ip route flush table $TABLE 2>/dev/null || true
ip route add default via 10.10.10.1 dev wg0 table $TABLE

# Remove old rules safely
while ip rule show | grep -q "fwmark $MARK"; do ip rule del fwmark $MARK 2>/dev/null || true; done

# Add fwmark rule: Marked packets go to table 200
ip rule add fwmark $MARK lookup $TABLE priority 1000

# Dynamically find VPN subnets (Amnezia/Docker) at runtime
SUBNETS=$(ip -4 addr show | awk '/inet / {print $2}' | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)' | grep -v "10.10.10" | cut -d/ -f1 | cut -d. -f1-3 | sed 's/$/.0\/24/' | sort -u)

for net in $SUBNETS; do
    echo "[INFO] Applying fwmark rules for subnet: $net"
    # Exclude local traffic from marking (allow internal server communication)
    iptables -t mangle -A PREROUTING -s "$net" -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A PREROUTING -s "$net" -d 10.0.0.0/8 -j RETURN
    iptables -t mangle -A PREROUTING -s "$net" -d 172.16.0.0/12 -j RETURN
    iptables -t mangle -A PREROUTING -s "$net" -d 192.168.0.0/16 -j RETURN
    
    # Mark the remaining traffic (Internet bound)
    iptables -t mangle -A PREROUTING -s "$net" -j MARK --set-mark $MARK
    
    # Masquerade so TAIL server only sees the WG IP
    iptables -t nat -A POSTROUTING -s "$net" -o wg0 -j MASQUERADE
done
EOF

# --- DOWN HOOK ---
cat > /etc/wireguard/wg-down.sh << 'EOF'
#!/bin/bash
TABLE="tail_out"
MARK="0x3"

SUBNETS=$(ip -4 addr show | awk '/inet / {print $2}' | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)' | grep -v "10.10.10" | cut -d/ -f1 | cut -d. -f1-3 | sed 's/$/.0\/24/' | sort -u)

for net in $SUBNETS; do
    # Remove all added rules silently
    iptables -t mangle -D PREROUTING -s "$net" -d 127.0.0.0/8 -j RETURN 2>/dev/null || true
    iptables -t mangle -D PREROUTING -s "$net" -d 10.0.0.0/8 -j RETURN 2>/dev/null || true
    iptables -t mangle -D PREROUTING -s "$net" -d 172.16.0.0/12 -j RETURN 2>/dev/null || true
    iptables -t mangle -D PREROUTING -s "$net" -d 192.168.0.0/16 -j RETURN 2>/dev/null || true
    iptables -t mangle -D PREROUTING -s "$net" -j MARK --set-mark $MARK 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "$net" -o wg0 -j MASQUERADE 2>/dev/null || true
done

while ip rule show | grep -q "fwmark $MARK"; do ip rule del fwmark $MARK 2>/dev/null || true; done
ip route flush table $TABLE 2>/dev/null || true
EOF

chmod +x /etc/wireguard/wg-up.sh /etc/wireguard/wg-down.sh

echo "[5/6] Generating wg0.conf..."
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.10.10.2/24
PrivateKey = $(cat "$PRIV_KEY_FILE")
# CRITICAL: Do not hijack main routing table
Table = off

PostUp = /etc/wireguard/wg-up.sh
PostDown = /etc/wireguard/wg-down.sh

[Peer]
# TAIL Server
PublicKey = $TAIL_PUB_KEY
Endpoint = $TAIL_IP:$WG_PORT
# CRITICAL: Allow all IPs, routing is handled by fwmark
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

echo "[6/6] Starting WireGuard tunnel..."
systemctl daemon-reload
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

echo "[INFO] Waiting 5 seconds for handshake verification..."
sleep 5

HANDSHAKE=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}') || true
NOW=$(date +%s)

if [ -n "$HANDSHAKE" ] && [ $((NOW - HANDSHAKE)) -lt 120 ]; then
    echo "=================================================="
    echo "[SUCCESS] Handshake verified! Tunnel is ACTIVE."
    echo "[SUCCESS] HEAD setup completed."
    echo "=================================================="
else
    echo "=================================================="
    echo "[ERROR] Handshake FAILED."
    echo "        Check keys, TAIL IP, and TAIL Firewall."
    echo "        Shutting down tunnel to prevent issues."
    echo "=================================================="
    systemctl stop wg-quick@wg0
    exit 1
fi