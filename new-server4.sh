#!/bin/bash
set -euo pipefail

# ==============================================================================
# === CONFIGURATION (Magic Constants) ===
# ==============================================================================

# Logging
LOG_FILE="/root/new-server.log"

# System settings
SWAP_SIZE_MB=512
SSH_PORTS=(22 24940)

# Security & Fail2ban
F2B_IGNORE_IPS="176.56.1.165 95.78.162.177 45.86.86.195 46.29.239.23 45.151.139.193 45.38.143.206 217.60.252.204 176.125.243.194 194.58.68.23"

# Setup Archive
SETUP_ARCHIVE_URL="https://raw.githubusercontent.com/hummer74/new-server/main/setup.7z"

# Reverse SSH Tunnel
ROUTER_USER="tunneluser"
ROUTER_HOST="mousehouse.ignorelist.com"
ROUTER_PORT=24930

# Telemt MTProto Proxy
PROXY_PORT=8443
PROXY_DOMAIN="github.com"
PROXY_USER="proxy_user"

# ==============================================================================
# === GLOBAL STATE VARIABLES ===
# ==============================================================================
DEBIAN_VERSION_ID=""
DEBIAN_CODENAME=""
INBOUND_IP=""
OUTBOUND_IP=""
USE_SPLIT_NETWORK="false"
NEW_HOSTNAME=""
MASTER_PASSWORD=""
EXTERNAL_IP=""

# ==============================================================================
# === FUNCTIONS ===
# ==============================================================================

init_logging() {
    exec 3>&1 4>&2
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "=== Script started at $(date '+%Y-%m-%d %H:%M:%S') ===" >&3
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "This script must be run as root."
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        DEBIAN_VERSION_ID="${VERSION_ID:-0}"
        if [ -z "${VERSION_CODENAME:-}" ] && [ -n "${VERSION:-}" ]; then
            DEBIAN_CODENAME=$(echo "$VERSION" | sed -n 's/.*(\(.*\)).*/\1/p')
        else
            DEBIAN_CODENAME="${VERSION_CODENAME:-unknown}"
        fi
    else
        echo "Error: Failed to determine Debian version (/etc/os-release not found)."
        exit 1
    fi

    if [ "$DEBIAN_CODENAME" = "unknown" ]; then
        echo "Error: Failed to determine Debian codename."
        exit 1
    fi
    echo "Detected OS: ${PRETTY_NAME:-$NAME $VERSION} (codename: $DEBIAN_CODENAME)"
}

configure_network_ips() {
    echo "--- Network Analysis ---"
    IPV4_LIST=($(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || ip -4 addr show | grep inet | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1))
    NUM_IPS=${#IPV4_LIST[@]}

    if [ "$NUM_IPS" -gt 1 ]; then
        echo "Found multiple IPv4 addresses:"
        for i in "${!IPV4_LIST[@]}"; do
            echo "[$i] ${IPV4_LIST[$i]}"
        done
        
        while true; do
            read -p "Do you want to use Inbound/Outbound split technology? (Y/N): " use_split
            case "$use_split" in
                [Yy]*) USE_SPLIT_NETWORK="true"; break ;;
                [Nn]*) break ;;
                *) echo "Invalid input. Please enter exactly Y or N." ;;
            esac
        done

        if [ "$USE_SPLIT_NETWORK" == "true" ]; then
            if [ "$NUM_IPS" -eq 2 ]; then
                INBOUND_IP=${IPV4_LIST[0]}
                OUTBOUND_IP=${IPV4_LIST[1]}
                echo "Auto-selected: Inbound=$INBOUND_IP, Outbound=$OUTBOUND_IP"
            else
                MAX_IDX=$((NUM_IPS - 1))
                while true; do
                    read -p "Select index for INBOUND IP (0-$MAX_IDX): " in_idx
                    if [[ "$in_idx" =~ ^[0-9]+$ ]] && [ "$in_idx" -ge 0 ] && [ "$in_idx" -le "$MAX_IDX" ]; then
                        INBOUND_IP=${IPV4_LIST[$in_idx]}
                        break
                    else
                        echo "Invalid index."
                    fi
                done
                while true; do
                    read -p "Select index for OUTBOUND IP (0-$MAX_IDX): " out_idx
                    if [[ "$out_idx" =~ ^[0-9]+$ ]] && [ "$out_idx" -ge 0 ] && [ "$out_idx" -le "$MAX_IDX" ]; then
                        OUTBOUND_IP=${IPV4_LIST[$out_idx]}
                        break
                    else
                        echo "Invalid index."
                    fi
                done
            fi
        else
            INBOUND_IP=${IPV4_LIST[0]:-""}
            OUTBOUND_IP=${IPV4_LIST[0]:-""}
        fi
    else
        INBOUND_IP=${IPV4_LIST[0]:-""}
        OUTBOUND_IP=${IPV4_LIST[0]:-""}
    fi

    if [ -z "$INBOUND_IP" ]; then
        INBOUND_IP=$(curl -s ifconfig.me 2>/dev/null || echo "127.0.0.1")
    fi
    if [ -z "$OUTBOUND_IP" ]; then
        OUTBOUND_IP="$INBOUND_IP"
    fi

    cat > /root/.network_config <<EOF
USE_SPLIT_NETWORK=$USE_SPLIT_NETWORK
INBOUND_IP=$INBOUND_IP
OUTBOUND_IP=$OUTBOUND_IP
EOF
}

fix_apt_sources() {
    echo "Checking and fixing APT sources..."
    if [ -d /etc/apt/sources.list.d ]; then
        for src in /etc/apt/sources.list.d/*.sources; do
            if [ -f "$src" ]; then
                echo "Found deb822 file: $src - moving to /root/apt-backups/"
                mkdir -p /root/apt-backups
                mv "$src" "/root/apt-backups/$(basename "$src").bak-$(date +%Y%m%d%H%M%S)"
            fi
        done
        for listfile in /etc/apt/sources.list.d/*.list; do
            if [ -f "$listfile" ]; then
                echo "Removing conflicting .list file: $listfile"
                mkdir -p /root/apt-backups
                mv "$listfile" "/root/apt-backups/$(basename "$listfile").bak-$(date +%Y%m%d%H%M%S)"
            fi
        done
    fi

    if [ "$DEBIAN_VERSION_ID" -le 10 ] 2>/dev/null; then
        cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian ${DEBIAN_CODENAME} main contrib non-free non-free-firmware
deb http://archive.debian.org/debian ${DEBIAN_CODENAME}-updates main contrib non-free non-free-firmware
EOF
    else
        cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${DEBIAN_CODENAME} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${DEBIAN_CODENAME}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${DEBIAN_CODENAME}-security main contrib non-free non-free-firmware
EOF
    fi

    if [ "$DEBIAN_VERSION_ID" -lt 12 ] 2>/dev/null; then
        sed -i 's/ non-free-firmware//g' /etc/apt/sources.list
    fi

    sed -i '/-backports/d' /etc/apt/sources.list 2>/dev/null || true
    echo "APT sources fixed."
}

update_system() {
    echo "# Install all updates."
    dpkg --configure -a
    apt-get clean -y && rm -rf /var/lib/apt/lists/*
    echo "# Updating package lists..."
    apt-get update -y || { echo "ERROR: apt update failed"; exit 1; }
    echo "# Full upgrade..."
    DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -o Dpkg::Options::="--force-confold" || { echo "ERROR: apt full-upgrade failed"; exit 1; }
    apt-get autoremove -y && apt-get autoclean
    apt-get autoremove --purge -y
    echo ""
}

setup_swap() {
    local SWAP_FILE="/swapfile"
    if swapon --show=NAME --noheadings --raw | grep -q "^${SWAP_FILE}$"; then
        echo "Swap file $SWAP_FILE is already active. Skipping swap creation."
        if ! grep -qF "$SWAP_FILE" /etc/fstab; then
            cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d%H%M%S)
            echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
            echo "Added swap entry to /etc/fstab."
        fi
    else
        echo "# Creating swap file (${SWAP_SIZE_MB} MB)..."
        if [ -f "$SWAP_FILE" ]; then
            swapoff "$SWAP_FILE" 2>/dev/null || true
            rm -f "$SWAP_FILE"
        fi
        if fallocate -l "${SWAP_SIZE_MB}M" "$SWAP_FILE" 2>/dev/null; then
            echo "Using fallocate."
        else
            echo "fallocate not supported, using dd..."
            dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB" status=progress
        fi
        chmod 600 "$SWAP_FILE"
        mkswap "$SWAP_FILE"
        swapon "$SWAP_FILE"
        cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d%H%M%S)
        sed -i "\\#^$SWAP_FILE#d" /etc/fstab
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
        echo "Swap configured."
    fi
}

ask_hostname() {
    printf "\\033[33m# Change PRETTY hostname!!!\\033[0m\\n"
    while true; do
        read -p "Type new PRETTY hostname here: " NEW_HOSTNAME
        if [ -n "$NEW_HOSTNAME" ]; then
            break
        else
            echo "Hostname cannot be empty. Please enter a valid name."
        fi
    done
    hostnamectl set-hostname "$NEW_HOSTNAME" --pretty
    echo ""
}

harden_network() {
    echo "Hard-disabling IPv6 and blocking ICMP..."
    cat > /etc/sysctl.d/99-hardened.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv4.icmp_echo_ignore_all = 1
EOF

    if ! grep -q "ipv6.disable=1" /etc/default/grub; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="ipv6.disable=1 /' /etc/default/grub
        update-grub || true
    fi
    sysctl --system

    if systemctl is-active --quiet exim4 2>/dev/null || systemctl is-failed --quiet exim4 2>/dev/null; then
        systemctl stop exim4 2>/dev/null || true
        systemctl disable exim4 2>/dev/null || true
    fi
}

configure_ssh() {
    echo ""
    printf "\\033[33m# Configure SSH to listen on specified ports.\\033[0m\\n"
    mkdir -p /etc/ssh/sshd_config.d
    
    > /etc/ssh/sshd_config.d/99-custom.conf
    for port in "${SSH_PORTS[@]}"; do
        echo "Port $port" >> /etc/ssh/sshd_config.d/99-custom.conf
    done

    cat >> /etc/ssh/sshd_config.d/99-custom.conf <<EOF
$([ "$USE_SPLIT_NETWORK" == "true" ] && echo "ListenAddress 127.0.0.1" || true)
$([ "$USE_SPLIT_NETWORK" == "true" ] && [ -n "$INBOUND_IP" ] && echo "ListenAddress $INBOUND_IP" || true)
PermitRootLogin without-password
PubkeyAuthentication yes
EOF

    if ! grep -q "^Include /etc/ssh/sshd_config.d/\*.conf" /etc/ssh/sshd_config; then
        sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
    fi

    if sshd -t; then
        systemctl reload ssh
        echo "SSH service reloaded successfully."
    else
        echo "SSH configuration syntax error. Reload aborted."
    fi
    echo ""
}

install_packages() {
    echo "# Install standard tools and security packages..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y sudo ufw cron rsyslog mc curl wget unzip p7zip-full htop unattended-upgrades apt-listchanges bsd-mailx iptables fail2ban dos2unix locales screen dnsutils openssl gpg autossh python3-systemd
}

configure_locales() {
    echo "Set UTF-8 locales."
    locale-gen en_US.UTF-8 ru_RU.UTF-8
    if ! locale -a | grep -qi "ru_ru\.utf8\|ru_ru\.utf-8"; then
        echo "ru_RU.UTF-8 not found, forcing generation..."
        sed -i 's/^# ru_RU.UTF-8/ru_RU.UTF-8/' /etc/locale.gen
        locale-gen ru_RU.UTF-8
    fi
    cat > /etc/default/locale <<EOF
LANG=ru_RU.UTF-8
EOF
    if ! grep -q "^LANG=" /etc/environment 2>/dev/null; then
        echo "LANG=ru_RU.UTF-8" >> /etc/environment
    fi
    export LANG=ru_RU.UTF-8
    unset LC_ALL LC_CTYPE LC_MESSAGES 2>/dev/null || true
    echo ""
}

configure_fail2ban() {
    echo "Configuring Fail2ban..."
    systemctl enable fail2ban.service
    cat > /etc/fail2ban/fail2ban.local <<EOF
[Definition]
allowipv6 = auto
EOF

    local ignore_ips="$F2B_IGNORE_IPS"
    if [ "$USE_SPLIT_NETWORK" == "true" ] && [ -n "$INBOUND_IP" ]; then
        ignore_ips="$INBOUND_IP $OUTBOUND_IP $ignore_ips"
    fi

    local f2b_sshd_log=""
    if [ "$DEBIAN_VERSION_ID" -lt 12 ] 2>/dev/null; then
        f2b_sshd_log="logpath = %(sshd_log)s"
    fi

    local f2b_backend_line=""
    if [ "$DEBIAN_VERSION_ID" -ge 12 ] 2>/dev/null; then
        f2b_backend_line="backend = systemd"
    fi

    local ports_csv=$(IFS=,; echo "${SSH_PORTS[*]}")

    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 7d
findtime = 180m
maxretry = 4
ignoreip = $ignore_ips
$f2b_backend_line

[sshd]
enabled = true
port = $ports_csv
$f2b_sshd_log
EOF

    if fail2ban-client -t >/dev/null 2>&1; then
        systemctl restart fail2ban.service
        sleep 2
        if systemctl is-active --quiet fail2ban.service; then
            echo "Fail2ban is active and protecting SSH."
        else
            echo "WARNING: Fail2ban failed to start."
        fi
    else
        echo "ERROR: Fail2ban configuration invalid."
        exit 1
    fi
    echo ""
}

configure_unattended_upgrades() {
    echo "# Configuring unattended-upgrades..."
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Mail "root";
Unattended-Upgrade::MailOnlyOnError "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "00:01";
EOF
    systemctl enable unattended-upgrades
    systemctl restart unattended-upgrades
    echo ""
}

configure_profile() {
    if ! grep -q "screen -ls | grep -q" ~/.profile; then
        cat >> ~/.profile << 'EOF'

if screen -ls | grep -q "Detached"; then
    screen -r 2>/dev/null
fi
sleep 2
sudo mc 2>/dev/null
EOF
    fi
}

ask_master_password_and_extract() {
    wget -O setup.7z "$SETUP_ARCHIVE_URL"
    if [ ! -s setup.7z ]; then
        echo "Error: downloaded file is empty"
        exit 1
    fi

    MASTER_PASSWORD=""
    for attempt in {1..5}; do
        read -s -p "Enter master password for setup & user (attempt $attempt/5): " MASTER_PASSWORD
        echo
        if 7za x -p"$MASTER_PASSWORD" setup.7z -aoa >/dev/null 2>&1; then
            echo "Archive extracted successfully."
            break
        else
            echo "Wrong password."
            if [ $attempt -eq 5 ]; then
                echo "Failed to extract archive after 5 attempts. Exiting."
                exit 1
            fi
        fi
    done
    rm -f setup.7z

    echo "Fixing permissions..."
    chmod 700 ~/.config/htop 2>/dev/null || true
    chmod 700 ~/.config/mc 2>/dev/null || true
    chmod 700 ~/.ssh
    chmod 600 ~/.ssh/* 2>/dev/null
    chmod 644 ~/.ssh/*.pub 2>/dev/null
    chmod 600 ~/.ssh/authorized_keys 2>/dev/null
    chmod 644 ~/.ssh/known_hosts 2>/dev/null
    chmod 644 ~/.ssh/config 2>/dev/null
    chmod +x ~/*.sh 2>/dev/null
    echo ""
}

apply_system_passwords() {
    if [ -f ~/.ssh/passwd.txt ]; then
       chpasswd < ~/.ssh/passwd.txt
    fi
}

setup_users() {
    printf "\\033[33m# Add ordinary user OPOSSUM with PASSWORD!\\033[0m\\n"
    if grep -q "^opossum:" /etc/passwd; then
        echo "User opossum already exists. Updating password..."
        local pass=$(openssl passwd -6 "$MASTER_PASSWORD")
        usermod -p "$pass" opossum
        usermod -aG sudo opossum 2>/dev/null || true
        echo "Password for opossum updated."
    else
        local pass=$(openssl passwd -6 "$MASTER_PASSWORD")
        useradd -m -p "$pass" opossum
        if [ $? -eq 0 ]; then
            echo "User opossum added to system!"
            usermod -aG sudo opossum
        else
            echo "Failed to add user!"
        fi
    fi

    if [ -d /home/opossum ]; then
        if [ -f /root/opossum.7z ]; then
            cp /root/opossum.7z /home/opossum/
            cd /home/opossum
            7za x -p"$MASTER_PASSWORD" opossum.7z -aoa
            rm -f opossum.7z
            chmod +x opossum.sh 2>/dev/null || true
            chown -R opossum:opossum /home/opossum
            cd /root
        else
            echo "/root/opossum.7z not found, skipping opossum setup."
        fi
    fi

    unset MASTER_PASSWORD
    echo ""
}

cleanup_markers() {
    systemctl reset-failed 2>/dev/null || true
    local safe_name=$(echo "$NEW_HOSTNAME" | tr ' ' '_' | tr -cd '[:alnum:]_-')
    for old_marker in /root/zzz-*; do
        if [ -f "$old_marker" ] && [ "$(basename "$old_marker")" != "zzz-$safe_name" ]; then
            rm -f "$old_marker"
            echo "Removed old marker: $old_marker"
        fi
    done
    touch "/root/zzz-$safe_name"
    echo ""
}

configure_ufw() {
    echo "Configuring UFW firewall..."
    for port in "${SSH_PORTS[@]}"; do
        if [ "$USE_SPLIT_NETWORK" == "true" ] && [ -n "$INBOUND_IP" ]; then
            ufw delete allow to "$INBOUND_IP" port "$port" proto tcp 2>/dev/null || true
            ufw allow to "$INBOUND_IP" port "$port" proto tcp
            echo "Allowed SSH port $port on $INBOUND_IP in UFW."
        else
            ufw delete allow "$port/tcp" 2>/dev/null || true
            ufw allow "$port/tcp"
            echo "Allowed SSH port $port in UFW."
        fi
    done
    echo "SSH ports are allowed."
    echo ""
}

setup_reverse_tunnel() {
    echo "=============================================="
    echo " Setting up Reverse SSH Tunnel to OpenWrt "
    echo "=============================================="
    local KEY_PATH="/root/.ssh/ssh2router-key"
    local REVERSE_LOG="/root/reverse_ssh.log"

    if [ ! -f "$KEY_PATH" ]; then
        echo "Warning: $KEY_PATH not found. Reverse tunnel setup skipped." | tee -a "$REVERSE_LOG"
        return
    fi

    chmod 600 "$KEY_PATH"
    local LOCAL_SSH_PORT=$(ss -tlnp | grep 'sshd' | awk '{print $4}' | awk -F':' '{print $NF}' | sort -rn | head -n 1)
    if [ -z "$LOCAL_SSH_PORT" ]; then
        LOCAL_SSH_PORT=22
    fi
    
    echo "Local SSH port: $LOCAL_SSH_PORT" | tee -a "$REVERSE_LOG"
    local NAME_PREFIX=$(echo "$NEW_HOSTNAME" | grep -oE '[0-9]{2}' | head -n 1)
    local DEFAULT_REVERSE_PORT="25900"
    
    if [ -n "$NAME_PREFIX" ]; then
        DEFAULT_REVERSE_PORT="259$NAME_PREFIX"
    fi
    
    printf "Enter REMOTE port on OpenWrt (default %s): " "$DEFAULT_REVERSE_PORT"
    read USER_INPUT_PORT
    local REVERSE_PORT=${USER_INPUT_PORT:-$DEFAULT_REVERSE_PORT}
    
    if ! [[ "$REVERSE_PORT" =~ ^[0-9]+$ ]]; then
        echo "Error: port must be a number, skipping tunnel setup." | tee -a "$REVERSE_LOG"
        return
    fi

    local SERVICE_TEMPLATE="/etc/systemd/system/reverse-tunnel@.service"
    local SERVICE_INSTANCE="reverse-tunnel@${REVERSE_PORT}.service"
    
    mapfile -t EXISTING_SERVICES < <(systemctl list-units --type=service --all "reverse-tunnel@*" --no-legend 2>/dev/null | awk '{print $1}')
    if [ ${#EXISTING_SERVICES[@]} -gt 0 ]; then
        echo "Found existing tunnel services:" | tee -a "$REVERSE_LOG"
        for i in "${!EXISTING_SERVICES[@]}"; do
            printf "[%d] %s\n" "$((i+1))" "${EXISTING_SERVICES[$i]}"
        done | tee -a "$REVERSE_LOG"
        echo "Options: [Number] delete specific, [A]ll delete all, [S]kip to add new"
        read -p "Select action: " ACTION
        case "$ACTION" in
            [aA]* )
                for svc in "${EXISTING_SERVICES[@]}"; do
                    systemctl stop "$svc" 2>/dev/null || true
                    systemctl disable "$svc" 2>/dev/null || true
                done
                ;;
            [sS]* | "" ) ;;
            [0-9]* )
                local IDX=$((ACTION-1))
                if [ "$IDX" -ge 0 ] && [ "$IDX" -lt "${#EXISTING_SERVICES[@]}" ]; then
                    local SELECTED_SVC="${EXISTING_SERVICES[$IDX]}"
                    systemctl stop "$SELECTED_SVC" 2>/dev/null || true
                    systemctl disable "$SELECTED_SVC" 2>/dev/null || true
                fi
                ;;
        esac
    fi
    
    local BIND_ADDR_OPTION=""
    if [ "$USE_SPLIT_NETWORK" == "true" ] && [ -n "$OUTBOUND_IP" ]; then
        BIND_ADDR_OPTION="-o \"BindAddress=$OUTBOUND_IP\""
    fi

    cat > "$SERVICE_TEMPLATE" <<EOF
[Unit]
Description=Reverse SSH Tunnel to OpenWrt on port %i
After=network.target

[Service]
User=root
Group=root
Environment="AUTOSSH_GATETIME=0"

ExecStart=/usr/bin/autossh -M 0 -N \\
    -o "StrictHostKeyChecking=no" \\
    -o "UserKnownHostsFile=/dev/null" \\
    $BIND_ADDR_OPTION \\
    -o "ServerAliveInterval=60" \\
    -o "ServerAliveCountMax=3" \\
    -o "ExitOnForwardFailure=yes" \\
    -o "TCPKeepAlive=yes" \\
    -i $KEY_PATH \\
    -p $ROUTER_PORT \\
    -R %i:127.0.0.1:$LOCAL_SSH_PORT \\
    $ROUTER_USER@$ROUTER_HOST

Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_INSTANCE"
    systemctl restart "$SERVICE_INSTANCE"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_INSTANCE"; then
        echo "Tunnel service $SERVICE_INSTANCE is active." | tee -a "$REVERSE_LOG"
    else
        echo "ERROR: Tunnel service $SERVICE_INSTANCE failed to start." | tee -a "$REVERSE_LOG"
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] REVERSE Tunnel: ${ROUTER_HOST}:${REVERSE_PORT} -> ${NEW_HOSTNAME}:${LOCAL_SSH_PORT} (Status: $(systemctl is-active "$SERVICE_INSTANCE"))" >> "$REVERSE_LOG"
}

install_telemt_proxy() {
    echo "# Installing telemt MTProto proxy (Docker Compose V2)..."
    if ! command -v docker >/dev/null; then
        apt-get update
        apt-get install -y docker.io
        systemctl enable --now docker
    fi
    if ! docker info >/dev/null 2>&1; then
        systemctl start docker
    fi

    if ! docker compose version >/dev/null 2>&1; then
        echo "Installing docker-compose-plugin..."
        apt-get update
        apt-get install -y docker-compose-plugin || {
            echo "Fallback: Downloading Docker Compose V2 binary from GitHub..."
            mkdir -p /usr/libexec/docker/cli-plugins
            curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" -o /usr/libexec/docker/cli-plugins/docker-compose
            chmod +x /usr/libexec/docker/cli-plugins/docker-compose
        }
    fi
    local DOCKER_COMPOSE_CMD="docker compose"

    command -v apparmor_parser >/dev/null || { apt-get update && apt-get install -y apparmor; }
    command -v openssl >/dev/null || { apt-get update && apt-get install -y openssl; }
    command -v xxd >/dev/null || { apt-get update && apt-get install -y xxd; }
    command -v ufw >/dev/null || { apt-get update && apt-get install -y ufw; }

    if [ "$USE_SPLIT_NETWORK" == "true" ] && [ -n "$INBOUND_IP" ]; then
        EXTERNAL_IP="$INBOUND_IP"
        echo "Split-network active: using Inbound IP ($EXTERNAL_IP) for proxy link."
    else
        EXTERNAL_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || curl -s icanhazip.com)
        if [ -z "$EXTERNAL_IP" ]; then
            EXTERNAL_IP="127.0.0.1"
        fi
    fi

    local INSTALL_DIR="/etc/telemt-docker"
    local CONFIG_DIR="$INSTALL_DIR/config"
    mkdir -p "$CONFIG_DIR"
    cd "$INSTALL_DIR"

    local SECRET=""
    if [ -f "$CONFIG_DIR/telemt.toml" ]; then
        SECRET=$(grep -oP "${PROXY_USER}\s*=\s*\"\K[a-f0-9]+" "$CONFIG_DIR/telemt.toml" 2>/dev/null | tail -1)
    fi
    if [ -z "$SECRET" ]; then
        SECRET=$(openssl rand -hex 16)
        echo "Generated new MTProto proxy secret."
    fi

    local TLS_DOMAIN_HEX=$(printf "%s" "$PROXY_DOMAIN" | xxd -p -c 1000 | tr -d '\\n')
    local FULL_SECRET="ee${SECRET}${TLS_DOMAIN_HEX}"

    cat > "$CONFIG_DIR/telemt.toml" <<EOF
[general]
use_middle_proxy = false
[general.modes]
classic = false
secure = false
tls = true
[server]
port = $PROXY_PORT
[server.api]
enabled = true
listen = "127.0.0.1:9091"
[censorship]
tls_domain = "$PROXY_DOMAIN"
[access.users]
$PROXY_USER = "$SECRET"
EOF
    chmod -R 777 "$CONFIG_DIR"

    local TELEMT_PORT_BIND="$PROXY_PORT"
    if [ "$USE_SPLIT_NETWORK" == "true" ] && [ -n "$INBOUND_IP" ]; then
        TELEMT_PORT_BIND="$INBOUND_IP:$PROXY_PORT"
    fi

    cat > docker-compose.yml <<EOF
version: '3.3'
services:
  telemt:
    image: whn0thacked/telemt-docker:latest
    container_name: telemt
    restart: unless-stopped
    ports:
      - "$TELEMT_PORT_BIND:$PROXY_PORT"
    environment:
      RUST_LOG: info
    volumes:
      - "$CONFIG_DIR:/etc/telemt"
    command: ["/etc/telemt/telemt.toml"]
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    tmpfs:
      - /tmp:rw,nosuid,nodev,noexec,size=16m
    ulimits:
      nofile: 65536
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

    if [ "$USE_SPLIT_NETWORK" == "true" ] && [ -n "$INBOUND_IP" ]; then
        ufw delete allow to "$INBOUND_IP" port "$PROXY_PORT" proto tcp 2>/dev/null || true
        ufw allow to "$INBOUND_IP" port "$PROXY_PORT" proto tcp
    else
        ufw delete allow "$PROXY_PORT/tcp" 2>/dev/null || true
        ufw allow "$PROXY_PORT/tcp"
    fi
    echo "$PROXY_PORT" > "$INSTALL_DIR/ufw_port.txt"
    
    $DOCKER_COMPOSE_CMD up -d
    sleep 5
    if docker ps --format '{{.Names}}' | grep -q "^telemt$"; then
        echo "Telemt container is running."
    else
        echo "ERROR: Telemt container failed to start."
    fi
    
    local LINK="tg://proxy?server=${EXTERNAL_IP}&port=${PROXY_PORT}&secret=${FULL_SECRET}"
    echo "$LINK" > /root/tg-proxy_secret.txt
    echo "Telemt proxy installed. Link saved to /root/tg-proxy_secret.txt"
}

configure_cron() {
    local CRON_TMP=$(mktemp)
    crontab -l 2>/dev/null > "$CRON_TMP" || echo "# New crontab" > "$CRON_TMP"

    add_cron_job() {
        if ! grep -Fxq "$1" "$CRON_TMP"; then
            echo "$1" >> "$CRON_TMP"
        fi
    }

    add_cron_job "@reboot         date >> /root/reboot.log"
    add_cron_job "0 0 1 * *       date > /root/reboot.log"
    add_cron_job "1 */2 * * *     /root/telemt-update.sh"
    add_cron_job "5 */3 * * *     /root/auto-update.sh"
    add_cron_job "*/5 * * * *     systemctl reset-failed"

    crontab "$CRON_TMP"
    rm -f "$CRON_TMP"
    echo "Crontab successfully updated."
}

finalize_and_reboot() {
    echo ""
    printf "\\033[33mLast update and finalizing.\\033[0m\\n"
    apt-get clean -y && rm -rf /var/lib/apt/lists/* && apt-get update -y && apt-get full-upgrade -y -o Dpkg::Options::="--force-confold" && apt-get autoremove -y && apt-get autoclean
    apt-get autoremove --purge -y

    if [ "$USE_SPLIT_NETWORK" == "true" ] && [ -n "$OUTBOUND_IP" ]; then
        local MAIN_IFACE=$(ip -4 route | grep default | awk '{print $5}' | head -n1)
        local GATEWAY=$(ip -4 route | grep default | awk '{print $3}' | head -n1)
        
        if [ -z "$GATEWAY" ] || [ -z "$MAIN_IFACE" ]; then
            echo "WARNING: Could not detect Gateway or Interface. Skipping outbound route setup."
        else
            local IP_BIN=$(command -v ip)
            cat > /etc/systemd/system/set-outbound-route.service <<EOF
[Unit]
Description=Set default outbound IP route
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$IP_BIN route replace default via $GATEWAY dev $MAIN_IFACE src $OUTBOUND_IP
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
            systemctl enable set-outbound-route.service
            
            if ! $IP_BIN route replace default via "$GATEWAY" dev "$MAIN_IFACE" src "$OUTBOUND_IP" 2>/dev/null; then
                echo "ERROR: Failed to apply outbound route."
                systemctl disable set-outbound-route.service
            else
                echo "Outbound route configured to use $OUTBOUND_IP"
            fi
        fi
    fi

    echo "Enabling UFW..."
    ufw --force enable
    ufw status verbose

    echo "REBOOT in 5s..."
    sleep 5
    reboot now
}

# ==============================================================================
# === MAIN EXECUTION ===
# ==============================================================================

init_logging
check_root
detect_os
configure_network_ips
fix_apt_sources
update_system
setup_swap
ask_hostname
harden_network
configure_ssh
install_packages
configure_locales
configure_fail2ban
configure_unattended_upgrades
configure_profile
ask_master_password_and_extract
apply_system_passwords
setup_users
cleanup_markers
configure_ufw
setup_reverse_tunnel
install_telemt_proxy
configure_cron
finalize_and_reboot