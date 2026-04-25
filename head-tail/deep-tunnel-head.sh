#!/bin/bash
# tunnel-head.sh – Configure HEAD server to proxy Amnezia clients via TAIL
# Runs on the HEAD (French) VPS. All client traffic from the Amnezia subnet
# is routed through the WireGuard tunnel to the TAIL exit node.

set -euo pipefail

LOG="/root/${0##*/}.log"
exec > >(tee -a "$LOG") 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ---------- Root check ----------
if [[ $EUID -ne 0 ]]; then
    log "This script must be run as root."
    exit 1
fi

install_if_missing() {
    if ! dpkg -s "$1" >/dev/null 2>&1; then
        log "Installing $1..."
        apt-get update -qq && apt-get install -y "$1"
    fi
}

confirm_default() {
    local prompt="$1"; local default="$2"
    read -p "$prompt [$default]: " input
    echo "${input:-$default}"
}

# ---------- Detect Amnezia subnet ----------
detect_amnezia_subnet() {
    # Look for tunnel interfaces (tun*, amnezia*)
    local ifaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE 'lo|wg' | grep -E '^(tun|amnezia)')
    local candidates=()
    for if in $ifaces; do
        local cidr=$(ip -4 -o addr show dev "$if" 2>/dev/null | awk '{print $4}')
        [ -n "$cidr" ] && candidates+=("$if:$cidr")
    done

    if [ ${#candidates[@]} -eq 0 ]; then
        return 1
    fi

    local chosen_if chosen_cidr
    if [ ${#candidates[@]} -eq 1 ]; then
        IFS=':' read -r chosen_if chosen_cidr <<< "${candidates[0]}"
    else
        echo "Multiple VPN interfaces found:"
        for i in "${!candidates[@]}"; do
            echo "$((i+1))) ${candidates[$i]}"
        done
        read -p "Select Amnezia interface number (or Enter for first): " choice
        choice=${choice:-1}
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#candidates[@]} ]; then
            echo "Invalid choice, using first."
            choice=1
        fi
        IFS=':' read -r chosen_if chosen_cidr <<< "${candidates[$((choice-1))]}"
    fi

    # Compute network address using ipcalc
    install_if_missing ipcalc
    local network_cidr
    network_cidr=$(ipcalc -n "$chosen_cidr" | grep Network | awk '{print $2}' || true)
    if [ -z "$network_cidr" ]; then
        log "Could not compute network from $chosen_cidr, using simple fallback."
        local base="${chosen_cidr%.*}.0"; local prefix="${chosen_cidr#*/}"
        network_cidr="${base}/${prefix}"
    fi
    echo "$network_cidr"
}

log "=== HEAD proxy setup started ==="

# ---------- Parameters ----------
DE_IP="${1:-$(confirm_default "TAIL server IP address" "")}"
if [ -z "$DE_IP" ]; then
    log "ERROR: TAIL IP is required."
    exit 1
fi

DE_PUBKEY="${2:-$(confirm_default "TAIL server public key" "")}"
if [ -z "$DE_PUBKEY" ]; then
    log "ERROR: TAIL public key is required."
    exit 1
fi

# Auto-detect Amnezia subnet
log "Detecting Amnezia client subnet..."
DETECTED_SUBNET=$(detect_amnezia_subnet || true)
if [ -n "$DETECTED_SUBNET" ]; then
    log "Detected subnet: $DETECTED_SUBNET"
else
    log "WARNING: Could not detect Amnezia subnet automatically."
    DETECTED_SUBNET="10.8.0.0/24"
fi
CLIENT_SUBNET="${3:-$(confirm_default "Amnezia client subnet" "$DETECTED_SUBNET")}"

TUNNEL_IP_FR="${4:-$(confirm_default "HEAD IP inside tunnel (with prefix)" "10.9.0.1/30")}"
PORT="${5:-$(confirm_default "WireGuard port on TAIL" "51820")}"

CONF="/etc/wireguard/wg0.conf"

# ---------- Install packages ----------
install_if_missing wireguard
install_if_missing ipcalc

# ---------- Idempotency check ----------
if [ -f "$CONF" ]; then
    if grep -q "Endpoint = $DE_IP:$PORT" "$CONF" 2>/dev/null; then
        log "Tunnel to TAIL ($DE_IP:$PORT) already configured in $CONF"
        log "To recreate, remove $CONF manually."
        exit 0
    else
        log "Existing config with different endpoint found, backing up."
        cp "$CONF" "${CONF}.bak.$(date +%s)"
    fi
fi

# ---------- Generate keys ----------
mkdir -p /etc/wireguard
if [ ! -f /etc/wireguard/private.key ]; then
    wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
    chmod 600 /etc/wireguard/private.key
    log "HEAD keys generated."
fi
PRIVKEY=$(cat /etc/wireguard/private.key)
HEAD_PUBKEY=$(cat /etc/wireguard/public.key)

# ---------- Create WireGuard config ----------
cat > "$CONF" <<EOF
[Interface]
Address = $TUNNEL_IP_FR
PrivateKey = $PRIVKEY

# Policy routing: only Amnezia client subnet uses the tunnel to TAIL
PostUp = ip rule add from $CLIENT_SUBNET table 100 priority 100 2>/dev/null || true
PostUp = ip route add default via ${TUNNEL_IP_FR%/*} dev wg0 table 100 2>/dev/null || true
PostDown = ip rule del from $CLIENT_SUBNET table 100 2>/dev/null || true
PostDown = ip route del default via ${TUNNEL_IP_FR%/*} dev wg0 table 100 2>/dev/null || true

[Peer]
PublicKey = $DE_PUBKEY
Endpoint = $DE_IP:$PORT
AllowedIPs = 10.9.0.2/32
PersistentKeepalive = 25
EOF

log "WireGuard configuration $CONF written."

# ---------- Enable IP forwarding ----------
if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p
    log "IP forwarding enabled."
fi

# ---------- Start WireGuard ----------
systemctl enable --now wg-quick@wg0
log "WireGuard interface wg0 started on HEAD."

# ---------- Output ----------
log ""
log "HEAD proxy configured successfully."
log "HEAD public key: $HEAD_PUBKEY"
log "TAIL peer: $DE_IP:$PORT"
log "Amnezia clients from $CLIENT_SUBNET are now routed via TAIL."
log ""
log "Verification:"
log "  wg show"
log "  ip route show table 100"