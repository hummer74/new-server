#!/bin/bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0" .sh)
LOG_FILE="/root/${SCRIPT_NAME}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Please run as root (sudo)."
    exit 1
fi

echo "=================================================="
echo "[INFO] Starting HEAD setup script..."
echo "=================================================="

echo "[1/6] Installing required packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard iptables

echo "[2/6] Checking/Generating WireGuard keys..."
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
if [ -z "$TAIL_IP" ]; then echo "[ERROR] TAIL IP cannot be empty."; exit 1; fi

read -rp "[PROMPT] Paste the public key of the TAIL server: " TAIL_PUB_KEY
if [ -z "$TAIL_PUB_KEY" ]; then echo "[ERROR] TAIL key cannot be empty."; exit 1; fi

DEFAULT_PORT=51820
read -rp "[PROMPT] Enter WireGuard port of TAIL server [default: $DEFAULT_PORT]: " WG_PORT
WG_PORT=${WG_PORT:-$DEFAULT_PORT}

echo "[3/6] Auto-detecting Docker parameters..."
MAIN_IFACE=$(ip -4 route show default | awk '{print $5; exit}') || true
if [ -z "$MAIN_IFACE" ]; then echo "[ERROR] Main interface not found."; exit 1; fi

AMN_IFACE="amn0"
if ip -br link show "$AMN_IFACE" &>/dev/null; then
    DOCKER_NET=$(ip -4 addr show "$AMN_IFACE" | awk '$1 == "inet" {print $2}')
    echo "[INFO] Found Amnezia Docker interface: $AMN_IFACE ($DOCKER_NET)"
else
    echo "[ERROR] Docker interface $AMN_IFACE not found."
    exit 1
fi

read -rp "[PROMPT] Enter Xray listening port [default: 443]: " XRAY_PORT
XRAY_PORT=${XRAY_PORT:-443}

echo "[4/6] Configuring routing table..."
if ! grep -q "^200 tail_out" /etc/iproute2/rt_tables 2>/dev/null; then
    echo "200 tail_out" >> /etc/iproute2/rt_tables
fi

echo "[5/6] Generating routing hooks..."
cat > /etc/wireguard/wg-up.sh << EOF
#!/bin/bash
XRAY_PORT=$XRAY_PORT
DOCKER_NET="$DOCKER_NET"

ip route flush table tail_out 2>/dev/null || true
ip rule del pref 10 2>/dev/null || true
ip rule del pref 15 2>/dev/null || true
ip rule del pref 30 2>/dev/null || true
iptables -t mangle -D PREROUTING -i $AMN_IFACE -p tcp --sport \$XRAY_PORT -j RETURN 2>/dev/null || true
iptables -t mangle -D PREROUTING -i $AMN_IFACE -d 127.0.0.0/8 -j RETURN 2>/dev/null || true
iptables -t mangle -D PREROUTING -i $AMN_IFACE -d 172.16.0.0/12 -j RETURN 2>/dev/null || true
iptables -t mangle -D PREROUTING -i $AMN_IFACE -d 10.0.0.0/8 -j RETURN 2>/dev/null || true
iptables -t mangle -D PREROUTING -i $AMN_IFACE -d 192.168.0.0/16 -j RETURN 2>/dev/null || true
iptables -t mangle -D PREROUTING -i $AMN_IFACE -j MARK --set-mark 0x3 2>/dev/null || true
iptables -t nat -D POSTROUTING -s \$DOCKER_NET -o wg0 -j MASQUERADE 2>/dev/null || true

ip route add 10.10.10.0/24 dev wg0 src 10.10.10.2 table tail_out
ip route add default via 10.10.10.1 table tail_out

ip rule add pref 10 from 10.10.10.2 lookup main
ip rule add pref 15 to \$DOCKER_NET lookup main
ip rule add pref 30 fwmark 0x3 lookup tail_out

iptables -t mangle -A PREROUTING -i $AMN_IFACE -p tcp --sport \$XRAY_PORT -j RETURN
iptables -t mangle -A PREROUTING -i $AMN_IFACE -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A PREROUTING -i $AMN_IFACE -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A PREROUTING -i $AMN_IFACE -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A PREROUTING -i $AMN_IFACE -d 192.168.0.0/16 -j RETURN
iptables -t mangle -A PREROUTING -i $AMN_IFACE -j MARK --set-mark 0x3

iptables -t nat -A POSTROUTING -s \$DOCKER_NET -o wg0 -j MASQUERADE
EOF

cat > /etc/wireguard/wg-down.sh << EOF
#!/bin/bash
XRAY_PORT=$XRAY_PORT
DOCKER_NET="$DOCKER_NET"

ip rule del pref 10 2>/dev/null || true
ip rule del pref 15 2>/dev/null || true
ip rule del pref 30 2>/dev/null || true
ip route flush table tail_out 2>/dev/null || true
iptables -t mangle -D PREROUTING -i $AMN_IFACE -p tcp --sport \$XRAY_PORT -j RETURN 2>/dev/null || true
iptables -t mangle -D PREROUTING -i $AMN_IFACE -d 127.0.0.0/8 -j RETURN 2>/dev/null || true
iptables -t mangle -D PREROUTING -i $AMN_IFACE -d 172.16.0.0/12 -j RETURN 2>/dev/null || true
iptables -t mangle -D PREROUTING -i $AMN_IFACE -d 10.0.0.0/8 -j RETURN 2>/dev/null || true
iptables -t mangle -D PREROUTING -i $AMN_IFACE -d 192.168.0.0/16 -j RETURN 2>/dev/null || true
iptables -t mangle -D PREROUTING -i $AMN_IFACE -j MARK --set-mark 0x3 2>/dev/null || true
iptables -t nat -D POSTROUTING -s \$DOCKER_NET -o wg0 -j MASQUERADE 2>/dev/null || true
EOF

chmod +x /etc/wireguard/wg-up.sh /etc/wireguard/wg-down.sh

echo "[6/6] Generating wg0.conf..."
# КРИТИЧЕСКОЕ ИЗМЕНЕНИЕ: AllowedIPs разрешает отправку ЛЮБОГО трафика, 
# кроме самого IP TAIL (чтобы не сломать keepalive туннеля).
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.10.10.2/24
PrivateKey = $(cat "$PRIV_KEY_FILE")
PostUp = /etc/wireguard/wg-up.sh
PostDown = /etc/wireguard/wg-down.sh

[Peer]
PublicKey = $TAIL_PUB_KEY
Endpoint = $TAIL_IP:$WG_PORT
AllowedIPs = 0.0.0.0/0, !$TAIL_IP/32
PersistentKeepalive = 25
EOF

echo "[INFO] Starting WireGuard tunnel..."
systemctl daemon-reload
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

echo "[INFO] Waiting 5 seconds for handshake..."
sleep 5

HANDSHAKE=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}') || true
NOW=$(date +%s)

if [ -n "$HANDSHAKE" ] && [ $((NOW - HANDSHAKE)) -lt 120 ]; then
    echo "[SUCCESS] Handshake received."
else
    echo "[ERROR] Handshake FAILED."
    systemctl stop wg-quick@wg0
    exit 1
fi

echo "=================================================="
echo "[SUCCESS] HEAD setup completed."
echo "=================================================="