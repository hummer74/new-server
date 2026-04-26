#!/bin/bash
set -euo pipefail

LOG="/root/tunnel-tail.log"

log() {
    echo "$1" | tee -a "$LOG"
}

# --- Banner ---
cat << 'BANNER' | tee -a "$LOG"

============================================================
  zai-tunnel-tail.sh v3 — TAIL (Exit Node)
  WireGuard tunnel endpoint with Outbound IP NAT
============================================================
BANNER
log "[INFO] $(date '+%Y-%m-%d %H:%M:%S %Z')"

# ----------------------------------------------------------
[1/8] Installing required packages...
# ----------------------------------------------------------
if ! command -v wg &>/dev/null; then
    log "[INFO] Installing WireGuard..."
    apt-get update -qq && apt-get install -y -qq wireguard wireguard-tools
    log "[INFO] WireGuard installed."
else
    log "[INFO] WireGuard already installed."
fi

# ----------------------------------------------------------
[2/8] Enabling IPv4 forwarding...
# ----------------------------------------------------------
if [ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]; then
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/99-tunnel.conf
    sysctl -p /etc/sysctl.d/99-tunnel.conf >/dev/null
    log "[INFO] net.ipv4.ip_forward = 1"
else
    log "[INFO] net.ipv4.ip_forward already enabled."
fi

# ----------------------------------------------------------
[3/8] Checking/Generating WireGuard keys...
# ----------------------------------------------------------
WG_DIR="/etc/wireguard"
mkdir -p "$WG_DIR"

if [ ! -f "$WG_DIR/tail_private" ] || [ ! -f "$WG_DIR/tail_public" ]; then
    log "[INFO] Generating new WireGuard key pair..."
    wg genkey > "$WG_DIR/tail_private" 2>/dev/null
    wg pubkey < "$WG_DIR/tail_private" > "$WG_DIR/tail_public" 2>/dev/null
    chmod 600 "$WG_DIR/tail_private"
    log "[INFO] Keys generated."
else
    log "[INFO] Existing keys found. Reusing."
fi

TAIL_PRIVKEY=$(cat "$WG_DIR/tail_private")
TAIL_PUBKEY=$(cat "$WG_DIR/tail_public")

echo "--------------------------------------------------" | tee -a "$LOG"
log "[PROMPT] Public key of this TAIL server (copy to HEAD):"
log "[PROMPT] $TAIL_PUBKEY"
echo "--------------------------------------------------" | tee -a "$LOG"

read -rp "[PROMPT] Paste the public key of the HEAD server: " HEAD_PUBKEY
log "[INFO] HEAD public key received: ${HEAD_PUBKEY:0:8}...${HEAD_PUBKEY: -8}"

read -rp "[PROMPT] Enter WireGuard listen port [default: 51820]: " WG_PORT
WG_PORT="${WG_PORT:-51820}"
log "[INFO] WG port: $WG_PORT"

# ----------------------------------------------------------
[4/8] Detecting network configuration + Split Network...
# ----------------------------------------------------------
MAIN_IFACE=$(ip -4 route show default | awk '{print $5; exit}')
MAIN_IP=$(ip -4 addr show dev "$MAIN_IFACE" | awk '/inet / {print $2}' | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1)
log "[INFO] Main interface: $MAIN_IFACE ($MAIN_IP)"

# Detect Split Network from new-server.sh config
USE_SNAT="false"
SNAT_IP=""

if [ -f /root/.network_config ]; then
    source /root/.network_config
    log "[INFO] .network_config found: USE_SPLIT_NETWORK=$USE_SPLIT_NETWORK"
    if [ "$USE_SPLIT_NETWORK" = "true" ] && [ -n "$OUTBOUND_IP" ]; then
        USE_SNAT="true"
        SNAT_IP="$OUTBOUND_IP"
        log "[INFO] Split Network detected. SNAT -> $SNAT_IP"
    else
        log "[INFO] Single IP mode. Using MASQUERADE."
    fi
else
    # Fallback: check if interface has multiple IPs
    IP_COUNT=$(ip -4 addr show dev "$MAIN_IFACE" | grep -c 'inet ' || true)
    if [ "$IP_COUNT" -gt 1 ]; then
        log "[WARN] Multiple IPs on $MAIN_IFACE but no .network_config found!"
        log "[WARN] MASQUERADE will use primary IP (may not be desired)."
        log "[WARN] Run new-server.sh first for proper split network setup."
    else
        log "[INFO] Single IP on $MAIN_IFACE. Using MASQUERADE."
    fi
fi

# ----------------------------------------------------------
[5/8] Configuring UFW...
# ----------------------------------------------------------
if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
    ufw allow "$WG_PORT"/udp
    ufw reload
    log "[INFO] UFW is ACTIVE. Allowed $WG_PORT/udp."
else
    log "[INFO] UFW not active. Skipping UFW rules."
fi

# ----------------------------------------------------------
[6/8] Generating wg0.conf...
# ----------------------------------------------------------
if [ -f "$WG_DIR/wg0.conf" ]; then
    cp "$WG_DIR/wg0.conf" "$WG_DIR/wg0.conf.bak.$(date +%s)"
    log "[INFO] Backed up existing wg0.conf"
fi

# Build NAT rule based on split network detection
if [ "$USE_SNAT" = "true" ]; then
    NAT_POSTUP="iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o $MAIN_IFACE -j SNAT --to-source $SNAT_IP"
    NAT_POSTDOWN="bash -c 'iptables -t nat -D POSTROUTING -s 10.10.10.0/24 -o $MAIN_IFACE -j SNAT --to-source $SNAT_IP 2>/dev/null || true'"
    NAT_TYPE="SNAT -> $SNAT_IP"
else
    NAT_POSTUP="iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o $MAIN_IFACE -j MASQUERADE"
    NAT_POSTDOWN="bash -c 'iptables -t nat -D POSTROUTING -s 10.10.10.0/24 -o $MAIN_IFACE -j MASQUERADE 2>/dev/null || true'"
    NAT_TYPE="MASQUERADE"
fi

cat > "$WG_DIR/wg0.conf" << WGCNF
[Interface]
Address = 10.10.10.1/24
ListenPort = $WG_PORT
PrivateKey = $TAIL_PRIVKEY
MTU = 1280

# --- PostUp: FORWARD + NAT ---
# 1) Allow all traffic arriving from wg0 to be forwarded
# 2) Allow established/related return traffic back to wg0
# 3) NAT: $NAT_TYPE
PostUp = iptables -I FORWARD -i wg0 -j ACCEPT
PostUp = iptables -I FORWARD -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostUp = $NAT_POSTUP

# --- PostDown: cleanup (mirror of PostUp) ---
PostDown = bash -c 'iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true'
PostDown = bash -c 'iptables -D FORWARD -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true'
PostDown = $NAT_POSTDOWN

[Peer]
# HEAD Server (Input Node)
PublicKey = $HEAD_PUBKEY
AllowedIPs = 10.10.10.2/32
WGCNF
chmod 600 "$WG_DIR/wg0.conf"
log "[INFO] wg0.conf written. NAT: $NAT_TYPE"

# ----------------------------------------------------------
[7/8] Starting WireGuard tunnel...
# ----------------------------------------------------------
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0 || {
    log "[ERROR] Failed to start wg-quick@wg0!"
    log "[ERROR] Check: journalctl -u wg-quick@wg0 --no-pager -n 30"
    exit 1
}
log "[INFO] wg-quick@wg0 started."

sleep 3

# === DIAGNOSTICS ===
{
    echo ""
    echo "=== DIAGNOSTICS ==="
    echo ""
    echo "--- WireGuard status ---"
    wg show wg0
    echo ""
    echo "--- iptables FORWARD chain (filter) ---"
    iptables -L FORWARD -n -v --line-numbers 2>/dev/null | head -20
    echo ""
    echo "--- iptables nat POSTROUTING ---"
    iptables -t nat -L POSTROUTING -n -v --line-numbers 2>/dev/null | head -10
    echo ""
    echo "--- Routing table ---"
    ip route show
    echo ""
} | tee -a "$LOG"

# --- Check handshake ---
HANDSHAKE=$(wg show wg0 latest-handshakes 2>/dev/null | awk -F'\t' '{print $2}')
if [ -n "$HANDSHAKE" ] && [ "$HANDSHAKE" != "0" ]; then
    TUNNEL_STATUS="ACTIVE"
else
    TUNNEL_STATUS="WAITING_FOR_HEAD"
fi

# --- Summary ---
cat << SUMMARY | tee -a "$LOG"

============================================================
  TAIL SERVER — CONFIGURATION SUMMARY
============================================================
  Date:       $(date '+%Y-%m-%d %H:%M:%S %Z')
  Role:       TAIL (Exit Node)
  Interface:  $MAIN_IFACE ($MAIN_IP)
  WG Address: 10.10.10.1/24
  WG Port:    $WG_PORT/udp
  WG MTU:     1280
  UFW:        $(command -v ufw &>/dev/null && ufw status | grep -q "active" && echo "active" || echo "not active")
  NAT Type:   $NAT_TYPE
  Tunnel:     $TUNNEL_STATUS
============================================================
  TAIL Public Key (give to HEAD):
  $TAIL_PUBKEY
  HEAD Public Key (received):
  $HEAD_PUBKEY
============================================================
  Config files:
    $WG_DIR/wg0.conf
  Log: $LOG
============================================================
SUMMARY

if [ "$TUNNEL_STATUS" = "WAITING_FOR_HEAD" ]; then
    echo "" | tee -a "$LOG"
    log "[WARN] No recent handshake. This is OK if HEAD is not configured yet."
    log "[WARN] Tunnel will activate when HEAD connects."
fi