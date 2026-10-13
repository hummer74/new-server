#!/bin/bash
set -euo pipefail

# ==============================================================================
# === CONFIGURATION (defaults, override via ./config.env next to script) ===
# === Split-IP (INBOUND/OUTBOUND) — только авто-детект, хардкода адресов нет ===
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Logging
LOG_FILE="/root/new-server.log"

# System settings
SWAP_SIZE_MB=512
SSH_PORTS=(22 24940)

# Security & Fail2ban
F2B_IGNORE_IPS="176.56.1.165 95.78.162.177 45.86.86.195 46.29.239.23 45.151.139.193 45.38.143.206 217.60.252.204 176.125.243.194 194.58.68.23"
F2B_BANTIME="30d"
F2B_FINDTIME="1440m"
F2B_MAXRETRY=4

# Setup Archive
SETUP_ARCHIVE_URL="https://raw.githubusercontent.com/hummer74/new-server/main/setup.7z"

# Reverse SSH Tunnel
ROUTER_USER="tunneluser"
ROUTER_HOST="mousehouse.ignorelist.com"
ROUTER_PORT=24930

# Tailscale (optional step: local file next to script wins, else URL)
TAILSCALE_INSTALL_URL="https://raw.githubusercontent.com/hummer74/new-server/main/tailscale-insall.sh"

# Locale
SYSTEM_LANG="ru_RU.UTF-8"

# Override defaults from config.env if present (script dir or /root/)
if [ -f "$SCRIPT_DIR/config.env" ]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/config.env"
elif [ -f /root/config.env ]; then
    # shellcheck disable=SC1091
    source /root/config.env
fi
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
        # On Debian testing/unstable, VERSION_ID might be empty. Default to 0.
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
    if [ "${ID:-}" != "debian" ]; then
        echo "Error: only Debian is supported (detected ID=${ID:-unknown})."
        exit 1
    fi
    if [ "$DEBIAN_VERSION_ID" -lt 11 ] 2>/dev/null; then
        echo "Error: Debian 11+ required (detected $DEBIAN_VERSION_ID)."
        exit 1
    fi
    echo "Detected OS: ${PRETTY_NAME:-$NAME $VERSION} (codename: $DEBIAN_CODENAME)"
}

configure_network_ips() {
    echo "--- Network Analysis ---"
    # All global IPv4 addresses on all interfaces (route-based src yields only
    # ONE address, so it must not be the primary source for split detection).
    IPV4_LIST=($(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u))
    if [ "${#IPV4_LIST[@]}" -eq 0 ]; then
        IPV4_LIST=($(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || ip -4 addr show | grep inet | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1))
    fi
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

    cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${DEBIAN_CODENAME} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${DEBIAN_CODENAME}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${DEBIAN_CODENAME}-security main contrib non-free non-free-firmware
EOF

    # Remove non-free-firmware only for Debian versions strictly older than 12
    if [[ "$DEBIAN_VERSION_ID" =~ ^(8|9|10|11)$ ]]; then
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
    echo "IPv6 stays ENABLED. Blocking echo/probing, enabling forwarding..."
    cat > /etc/sysctl.d/99-hardened.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.icmp_echo_ignore_all = 1
net.ipv6.icmp.echo_ignore_all = 1
EOF
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
PermitRootLogin yes
PasswordAuthentication yes
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
    DEBIAN_FRONTEND=noninteractive apt-get install -y sudo ufw cron rsyslog mc curl wget unzip p7zip-full htop unattended-upgrades apt-listchanges bsd-mailx iptables fail2ban dos2unix locales screen dnsutils openssl gpg autossh python3-systemd git nftables iptables-persistent wireguard-tools jq needrestart
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
LANG=$SYSTEM_LANG
EOF
    if ! grep -q "^LANG=" /etc/environment 2>/dev/null; then
        echo "LANG=$SYSTEM_LANG" >> /etc/environment
    fi
    export LANG="$SYSTEM_LANG"
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

    # Fix logic for missing logpath in newer Debian
    local f2b_sshd_log=""
    if [[ "$DEBIAN_VERSION_ID" =~ ^(8|9|10|11)$ ]]; then
        f2b_sshd_log="logpath = %(sshd_log)s"
    fi

    local f2b_backend_line=""
    if ! [[ "$DEBIAN_VERSION_ID" =~ ^(8|9|10|11)$ ]]; then
        f2b_backend_line="backend = systemd"
    fi

    local ports_csv=$(IFS=,; echo "${SSH_PORTS[*]}")

    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = $F2B_BANTIME
findtime = $F2B_FINDTIME
maxretry = $F2B_MAXRETRY
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
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "00:01";
EOF
    systemctl enable unattended-upgrades
    systemctl restart unattended-upgrades
    echo ""
}

configure_profile() {
    if ! grep -q 'mc-interactive-guard' ~/.profile; then
        cat >> ~/.profile << 'EOF'

# mc-interactive-guard: only for interactive shells (keeps scp/sftp working)
[[ $- == *i* ]] && { sudo mc 2>/dev/null; }
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
    # '|| true' appended to prevent script crash due to 'set -e' if mask matches nothing
    chmod 600 ~/.ssh/* 2>/dev/null || true
    chmod 644 ~/.ssh/*.pub 2>/dev/null || true
    chmod 600 ~/.ssh/authorized_keys 2>/dev/null || true
    chmod 644 ~/.ssh/known_hosts 2>/dev/null || true
    chmod 644 ~/.ssh/config 2>/dev/null || true
    chmod +x ~/*.sh 2>/dev/null || true
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
    echo "Configuring UFW firewall (IPv4+IPv6)..."
    if [ -f /etc/default/ufw ] && ! grep -q "^IPV6=yes" /etc/default/ufw; then
        sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
    fi
    ufw default deny incoming || true
    ufw default allow outgoing || true
    for port in "${SSH_PORTS[@]}"; do
        if [ "$USE_SPLIT_NETWORK" == "true" ] && [ -n "$INBOUND_IP" ]; then
            ufw delete allow to "$INBOUND_IP" port "$port" proto tcp 2>/dev/null || true
            ufw allow to "$INBOUND_IP" port "$port" proto tcp
            ufw delete limit to "$INBOUND_IP" port "$port" proto tcp 2>/dev/null || true
            ufw limit to "$INBOUND_IP" port "$port" proto tcp 2>/dev/null || true
            echo "Allowed+limited SSH port $port on $INBOUND_IP in UFW."
        else
            ufw delete allow "$port/tcp" 2>/dev/null || true
            ufw allow "$port/tcp"
            echo "Allowed SSH port $port in UFW."
            ufw limit "$port/tcp" 2>/dev/null || true
        fi
    done
    if [ -f /etc/wireguard/wg0.conf ]; then
        ufw allow 51820/udp 2>/dev/null || true
        echo "Allowed WireGuard 51820/udp (wg0.conf exists)."
    fi
    echo "SSH ports are allowed (deny incoming, limit enabled, IPv6 on)."
    echo ""
}

setup_reverse_tunnel() {
    echo "=============================================="
    echo " Setting up Reverse SSH Tunnel to OpenWrt "
    echo "=============================================="
    local KEY_PATH="/root/.ssh/ssh2router-key"
    local REVERSE_LOG="/root/reverse_ssh.log"

    if [ ! -f "$KEY_PATH" ]; then
        echo "ERROR: $KEY_PATH not found (it arrives inside setup.7z -> /root/.ssh/)." | tee -a "$REVERSE_LOG"
        echo "Reverse tunnel cannot be set up without this private key."
        while true; do
            read -p "Abort installation [q] or continue WITHOUT tunnel [c]? (q/c): " key_choice
            case "$key_choice" in
                [Qq]*) echo "Aborted by user (missing ssh2router key)."; exit 1 ;;
                [Cc]*) echo "Continuing without reverse tunnel." | tee -a "$REVERSE_LOG"; return 0 ;;
                *) echo "Enter q or c." ;;
            esac
        done
    fi

    chmod 600 "$KEY_PATH"
    # Deterministic: senior SSH port from config, not from ss parsing
    local LOCAL_SSH_PORT="${SSH_PORTS[${#SSH_PORTS[@]}-1]}"
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
    
    # Bind outbound socket to OUTBOUND_IP only if that IP really exists locally.
    # No hardcoded addresses: values come only from auto-detected $OUTBOUND_IP.
    # BIND_OPT expands inline (no extra continuation line -> no broken ExecStart).
    local BIND_OPT=""
    if [ "$USE_SPLIT_NETWORK" == "true" ] && [ -n "${OUTBOUND_IP:-}" ]; then
        if ip -4 addr show | grep -qw "$OUTBOUND_IP"; then
            BIND_OPT="-o BindAddress=$OUTBOUND_IP"
        else
            echo "WARNING: OUTBOUND_IP=$OUTBOUND_IP not found locally, connecting via default route." | tee -a "$REVERSE_LOG"
        fi
    fi

    cat > "$SERVICE_TEMPLATE" <<EOF
[Unit]
Description=Reverse SSH Tunnel to OpenWrt on port %i
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
    -p $ROUTER_PORT \\
    -R %i:127.0.0.1:$LOCAL_SSH_PORT \\
    $ROUTER_USER@$ROUTER_HOST

Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    # Guard against the 127:0:0:1 corruption (dots must stay dots)
    if ! grep -q '127\.0\.0\.1' "$SERVICE_TEMPLATE"; then
        echo "ERROR: generated $SERVICE_TEMPLATE has no 127.0.0.1 — refusing to enable." | tee -a "$REVERSE_LOG"
        echo "Check BIND_OPT/quoting, template left on disk for inspection."
        return 1
    fi
    if command -v systemd-analyze >/dev/null 2>&1; then
        systemd-analyze verify "$SERVICE_TEMPLATE" 2>&1 | tee -a "$REVERSE_LOG" || true
    fi
    systemctl daemon-reload
    systemctl enable "$SERVICE_INSTANCE"
    systemctl restart "$SERVICE_INSTANCE"
    sleep 3
    if systemctl is-active --quiet "$SERVICE_INSTANCE"; then
        echo "Tunnel service $SERVICE_INSTANCE is active." | tee -a "$REVERSE_LOG"
    else
        echo "ERROR: Tunnel service $SERVICE_INSTANCE failed to start." | tee -a "$REVERSE_LOG"
        journalctl -u "$SERVICE_INSTANCE" --no-pager -n 15 | tee -a "$REVERSE_LOG" || true
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] REVERSE Tunnel: ${ROUTER_HOST}:${REVERSE_PORT} -> ${NEW_HOSTNAME}:${LOCAL_SSH_PORT} (Status: $(systemctl is-active "$SERVICE_INSTANCE"))" >> "$REVERSE_LOG"
}

setup_tailscale_exit_node() {
    echo "=============================================="
    echo " Optional: Tailscale Exit Node "
    echo "=============================================="
    while true; do
        read -p "Install and configure Tailscale as Exit Node? [y/N]: " ts_answer
        case "$ts_answer" in
            [Yy]*) break ;;
            [Nn]*|"") echo "Skipping Tailscale setup."; return 0 ;;
            *) echo "Enter y or N." ;;
        esac
    done

    echo ">>> Installing Tailscale..."
    if ! command -v tailscale >/dev/null 2>&1; then
        if [ -f "$SCRIPT_DIR/tailscale-insall.sh" ]; then
            bash "$SCRIPT_DIR/tailscale-insall.sh"
        else
            bash -c "$(curl -fsSL "$TAILSCALE_INSTALL_URL")"
        fi
        sleep 2
    else
        echo "Tailscale already installed."
    fi

    echo ">>> Ensuring IP forwarding (IPv6 stays enabled)..."
    grep -q "^net.ipv4.ip_forward" /etc/sysctl.d/99-hardened.conf 2>/dev/null || echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/99-hardened.conf
    grep -q "^net.ipv6.conf.all.forwarding" /etc/sysctl.d/99-hardened.conf 2>/dev/null || echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.d/99-hardened.conf
    sysctl --system >/dev/null 2>&1 || echo "   (Some sysctl keys not applied — ok if kernel lacks IPv6)"

    echo ">>> Connecting to Tailscale and advertising Exit Node..."
    echo "    (Approve login URL if shown, then approve Exit Node in Admin Console)"
    if ! tailscale up --advertise-exit-node; then
        echo "WARNING: 'tailscale up' failed (login not completed?). Continuing without Exit Node SNAT."
        echo "Rerun later: tailscale up --advertise-exit-node (or standalone tailscale-exit-node.sh)."
        return 0
    fi
    echo ">>> Waiting for network settings..."
    sleep 3

    # Outbound IP: split-network OUTBOUND_IP wins, no hardcoded addresses
    local TS_OUTBOUND_IP=""
    if [ "$USE_SPLIT_NETWORK" == "true" ] && [ -n "${OUTBOUND_IP:-}" ]; then
        TS_OUTBOUND_IP="$OUTBOUND_IP"
        echo "Split-network active: using Outbound IP ($TS_OUTBOUND_IP) for Exit Node SNAT."
    else
        if command -v curl >/dev/null 2>&1; then
            TS_OUTBOUND_IP=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || true)
        fi
        if [ -z "${TS_OUTBOUND_IP:-}" ]; then
            TS_OUTBOUND_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)
        fi
    fi

    if [ -z "${TS_OUTBOUND_IP:-}" ]; then
        echo "WARNING: Could not detect outbound IP. Skipping SNAT (default MASQUERADE stays)."
    else
        echo "   Outbound IP: $TS_OUTBOUND_IP"
        echo ">>> Configuring SNAT for Exit Node traffic..."
        if iptables -t nat -L ts-postrouting &>/dev/null; then
            iptables -t nat -D ts-postrouting -m mark --mark 0x40000/0xff0000 -j MASQUERADE 2>/dev/null || true
            if ! iptables -t nat -C ts-postrouting -m mark --mark 0x40000/0xff0000 -j SNAT --to-source "$TS_OUTBOUND_IP" 2>/dev/null; then
                iptables -t nat -A ts-postrouting -m mark --mark 0x40000/0xff0000 -j SNAT --to-source "$TS_OUTBOUND_IP"
            fi
            echo "   Rule applied."
        else
            echo "   Chain ts-postrouting not ready yet, rule will apply at boot."
        fi

        echo ">>> Creating fix-exit-node-ip.service..."
        cat > /etc/systemd/system/fix-exit-node-ip.service <<EOF
[Unit]
Description=Fix Exit Node SNAT IP to $TS_OUTBOUND_IP
After=tailscaled.service
Requires=tailscaled.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'iptables -t nat -D ts-postrouting -m mark --mark 0x40000/0xff0000 -j MASQUERADE 2>/dev/null; iptables -t nat -C ts-postrouting -m mark --mark 0x40000/0xff0000 -j SNAT --to-source $TS_OUTBOUND_IP 2>/dev/null || iptables -t nat -A ts-postrouting -m mark --mark 0x40000/0xff0000 -j SNAT --to-source $TS_OUTBOUND_IP'

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable fix-exit-node-ip.service
        echo "   Service fix-exit-node-ip.service enabled."
    fi

    systemctl enable tailscaled &>/dev/null || true

    echo ""
    echo "=== Tailscale Exit Node ready ==="
    if [ -n "${TS_OUTBOUND_IP:-}" ]; then
        echo "Exit Node traffic leaves via: $TS_OUTBOUND_IP"
    else
        echo "Exit Node traffic uses default IP (MASQUERADE)."
    fi
    echo "Tailscale IP:"
    tailscale ip -4 2>/dev/null || echo "  (check with: tailscale ip -4)"
    echo "Approve this machine as Exit Node: https://login.tailscale.com/admin/machines"
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
    add_cron_job "5 */3 * * *      /root/auto-update.sh"
    add_cron_job "*/5 * * * *      systemctl reset-failed"

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
setup_tailscale_exit_node
configure_cron
finalize_and_reboot
