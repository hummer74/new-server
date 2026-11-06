#!/bin/bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
fi

# --- CONFIGURATION (mirrors new-server.sh defaults) ---
ROUTER_USER="tunneluser"
ROUTER_HOST="mousehouse.ignorelist.com"
ROUTER_PORT=24930
Z_ROUTER_USER="tunneluser"
Z_ROUTER_HOST="45.151.139.193"
Z_ROUTER_PORT=24940
SSH_PORTS=(22 24940)
LOG_FILE="/root/reverse_ssh.log"
KEY_PATH="/root/.ssh/ssh2router-key"

echo "=============================================="
echo " Setting up Reverse SSH Tunnels (x + z) "
echo "=============================================="

# 0. Key check (arrives via setup.7z)
if [ ! -f "$KEY_PATH" ]; then
    echo "ERROR: $KEY_PATH not found (it arrives inside setup.7z -> /root/.ssh/)." | tee -a "$LOG_FILE"
    echo "Reverse tunnel cannot be set up without this private key."
    while true; do
        read -p "Abort installation [q] or continue WITHOUT tunnel [c]? (q/c): " key_choice || { echo "ERROR: no input (stdin closed?). Aborting."; exit 1; }
        case "$key_choice" in
            [Qq]*) echo "Aborted by user (missing ssh2router key)."; exit 1 ;;
            [Cc]*) echo "Continuing without reverse tunnel." | tee -a "$LOG_FILE"; exit 0 ;;
            *) echo "Enter q or c." ;;
        esac
    done
fi
chmod 600 "$KEY_PATH"

setup_reverse_tunnel_to() {
    # One jumper leg. Arg JID: x = OpenWrt router, z = 03-RU reserve.
    local JID="$1"
    local RHOST RPORT RUSER RDESC
    case "$JID" in
        x) RHOST="$ROUTER_HOST"; RPORT="$ROUTER_PORT"; RUSER="$ROUTER_USER"; RDESC="OpenWrt" ;;
        z) RHOST="$Z_ROUTER_HOST"; RPORT="$Z_ROUTER_PORT"; RUSER="$Z_ROUTER_USER"; RDESC="03-RU" ;;
        *) echo "ERROR: unknown jumper '$JID'." | tee -a "$LOG_FILE"; exit 1 ;;
    esac

# 1. Local SSH port: deterministic senior port from config (same as orchestrator)
LOCAL_SSH_PORT="${SSH_PORTS[${#SSH_PORTS[@]}-1]}"
if [ -z "$LOCAL_SSH_PORT" ]; then
    LOCAL_SSH_PORT=22
fi

echo "Local SSH port: $LOCAL_SSH_PORT (leg $JID -> $RDESC $RHOST:$RPORT)" | tee -a "$LOG_FILE"

# 2. Default remote port from pretty hostname (same as orchestrator)
NEW_HOSTNAME=$(hostnamectl --pretty 2>/dev/null || true)
if [ -z "$NEW_HOSTNAME" ]; then
    NEW_HOSTNAME=$(hostname)
fi
NAME_PREFIX=$(echo "$NEW_HOSTNAME" | grep -oE '[0-9]{2}' | head -n 1 || true)
DEFAULT_REVERSE_PORT="25900"

if [ -n "$NAME_PREFIX" ]; then
    DEFAULT_REVERSE_PORT="259$NAME_PREFIX"
fi

printf "Enter REMOTE port on %s-jumper %s %s (default %s): " "$JID" "$RDESC" "$RHOST" "$DEFAULT_REVERSE_PORT"
read USER_INPUT_PORT || { echo "ERROR: no input (stdin closed?). Aborting."; exit 1; }
REVERSE_PORT=${USER_INPUT_PORT:-$DEFAULT_REVERSE_PORT}

if ! [[ "$REVERSE_PORT" =~ ^[0-9]+$ ]]; then
    echo "Error: port must be a number, skipping tunnel setup." | tee -a "$LOG_FILE"
    exit 1
fi

SERVICE_TEMPLATE="/etc/systemd/system/reverse-tunnel-${JID}@.service"
SERVICE_INSTANCE="reverse-tunnel-${JID}@${REVERSE_PORT}.service"

# 3. Manage existing reverse-tunnel services of this leg (same as orchestrator)
# Leg x also owns legacy single-template units (reverse-tunnel@*).
UNIT_GLOB="reverse-tunnel-${JID}@*"
UNIT_EXCLUDE='^$'
if [ "$JID" == "x" ]; then
    UNIT_GLOB="reverse-tunnel*"
    UNIT_EXCLUDE='reverse-tunnel-z@'
fi
mapfile -t EXISTING_SERVICES < <(systemctl list-units --type=service --all "$UNIT_GLOB" --no-legend 2>/dev/null | awk '{print $1}' | grep -v "$UNIT_EXCLUDE" || true)
if [ ${#EXISTING_SERVICES[@]} -gt 0 ]; then
    echo "Found existing tunnel services:" | tee -a "$LOG_FILE"
    for i in "${!EXISTING_SERVICES[@]}"; do
        printf "[%d] %s\n" "$((i+1))" "${EXISTING_SERVICES[$i]}"
    done | tee -a "$LOG_FILE"
    echo "Options: [Number] delete specific, [A]ll delete all, [S]kip to add new"
    read -p "Select action: " ACTION || { echo "ERROR: no input (stdin closed?). Aborting."; exit 1; }
    case "$ACTION" in
        [aA]* )
            for svc in "${EXISTING_SERVICES[@]}"; do
                systemctl stop "$svc" 2>/dev/null || true
                systemctl disable "$svc" 2>/dev/null || true
            done
            ;;
        [sS]* | "" ) ;;
        [0-9]* )
            IDX=$((ACTION-1))
            if [ "$IDX" -ge 0 ] && [ "$IDX" -lt "${#EXISTING_SERVICES[@]}" ]; then
                SELECTED_SVC="${EXISTING_SERVICES[$IDX]}"
                systemctl stop "$SELECTED_SVC" 2>/dev/null || true
                systemctl disable "$SELECTED_SVC" 2>/dev/null || true
            fi
            ;;
    esac
fi

# 4. Software installation (with bounded wait for apt lock on fresh boxes)
if ! command -v autossh &> /dev/null; then
    echo "Updating packages and installing autossh..."
    for w in $(seq 1 24); do
        fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
        echo "apt lock held, waiting... ($w)"; sleep 5
    done
    apt update && apt install autossh -y
fi

# 4b. Split-network BindAddress (key already checked in step 0)
BIND_OPT=""
if [ -f /root/.network_config ]; then
    # shellcheck disable=SC1091
    source /root/.network_config
    if [ "${USE_SPLIT_NETWORK:-false}" == "true" ] && [ -n "${OUTBOUND_IP:-}" ]; then
        if ip -4 addr show | grep -qw "$OUTBOUND_IP"; then
            BIND_OPT="-o BindAddress=$OUTBOUND_IP"
            echo "Split-network: binding outbound tunnel socket to $OUTBOUND_IP"
        else
            echo "WARNING: OUTBOUND_IP=$OUTBOUND_IP not local, connecting via default route."
        fi
    fi
fi

# 5. Create systemd template service (direct heredoc, same pattern as new-server.sh setup_reverse_tunnel)
echo "Creating/Updating systemd unit file..."
cat > "$SERVICE_TEMPLATE" <<EOF
[Unit]
Description=Reverse SSH Tunnel to $RDESC ($RHOST) on port %i
After=network-online.target
Wants=network-online.target

[Service]
User=root
Group=root
Environment="AUTOSSH_GATETIME=0"

ExecStart=/usr/bin/autossh -M 0 -N \\
    -o "StrictHostKeyChecking=no" \\
    -o "UserKnownHostsFile=/dev/null" $BIND_OPT \\
    -o "ServerAliveInterval=60" \\
    -o "ServerAliveCountMax=3" \\
    -o "ExitOnForwardFailure=yes" \\
    -o "TCPKeepAlive=yes" \\
    -i $KEY_PATH \\
    -p $RPORT \\
    -R %i:127.0.0.1:$LOCAL_SSH_PORT \\
    $RUSER@$RHOST

Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Guard against the 127:0:0:1 corruption (dots must stay dots)
if ! grep -q '127\.0\.0\.1' "$SERVICE_TEMPLATE"; then
    echo "ERROR: generated $SERVICE_TEMPLATE has no 127.0.0.1 — refusing to enable."
    exit 1
fi
if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "$SERVICE_TEMPLATE" 2>&1 | tee -a "$LOG_FILE" || true
fi
systemctl daemon-reload
systemctl enable "$SERVICE_INSTANCE"
systemctl restart "$SERVICE_INSTANCE"
sleep 3
if systemctl is-active --quiet "$SERVICE_INSTANCE"; then
    echo "Tunnel service $SERVICE_INSTANCE is active." | tee -a "$LOG_FILE"
else
    echo "ERROR: Tunnel service $SERVICE_INSTANCE failed to start." | tee -a "$LOG_FILE"
    journalctl -u "$SERVICE_INSTANCE" --no-pager -n 15 | tee -a "$LOG_FILE" || true
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] REVERSE Tunnel [$JID]: ${RHOST}:${REVERSE_PORT} -> ${NEW_HOSTNAME}:${LOCAL_SSH_PORT} (Status: $(systemctl is-active "$SERVICE_INSTANCE"))" >> "$LOG_FILE"
}

# Both jumper legs, always. No selection prompt.
setup_reverse_tunnel_to x
setup_reverse_tunnel_to z
