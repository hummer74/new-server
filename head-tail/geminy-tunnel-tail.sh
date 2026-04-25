#!/bin/bash
set -euo pipefail

# --- Logging Setup ---
LOG_FILE="/root/tunnel-tail.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "################################################"
echo "#      TAIL Server Setup (Exit Node)           #"
echo "################################################"

# --- 1. Network Context Detection ---
NETWORK_CONFIG="/root/.network_config"
INBOUND_IP=$(ip -4 addr show | grep inet | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -n1)
OUTBOUND_IP=$INBOUND_IP

if [ -f "$NETWORK_CONFIG" ]; then
    echo "[INFO] Loading existing network configuration..."
    # Source without set -u because config might have undefined vars
    set +u; source "$NETWORK_CONFIG"; set -u
fi

echo "[INFO] Network detection: Inbound=$INBOUND_IP, Outbound=$OUTBOUND_IP"

# --- 2. Install Dependencies ---
echo "[INFO] Installing required packages..."
apt-get update -q
apt-get install -y wireguard iptables ufw resolvconf iproute2

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
echo -e "YOUR TAIL SERVER PUBLIC KEY:"
echo -e "\e[32m$PUBLIC_KEY\e[0m"
echo "------------------------------------------------"

# --- 4. Interactive Inputs ---
echo "[INPUT] Configuration required:"
read -p "Enter HEAD Server PUBLIC KEY (or leave empty to edit later): " HEAD_PUBKEY
read -p "Enter WG Listen Port [default: 51820]: " WG_PORT
WG_PORT=${WG_PORT:-51820}

# --- 5. System Networking Setup ---
echo "[INFO] Enabling IPv4 Forwarding..."
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wg-forward.conf
sysctl --system >/dev/null

# --- 6. Generate Configuration ---
echo "[INFO] Generating /etc/wireguard/wg0.conf..."
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.99.99.1/24
ListenPort = $WG_PORT
PrivateKey = $PRIVATE_KEY

# Routing: SNAT all traffic from tunnel to the Outbound IP
PostUp = iptables -t nat -A POSTROUTING -s 10.99.99.0/24 -j SNAT --to-source $OUTBOUND_IP
PostDown = iptables -t nat -D POSTROUTING -s 10.99.99.0/24 -j SNAT --to-source $OUTBOUND_IP

[Peer]
# HEAD Server
PublicKey = ${HEAD_PUBKEY:-INSERT_HEAD_PUBKEY_HERE}
AllowedIPs = 10.99.99.2/32
EOF

# --- 7. Firewall Configuration ---
if ufw status | grep -q "Status: active"; then
    echo "[INFO] Updating UFW rules..."
    # Allow WG port on Inbound IP specifically if split network is used
    ufw allow proto udp to "$INBOUND_IP" port "$WG_PORT" comment 'WireGuard Tunnel'
    ufw reload >/dev/null
fi

# --- 8. Service Management ---
echo "[INFO] Enabling and starting WireGuard..."
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0 || systemctl start wg-quick@wg0

echo "################################################"
echo "# TAIL Setup Complete. Tunnel IP: 10.99.99.1   #"
echo "################################################"