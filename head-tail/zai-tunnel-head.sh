#!/bin/bash
# ============================================================
#  zai-tunnel-head.sh v4 — HEAD Server (Input Node)
#
#  Creates a WireGuard tunnel to TAIL exit node.
#  All Docker container traffic (Amnezia VPN, etc.) is
#  marked with fwmark 0x3 and routed through TAIL via
#  policy routing table "tail_out".
#
#  v4 key fixes:
#    - DNAT exclusion: VPN-protocol packets (client<->container)
#      bypass the tunnel and go directly to the client
#    - MASQUERADE with -I POSTROUTING 1 (before Docker's rules)
#    - systemd drop-in: After=docker.service (boot order)
#    - FORWARD rules in DOCKER-USER chain (survives Docker restarts)
#    - Real CIDR preservation (not forced /24)
#    - MTU 1280 for WireGuard+Docker encapsulation
#    - Config summary logging to /root/tunnel-head.log
# ============================================================
set -euo pipefail

LOG="/root/tunnel-head.log"

log() {
    echo "$1" | tee -a "$LOG"
}

# --- Banner ---
cat << 'BANNER' | tee -a "$LOG"

============================================================
  zai-tunnel-head.sh v4 — HEAD (Input Node)
  WireGuard tunnel + policy routing to TAIL exit node
============================================================
BANNER
log "[INFO] $(date '+%Y-%m-%d %H:%M:%S %Z')"

# ----------------------------------------------------------
[1/9] Installing required packages...
# ----------------------------------------------------------
if ! command -v wg &>/dev/null; then
    log "[INFO] Installing WireGuard..."
    apt-get update -qq && apt-get install -y -qq wireguard wireguard-tools
    log "[INFO] WireGuard installed."
else
    log "[INFO] WireGuard already installed."
fi

# ----------------------------------------------------------
[2/9] Enabling IPv4 forwarding...
# ----------------------------------------------------------
if [ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]; then
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/99-tunnel.conf
    sysctl -p /etc/sysctl.d/99-tunnel.conf >/dev/null
    log "[INFO] net.ipv4.ip_forward = 1"
else
    log "[INFO] net.ipv4.ip_forward already enabled."
fi

# ----------------------------------------------------------
[3/9] Checking/Generating WireGuard keys...
# ----------------------------------------------------------
WG_DIR="/etc/wireguard"
mkdir -p "$WG_DIR"

if [ ! -f "$WG_DIR/head_private" ] || [ ! -f "$WG_DIR/head_public" ]; then
    log "[INFO] Generating new WireGuard key pair..."
    wg genkey > "$WG_DIR/head_private" 2>/dev/null
    wg pubkey < "$WG_DIR/head_private" > "$WG_DIR/head_public" 2>/dev/null
    chmod 600 "$WG_DIR/head_private"
    log "[INFO] Keys generated."
else
    log "[INFO] Existing keys found. Reusing."
fi

HEAD_PRIVKEY=$(cat "$WG_DIR/head_private")
HEAD_PUBKEY=$(cat "$WG_DIR/head_public")

echo "--------------------------------------------------" | tee -a "$LOG"
log "[PROMPT] Public key of this HEAD server (copy to TAIL):"
log "[PROMPT] $HEAD_PUBKEY"
echo "--------------------------------------------------" | tee -a "$LOG"

read -rp "[PROMPT] Paste the public key of the TAIL server: " TAIL_PUBKEY
log "[INFO] TAIL public key received: ${TAIL_PUBKEY:0:8}...${TAIL_PUBKEY: -8}"

read -rp "[PROMPT] Enter TAIL server public IP or hostname: " TAIL_ENDPOINT
log "[INFO] TAIL endpoint: $TAIL_ENDPOINT"

read -rp "[PROMPT] Enter WireGuard listen port for TAIL [default: 51820]: " TAIL_PORT
TAIL_PORT="${TAIL_PORT:-51820}"
log "[INFO] TAIL port: $TAIL_PORT"

# ----------------------------------------------------------
[4/9] Detecting network configuration...
# ----------------------------------------------------------
MAIN_IFACE=$(ip -4 route show default | awk '{print $5; exit}')
MAIN_IP=$(ip -4 addr show dev "$MAIN_IFACE" | awk '/inet / {print $2}' | grep -oP '\d+\.\d+\.\d+\.\d+')
log "[INFO] Main interface: $MAIN_IFACE ($MAIN_IP)"

# ----------------------------------------------------------
[5/9] Creating wg-up.sh v4 (routing hooks)...
# ----------------------------------------------------------
cat > "$WG_DIR/wg-up.sh" << 'WGUP'
#!/bin/bash
# ============================================================
#  wg-up.sh v4 — runs as PostUp when wg0 starts
#  Marks Docker traffic for policy routing -> wg0 -> TAIL
#
#  Key fixes:
#    - DNAT exclusion: VPN-protocol packets (client<->container)
#      go directly, NOT through tunnel
#    - MASQUERADE with -I POSTROUTING 1 (before Docker's rules)
#    - After=docker.service systemd drop-in for boot order
# ============================================================
TABLE="tail_out"
MARK="0x3"

echo "[wg-up] $(date '+%H:%M:%S') Starting routing hooks..."

# --- 1. Policy routing table ---
ip route flush table $TABLE 2>/dev/null || true
ip route add default via 10.10.10.1 dev wg0 table $TABLE
echo "[wg-up] Default route via 10.10.10.1 in table $TABLE"

while ip rule show | grep -q "fwmark $MARK"; do
    ip rule del fwmark $MARK 2>/dev/null || true
done
ip rule add fwmark $MARK lookup $TABLE priority 1000
echo "[wg-up] Policy rule: fwmark $MARK -> table $TABLE (priority 1000)"

# --- 2. Detect subnets (preserve actual CIDR, NOT forced /24) ---
SUBNETS=$(ip -4 addr show | awk '/inet / {print $2}' | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)' | grep -v "10\.10\.10\." | sort -u)

if [ -z "$SUBNETS" ]; then
    echo "[wg-up] WARNING: No private-range subnets detected!"
    echo "[wg-up] Docker may not be running. Re-run later:"
    echo "[wg-up]   systemctl restart wg-quick@wg0"
else
    echo "[wg-up] Detected subnets:"
    echo "$SUBNETS" | while read line; do echo "[wg-up]   $line"; done
fi

# --- 3. Apply mangle + nat rules for each detected subnet ---
COUNT=0
for entry in $SUBNETS; do
    COUNT=$((COUNT + 1))

    # CRITICAL: Exclude DNAT connections (VPN-protocol client<->container)
    iptables -t mangle -A PREROUTING -s "$entry" -m conntrack --ctstate DNAT -j RETURN

    # Exclude private/local destinations
    iptables -t mangle -A PREROUTING -s "$entry" -d 127.0.0.0/8       -j RETURN
    iptables -t mangle -A PREROUTING -s "$entry" -d 169.254.0.0/16    -j RETURN
    iptables -t mangle -A PREROUTING -s "$entry" -d 10.0.0.0/8        -j RETURN
    iptables -t mangle -A PREROUTING -s "$entry" -d 172.16.0.0/12     -j RETURN
    iptables -t mangle -A PREROUTING -s "$entry" -d 192.168.0.0/16    -j RETURN

    # Mark remaining traffic (Internet-bound)
    iptables -t mangle -A PREROUTING -s "$entry" -j MARK --set-mark $MARK

    # Masquerade BEFORE Docker's rules (insert at position 1)
    iptables -t nat -I POSTROUTING 1 -s "$entry" -o wg0 -j MASQUERADE

    echo "[wg-up] Subnet #$COUNT: $entry -- DNAT-excluded + marked + masqueraded"
done

# --- 4. FORWARD through wg0 (DOCKER-USER survives Docker restarts) ---
if iptables -L DOCKER-USER >/dev/null 2>&1; then
    iptables -I DOCKER-USER -i wg0 -j ACCEPT
    iptables -I DOCKER-USER -o wg0 -j ACCEPT
    echo "[wg-up] FORWARD rules: added to DOCKER-USER chain"
else
    iptables -I FORWARD -i wg0 -j ACCEPT
    iptables -I FORWARD -o wg0 -j ACCEPT
    echo "[wg-up] FORWARD rules: added to FORWARD chain (no DOCKER-USER)"
fi

echo "[wg-up] Done. $COUNT subnet(s) configured."
WGUP
chmod +x "$WG_DIR/wg-up.sh"
log "[INFO] wg-up.sh v4 written."

# ----------------------------------------------------------
[6/9] Creating wg-down.sh v4 (cleanup hooks)...
# ----------------------------------------------------------
cat > "$WG_DIR/wg-down.sh" << 'WGDOWN'
#!/bin/bash
# ============================================================
#  wg-down.sh v4 — runs as PostDown when wg0 stops
#  Reverses ALL rules created by wg-up.sh
# ============================================================
TABLE="tail_out"
MARK="0x3"

echo "[wg-down] $(date '+%H:%M:%S') Cleaning up routing hooks..."

# --- 1. Flush mangle PREROUTING ---
iptables -t mangle -F PREROUTING 2>/dev/null || true
echo "[wg-down] Mangle PREROUTING flushed"

# --- 2. Remove MASQUERADE rules for wg0 ---
while iptables -t nat -L POSTROUTING | grep -q "wg0"; do
    iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE 2>/dev/null || true
done
echo "[wg-down] NAT MASQUERADE for wg0 removed"

# --- 3. Remove FORWARD rules from DOCKER-USER ---
if iptables -L DOCKER-USER >/dev/null 2>&1; then
    iptables -D DOCKER-USER -i wg0 -j ACCEPT 2>/dev/null || true
    iptables -D DOCKER-USER -o wg0 -j ACCEPT 2>/dev/null || true
    echo "[wg-down] FORWARD rules removed from DOCKER-USER"
else
    iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null || true
    echo "[wg-down] FORWARD rules removed from FORWARD"
fi

# --- 4. Remove policy routing ---
ip rule del fwmark $MARK 2>/dev/null || true
ip route flush table $TABLE 2>/dev/null || true
echo "[wg-down] Policy routing removed (fwmark $MARK, table $TABLE)"

echo "[wg-down] Done."
WGDOWN
chmod +x "$WG_DIR/wg-down.sh"
log "[INFO] wg-down.sh v4 written."

# ----------------------------------------------------------
[7/9] Creating systemd drop-in (After=docker.service)...
# ----------------------------------------------------------
SYSTEMD_DIR="/etc/systemd/system/wg-quick@wg0.service.d"
mkdir -p "$SYSTEMD_DIR"

cat > "$SYSTEMD_DIR/after-docker.conf" << 'SYSTEMD'
[Unit]
After=docker.service docker.socket
Wants=docker.service
SYSTEMD
systemctl daemon-reload
log "[INFO] systemd drop-in: After=docker.service docker.socket"

# ----------------------------------------------------------
[8/9] Generating wg0.conf...
# ----------------------------------------------------------
if [ -f "$WG_DIR/wg0.conf" ]; then
    cp "$WG_DIR/wg0.conf" "$WG_DIR/wg0.conf.bak.$(date +%s)"
    log "[INFO] Backed up existing wg0.conf"
fi

cat > "$WG_DIR/wg0.conf" << WGCNF
[Interface]
Address = 10.10.10.2/24
PrivateKey = $HEAD_PRIVKEY
# CRITICAL: Do NOT hijack main routing table.
# Only fwmark-marked packets use the tunnel (via wg-up.sh).
Table = off
MTU = 1280

PostUp = $WG_DIR/wg-up.sh
PostDown = $WG_DIR/wg-down.sh

[Peer]
# TAIL Server (Exit Node)
PublicKey = $TAIL_PUBKEY
Endpoint = ${TAIL_ENDPOINT}:${TAIL_PORT}
# CRITICAL: AllowedIPs = 0.0.0.0/0 is the crypto-key routing directive,
# NOT the routing table directive. With Table = off, wg-quick will NOT
# add any routes to the main table. Routing is controlled by fwmark.
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
WGCNF
chmod 600 "$WG_DIR/wg0.conf"
log "[INFO] wg0.conf written."

# ----------------------------------------------------------
[9/9] Starting WireGuard tunnel...
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
    echo "--- iptables mangle PREROUTING (first 24 rules) ---"
    iptables -t mangle -L PREROUTING -n -v --line-numbers 2>/dev/null | head -24
    echo ""
    echo "--- iptables nat POSTROUTING (first 10 rules) ---"
    iptables -t nat -L POSTROUTING -n -v --line-numbers 2>/dev/null | head -10
    echo ""
    echo "--- ip rule (fwmark) ---"
    ip rule show | grep -E "fwmark|lookup"
    echo ""
    echo "--- ip route table tail_out ---"
    ip route show table tail_out 2>/dev/null || echo "(empty)"
    echo ""
    echo "--- DOCKER-USER chain ---"
    if iptables -L DOCKER-USER >/dev/null 2>&1; then
        iptables -L DOCKER-USER -n -v --line-numbers 2>/dev/null
    else
        echo "(DOCKER-USER chain not found — no Docker)"
    fi
    echo ""
} | tee -a "$LOG"

HANDSHAKE=$(wg show wg0 latest-handshakes 2>/dev/null | awk -F'\t' '{print $2}')
if [ -n "$HANDSHAKE" ] && [ "$HANDSHAKE" != "0" ]; then
    TUNNEL_STATUS="ACTIVE"
else
    TUNNEL_STATUS="WAITING_FOR_TAIL"
fi

cat << SUMMARY | tee -a "$LOG"

============================================================
  HEAD SERVER — CONFIGURATION SUMMARY
============================================================
  Date:       $(date '+%Y-%m-%d %H:%M:%S %Z')
  Role:       HEAD (Input Node)
  Interface:  $MAIN_IFACE ($MAIN_IP)
  WG Address: 10.10.10.2/24
  WG MTU:     1280
  Tunnel:     $TUNNEL_STATUS
  Systemd:    After=docker.service docker.socket
============================================================
  HEAD Public Key (give to TAIL):
  $HEAD_PUBKEY
  TAIL Public Key (received):
  $TAIL_PUBKEY
  TAIL Endpoint:
  ${TAIL_ENDPOINT}:${TAIL_PORT}
============================================================
  Config files:
    $WG_DIR/wg0.conf
    $WG_DIR/wg-up.sh    (v4 — DNAT exclusion + insert-first MASQ)
    $WG_DIR/wg-down.sh  (v4 — full cleanup)
    $SYSTEMD_DIR/after-docker.conf
  Log: $LOG
============================================================
SUMMARY

if [ "$TUNNEL_STATUS" = "WAITING_FOR_TAIL" ]; then
    echo "" | tee -a "$LOG"
    log "[WARN] No recent handshake. This is OK if TAIL is not configured yet."
    log "[WARN] Tunnel will activate when TAIL connects."
fi