#!/bin/bash
set -euo pipefail

# === Log all output ===
LOG_FILE="/root/new-server.log"
exec 3>&1 4>&2
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== Script started at $(date '+%Y-%m-%d %H:%M:%S') ===" >&3

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

# --- Detect Debian version ---
if [ -f /etc/os-release ]; then
    source /etc/os-release
    DEBIAN_VERSION_ID="${VERSION_ID:-0}"
    DEBIAN_CODENAME="${VERSION_CODENAME:-unknown}"
else
    echo "Error: /etc/os-release not found."
    exit 1
fi

# --- STEP 0: Load or Detect IP Config ---
echo "--- Network Analysis ---"
NETWORK_CONFIG="/root/.network_config"
IPV4_LIST=($(ip -4 addr show | grep inet | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1))
NUM_IPS=${#IPV4_LIST[@]}

# Default values
USE_SPLIT_NETWORK="false"
INBOUND_IP=""
OUTBOUND_IP=""

# Load existing config if available
if [ -f "$NETWORK_CONFIG" ]; then
    echo "Loading existing configuration from $NETWORK_CONFIG"
    # Temporary disable 'set -u' to source potentially empty variables safely
    set +u
    source "$NETWORK_CONFIG"
    set -u
fi

# Interaction only if config is missing
if [ -z "$INBOUND_IP" ]; then
    if [ "$NUM_IPS" -gt 1 ]; then
        echo "Found multiple IPv4 addresses."
        while true; do
            read -p "Do you want to use Inbound/Outbound split technology? (Y/N): " use_split
            case "$use_split" in
                [Yy]*) USE_SPLIT_NETWORK="true"; break ;;
                [Nn]*) USE_SPLIT_NETWORK="false"; break ;;
                *) echo "Please enter Y or N." ;;
            esac
        done

        if [ "$USE_SPLIT_NETWORK" == "true" ]; then
            echo "Select INBOUND IP index:"
            for i in "${!IPV4_LIST[@]}"; do echo "[$i] ${IPV4_LIST[$i]}"; done
            read -p "Index: " in_idx
            INBOUND_IP=${IPV4_LIST[$in_idx]}
            
            if [ "$NUM_IPS" -eq 2 ]; then
                OUTBOUND_IP=${IPV4_LIST[$((1 - in_idx))]}
            else
                read -p "Select OUTBOUND IP index: " out_idx
                OUTBOUND_IP=${IPV4_LIST[$out_idx]}
            fi
        else
            INBOUND_IP=${IPV4_LIST[0]}
            OUTBOUND_IP=${IPV4_LIST[0]}
        fi
    else
        INBOUND_IP=${IPV4_LIST[0]}
        OUTBOUND_IP=${IPV4_LIST[0]}
        USE_SPLIT_NETWORK="false"
    fi
    # Save for idempotency
    cat > "$NETWORK_CONFIG" <<EOF
USE_SPLIT_NETWORK=$USE_SPLIT_NETWORK
INBOUND_IP=$INBOUND_IP
OUTBOUND_IP=$OUTBOUND_IP
EOF
fi

echo "Using: INBOUND=$INBOUND_IP, OUTBOUND=$OUTBOUND_IP, SPLIT=$USE_SPLIT_NETWORK"

# --- APT Sources (Idempotent) ---
if [ ! -f /etc/apt/sources.list.bak_orig ]; then
    echo "Backing up and fixing APT sources..."
    cp /etc/apt/sources.list /etc/apt/sources.list.bak_orig
    mkdir -p /root/apt-backups
    mv /etc/apt/sources.list.d/* /root/apt-backups/ 2>/dev/null || true

    if [ "$DEBIAN_VERSION_ID" -le 10 ] 2>/dev/null; then
        cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian ${DEBIAN_CODENAME} main contrib non-free
deb http://archive.debian.org/debian ${DEBIAN_CODENAME}-updates main contrib non-free
EOF
    else
        cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${DEBIAN_CODENAME} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${DEBIAN_CODENAME}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${DEBIAN_CODENAME}-security main contrib non-free non-free-firmware
EOF
    fi
    [ "$DEBIAN_VERSION_ID" -lt 12 ] && sed -i 's/ non-free-firmware//g' /etc/apt/sources.list
fi

# --- System Updates ---
apt update -y && apt full-upgrade -y

# --- Swap (Idempotent) ---
SWAP_FILE="/swapfile"
if ! swapon --show | grep -q "$SWAP_FILE"; then
    echo "Creating 512MB swap..."
    fallocate -l 512M "$SWAP_FILE" || dd if=/dev/zero of="$SWAP_FILE" bs=1M count=512
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
    swapon "$SWAP_FILE"
    grep -q "$SWAP_FILE" /etc/fstab || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
fi

# --- Packages ---
apt install sudo ufw cron rsyslog mc curl wget unzip p7zip-full htop unattended-upgrades fail2ban screen openssl docker.io docker-compose -y

# --- Users & Archive (Idempotent) ---
if [ ! -f /root/.setup_done ]; then
    wget -O setup.7z https://raw.githubusercontent.com/hummer74/new-server/main/setup.7z
    for attempt in {1..5}; do
        read -s -p "Enter master password for setup: " MASTER_PASSWORD
        echo
        if 7za x -p"$MASTER_PASSWORD" setup.7z -aoa >/dev/null 2>&1; then
            if ! grep -q "^opossum:" /etc/passwd; then
                pass=$(openssl passwd -6 "$MASTER_PASSWORD")
                useradd -m -p "$pass" -s /bin/bash opossum
                usermod -aG sudo opossum
                echo "User opossum added."
            fi
            touch /root/.setup_done
            break
        fi
        [ "$attempt" -eq 5 ] && exit 1
    done
    rm -f setup.7z
fi

# --- UFW (FIXED SYNTAX) ---
echo "Configuring UFW..."
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing

for port in 22 24940 443; do
    if [ "$USE_SPLIT_NETWORK" == "true" ] && [ -n "$INBOUND_IP" ]; then
        # Правильный синтаксис для конкретного IP
        ufw allow to "$INBOUND_IP" port "$port" proto tcp
    else
        # Универсальный синтаксис (исправляет вашу ошибку)
        ufw allow "$port"/tcp
    fi
done

# Patch UFW for Docker (Idempotent check)
if ! grep -q "BEGIN UFW AND DOCKER" /etc/ufw/after.rules; then
    cat >> /etc/ufw/after.rules <<'EOF'
*filter
:ufw-user-forward - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -j RETURN -s 10.0.0.0/8
-A DOCKER-USER -j RETURN -s 172.16.0.0/12
-A DOCKER-USER -j RETURN -s 192.168.0.0/16
-A DOCKER-USER -j ufw-user-forward
-A DOCKER-USER -j RETURN
COMMIT
EOF
fi

# --- PBR (Split Network) ---
if [ "$USE_SPLIT_NETWORK" == "true" ]; then
    MAIN_IFACE=$(ip -4 route | grep default | awk '{print $5}' | head -n1)
    OUTBOUND_GW=$(ip -4 route show dev "$MAIN_IFACE" | grep default | awk '{print $3}' | head -n1)
    
    grep -q "100 custom" /etc/iproute2/rt_tables || echo "100 custom" >> /etc/iproute2/rt_tables

    cat > /etc/systemd/system/set-outbound-route.service <<EOF
[Unit]
Description=Policy Based Routing
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/sbin/ip route replace default via $OUTBOUND_GW dev $MAIN_IFACE src $OUTBOUND_IP
ExecStart=/usr/sbin/ip route flush table 100
ExecStart=/usr/sbin/ip route add default via $OUTBOUND_GW dev $MAIN_IFACE table 100
ExecStart=/usr/sbin/ip rule add from $INBOUND_IP table 100
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now set-outbound-route.service
fi

echo "Finalizing..."
ufw --force enable
echo "Done. Rebooting in 5 seconds..."
sleep 5
reboot