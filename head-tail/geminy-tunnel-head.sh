#!/bin/bash
set -euo pipefail

# --- Logging Setup ---
LOG_FILE="/root/tunnel-head.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "################################################"
echo "#      HEAD Server Setup (Input Node)          #"
echo "################################################"

# --- 1. Network Context Detection ---
NETWORK_CONFIG="/root/.network_config"
if [ -f "$NETWORK_CONFIG" ]; then
    echo "[INFO] Loading existing network configuration..."
    set +u; source "$NETWORK_CONFIG"; set -u
fi

# --- 2. Install Dependencies ---
echo "[INFO] Installing required packages..."
apt-get update -q
apt-get install -y wireguard iptables iproute2

# --- 3. WireGuard Key Management ---
mkdir -p /etc/wireguard/keys
chmod 700 /etc/wireguard/keys
if [ ! -f /etc/wireguard/keys/private ]; then
    echo "[INFO] Generating new WireGuard keys..."
    wg genkey | tee /etc/wireguard/keys/private | wg pubkey > /etc/wireguard/keys/public
fi
PRIVATE_KEY=$(cat /etc/wireguard/keys/private)
PUBLIC_KEY=$(cat /etc/wireguard/keys/public)

echo "------------------------------------------------"
echo -e "YOUR HEAD SERVER PUBLIC KEY:"
echo -e "\e[32m$PUBLIC_KEY\e[0m"
echo "------------------------------------------------"

# --- 4. Interactive Inputs ---
echo "[INPUT] Configuration required:"
read -p "Enter TAIL Server PUBLIC KEY: " TAIL_PUBKEY
read -p "Enter TAIL Server INBOUND IP (Endpoint): " TAIL_ENDPOINT
read -p "Enter TAIL Server WG Port [default: 51820]: " WG_PORT
WG_PORT=${WG_PORT:-51820}

# --- 5. Helper Script for Dynamic PBR (FIXED DETECTION) ---
echo "[INFO] Creating routing helper script..."
cat > /etc/wireguard/route-helper.sh << 'EOF'
#!/bin/bash
ACTION=$1
TABLE=200
GW="10.99.99.1"
DEV="wg0"

# Robust detection: Find all private IPv4 addresses (RFC1918) assigned to local interfaces
# It captures 10.x.x.x, 172.16-31.x.x, and 192.168.x.x
# Then it converts them to /24 subnets and excludes our tunnel (10.99.99.0)
SUBNETS=$(ip -4 addr show | grep -oP '(?<=inet\s)(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)[0-9\.]+' | cut -d. -f1-3 | sed 's/$/.0\/24/' | sort -u | grep -v "10.99.99")

if [ "$ACTION" == "up" ]; then
    # Ensure default route exists in table 200
    ip route add default via "$GW" dev "$DEV" table "$TABLE" 2>/dev/null || true
    
    if [ -z "$SUBNETS" ]; then
        echo "[WARNING] No private subnets detected. Is Amnezia running?"
    else
        for net in $SUBNETS; do
            echo "[INFO] Adding PBR rule for subnet: $net"
            ip rule add from "$net" table "$TABLE" 2>/dev/null || true
        done
    fi
elif [ "$ACTION" == "down" ]; then
    for net in $SUBNETS; do
        ip rule del from "$net" table "$TABLE" 2>/dev/null || true
    done
    ip route del default via "$GW" dev "$DEV" table "$TABLE" 2>/dev/null || true
    echo "[INFO] PBR rules removed."
fi
EOF
chmod +x /etc/wireguard/route-helper.sh

# --- 6. Routing Table Definition ---
if ! grep -q "200 wg-tunnel" /etc/iproute2/rt_tables; then
    echo "200 wg-tunnel" >> /etc/iproute2/rt_tables
fi

# --- 7. Generate Configuration ---
echo "[INFO] Generating /etc/wireguard/wg0.conf..."
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.99.99.2/24
PrivateKey = $PRIVATE_KEY
Table = off

# Use helper to manage PBR rules for VPN/Docker clients
PostUp = /etc/wireguard/route-helper.sh up
PostDown = /etc/wireguard/route-helper.sh down

# MASQUERADE ensures TAIL doesn't need to know internal subnets
PostUp = iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE

[Peer]
# TAIL Server
PublicKey = $TAIL_PUBKEY
Endpoint = $TAIL_ENDPOINT:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

# --- 8. Service Management ---
echo "[INFO] Enabling and starting WireGuard..."
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0 || systemctl start wg-quick@wg0

echo "################################################"
echo "# HEAD Setup Complete. Tunnel IP: 10.99.99.2   #"
echo "# All Amnezia/Docker traffic routed via TAIL.  #"
echo "################################################"