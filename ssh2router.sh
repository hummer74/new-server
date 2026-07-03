#!/bin/bash

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
fi

# --- CONFIGURATION (set once) ---
ROUTER_USER="tunneluser"
ROUTER_HOST="mousehouse.ignorelist.com"
ROUTER_PORT=24930
LOG_FILE="/root/reverse-tunnel.log"

echo "=============================================="
echo " Setting up Reverse SSH Tunnel to OpenWrt "
echo "=============================================="

# 1. Auto-detecting the highest SSH port
echo "Detecting local SSH ports..."
LOCAL_SSH_PORT=$(ss -tlnp | grep 'sshd' | awk '{print $4}' | awk -F':' '{print $NF}' | sort -rn | head -n 1)

if [ -z "$LOCAL_SSH_PORT" ]; then
    echo "Warning: Could not detect sshd port. Falling back to 22."
    LOCAL_SSH_PORT=22
else
    echo "Detected max local SSH port: $LOCAL_SSH_PORT"
fi

# 2. Generate default remote port from pretty-name
# Prioritize 'pretty' hostname (e.g., 05-FR), fall back to static hostname
PRETTY_NAME=$(hostnamectl --pretty)
if [ -z "$PRETTY_NAME" ]; then
    PRETTY_NAME=$(hostname)
fi

# Extract the first two digits found in the name
NAME_PREFIX=$(echo "$PRETTY_NAME" | grep -oE '[0-9]{2}' | head -n 1)

if [ -z "$NAME_PREFIX" ]; then
    DEFAULT_REVERSE_PORT="25900"
    echo "Warning: Could not extract digits from name '$PRETTY_NAME'. Using 25900."
else
    DEFAULT_REVERSE_PORT="259$NAME_PREFIX"
    echo "Identified prefix '$NAME_PREFIX' from name '$PRETTY_NAME'."
fi

printf "Enter the REMOTE port on OpenWrt (default %s): " "$DEFAULT_REVERSE_PORT"
read USER_INPUT_PORT
REVERSE_PORT=${USER_INPUT_PORT:-$DEFAULT_REVERSE_PORT}

if ! [[ "$REVERSE_PORT" =~ ^[0-9]+$ ]]; then
    echo "Error: Remote port must be a number!"
    exit 1
fi

SERVICE_TEMPLATE="/etc/systemd/system/reverse-tunnel@.service"
SERVICE_INSTANCE="reverse-tunnel@${REVERSE_PORT}.service"

# 3. Manage existing reverse-tunnel services
echo "Checking for existing reverse-tunnel services..."
mapfile -t EXISTING_SERVICES < <(systemctl list-units --type=service --all "reverse-tunnel@*" --no-legend | awk '{print $1}')

if [ ${#EXISTING_SERVICES[@]} -gt 0 ]; then
    echo "----------------------------------------------"
    echo "Found existing tunnel services:"
    for i in "${!EXISTING_SERVICES[@]}"; do
        printf "[%d] %s\n" "$((i+1))" "${EXISTING_SERVICES[$i]}"
    done
    echo "----------------------------------------------"
    echo "Options: [Number] to delete specific, [A]ll to delete all, [S]kip to add new"
    read -p "Select action: " ACTION

    case "$ACTION" in
        [aA]* )
            for svc in "${EXISTING_SERVICES[@]}"; do
                echo "Stopping and disabling $svc..."
                systemctl stop "$svc" 2>/dev/null
                systemctl disable "$svc" 2>/dev/null
            done
            ;;
        [sS]* | "" )
            echo "Skipping deletion. Proceeding to add/update..."
            ;;
        [0-9]* )
            IDX=$((ACTION-1))
            if [ "$IDX" -ge 0 ] && [ "$IDX" -lt "${#EXISTING_SERVICES[@]}" ]; then
                SELECTED_SVC="${EXISTING_SERVICES[$IDX]}"
                echo "Removing $SELECTED_SVC..."
                systemctl stop "$SELECTED_SVC" 2>/dev/null
                systemctl disable "$SELECTED_SVC" 2>/dev/null
            else
                echo "Invalid index. Skipping deletion."
            fi
            ;;
    esac
else
    echo "No existing reverse-tunnel services found. Proceeding..."
fi

# 4. Software installation
if ! command -v autossh &> /dev/null; then
    echo "Updating packages and installing autossh..."
    apt update && apt install autossh -y
fi

# 5. Create systemd template service
echo "Creating/Updating systemd unit file..."
bash -c "cat <<EOF > $SERVICE_TEMPLATE
[Unit]
Description=Reverse SSH Tunnel to OpenWrt on port %i
After=network.target

[Service]
User=root
Group=root
Environment=\"AUTOSSH_GATETIME=0\"

ExecStart=/usr/bin/autossh -M 0 -N \\
    -o \"StrictHostKeyChecking=no\" \\
    -o \"UserKnownHostsFile=/dev/null\" \\
    -o \"ServerAliveInterval=60\" \\
    -o \"ServerAliveCountMax=3\" \\
    -o \"ExitOnForwardFailure=yes\" \\
    -o \"TCPKeepAlive=yes\" \\
    -i /root/.ssh/ssh2router-key \\
    -p $ROUTER_PORT \\
    -R %i:127.0.0.1:$LOCAL_SSH_PORT \\
    $ROUTER_USER@$ROUTER_HOST

Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF"

# 6. Launch and activation
echo "Reloading systemd and starting service..."
systemctl daemon-reload
systemctl enable "$SERVICE_INSTANCE"
systemctl start "$SERVICE_INSTANCE"

# 7. Output and logging
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
LOG_ENTRY="[$TIMESTAMP] REVERSE Tunnel Active: [${ROUTER_HOST}:${REVERSE_PORT} -> ${PRETTY_NAME}:${LOCAL_SSH_PORT}]"

echo "----------------------------------------------"
echo "Done! $LOG_ENTRY"
echo "Check status: systemctl status $SERVICE_INSTANCE"
echo "$LOG_ENTRY" >> "$LOG_FILE"
echo "----------------------------------------------"