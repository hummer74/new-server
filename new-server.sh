#!/bin/bash
set -euo pipefail

# === Log all output to /root/new-server.log ===
LOG_FILE="/root/new-server.log"
exec 3>&1 4>&2
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== Script started at $(date '+%Y-%m-%d %H:%M:%S') ===" >&3

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

# --- Detect Debian version ---
if [ -f /etc/os-release ]; then
    source /etc/os-release
    DEBIAN_VERSION_ID="${VERSION_ID:-0}"
    if [ -z "$VERSION_CODENAME" ] && [ -n "$VERSION" ]; then
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

# --- STEP 0: Auto-detect IP (Inbound/Outbound) ---
echo "--- Network Analysis ---"
# Get all public IPv4 addresses
IPV4_LIST=($(ip -4 addr show | grep inet | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1))
NUM_IPS=${#IPV4_LIST[@]}

INBOUND_IP=""
OUTBOUND_IP=""
USE_SPLIT_NETWORK="false"

if [ "$NUM_IPS" -gt 1 ]; then
    echo "Found multiple IPv4 addresses:"
    for i in "${!IPV4_LIST[@]}"; do
        echo "[$i] ${IPV4_LIST[$i]}"
    done
    
    # Strict Y/N request
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
            # If exactly 2 IPs, auto-assign Outbound
            INBOUND_IP=${IPV4_LIST[0]}
            OUTBOUND_IP=${IPV4_LIST[1]}
            echo "Auto-selected: Inbound=$INBOUND_IP, Outbound=$OUTBOUND_IP"
        else
            # If 3+ IPs, strict numeric request for both
            MAX_IDX=$((NUM_IPS - 1))
            
            while true; do
                read -p "Select index for INBOUND IP (0-$MAX_IDX): " in_idx
                if [[ "$in_idx" =~ ^[0-9]+$ ]] && [ "$in_idx" -ge 0 ] && [ "$in_idx" -le "$MAX_IDX" ]; then
                    INBOUND_IP=${IPV4_LIST[$in_idx]}
                    break
                else
                    echo "Invalid index. Please enter a number between 0 and $MAX_IDX."
                fi
            done
            
            while true; do
                read -p "Select index for OUTBOUND IP (0-$MAX_IDX): " out_idx
                if [[ "$out_idx" =~ ^[0-9]+$ ]] && [ "$out_idx" -ge 0 ] && [ "$out_idx" -le "$MAX_IDX" ]; then
                    OUTBOUND_IP=${IPV4_LIST[$out_idx]}
                    break
                else
                    echo "Invalid index. Please enter a number between 0 and $MAX_IDX."
                fi
            done
        fi
    else
        INBOUND_IP=${IPV4_LIST[0]}
        OUTBOUND_IP=${IPV4_LIST[0]}
    fi
else
    INBOUND_IP=${IPV4_LIST[0]}
    OUTBOUND_IP=${IPV4_LIST[0]}
fi

# Save config for future updates
cat > /root/.network_config <<EOF
USE_SPLIT_NETWORK=$USE_SPLIT_NETWORK
INBOUND_IP=$INBOUND_IP
OUTBOUND_IP=$OUTBOUND_IP
EOF

# --- APT Sources ---
echo "Checking and fixing APT sources..."
if [ -d /etc/apt/sources.list.d ]; then
    for src in /etc/apt/sources.list.d/*.sources; do
        if [ -f "$src" ]; then
            echo "Found deb822 file: $src - moving to /root/apt-backups/"
            mkdir -p /root/apt-backups
            mv "$src" "/root/apt-backups/$(basename "$src").bak-$(date +%Y%m%d%H%M%S)"
        fi
    done
fi

if [ -d /etc/apt/sources.list.d ]; then
    mkdir -p /root/apt-backups
    for listfile in /etc/apt/sources.list.d/*.list; do
        if [ -f "$listfile" ]; then
            echo "Removing conflicting .list file: $listfile"
            mv "$listfile" "/root/apt-backups/$(basename "$listfile").bak-$(date +%Y%m%d%H%M%S)"
        fi
    done
fi

if [ "$DEBIAN_VERSION_ID" -le 10 ] 2>/dev/null; then
    cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian ${DEBIAN_CODENAME} main contrib non-free non-free-firmware
deb http://archive.debian.org/debian ${DEBIAN_CODENAME}-updates main contrib non-free non-free-firmware
# Security updates for oldoldstable are not available in archive, skipping
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

# --- Updates ---
echo "# Install all updates."
dpkg --configure -a
apt clean -y && rm -rf /var/lib/apt/lists/*
echo "# Updating package lists..."
apt update -y || { echo "ERROR: apt update failed"; exit 1; }
echo "# Full upgrade..."
apt full-upgrade -y || { echo "ERROR: apt full-upgrade failed"; exit 1; }
apt autoremove -y && apt autoclean
apt autoremove --purge -y
echo ""

# --- Swap ---
echo "# Creating swap file (512 MB)..."
swaps=$(swapon --show=NAME,TYPE --noheadings --raw | awk '$2=="file" {print $1}')
if [ -n "$swaps" ]; then
    echo "Removing existing file-based swap devices: $swaps"
    for file in $swaps; do
        swapoff "$file" 2>/dev/null || true
        rm -f "$file"
    done
fi
SWAP_FILE="/swapfile"
SWAP_SIZE_MB=512
echo "Creating $SWAP_FILE of size ${SWAP_SIZE_MB} MB..."
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

# --- Hostname ---
printf "\\033[33m# Change PRETTY hostname!!!\\033[0m\\n"
while true; do
    read -p "Type new PRETTY hostname here: " newhostname
    if [ -n "$newhostname" ]; then
        break
    else
        echo "Hostname cannot be empty. Please enter a valid name."
    fi
done
hostnamectl set-hostname "$newhostname" --pretty
echo ""

# --- Hard-disable IPv6 and block ICMP ---
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

# --- SSH Configuration ---
echo ""
printf "\\033[33m# Configure SSH to listen on ports 22 and 24940.\\033[0m\\n"
mkdir -p /etc/ssh/sshd_config.d
SSH_LISTEN_BLOCK=""
if [ "$USE_SPLIT_NETWORK" == "true" ]; then
    SSH_LISTEN_BLOCK="ListenAddress 127.0.0.1
ListenAddress $INBOUND_IP"
fi
cat > /etc/ssh/sshd_config.d/99-custom.conf <<EOF
Port 22
Port 24940
$SSH_LISTEN_BLOCK
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

# --- Install Packages ---
echo "# Install standard tools, Docker, and security packages..."
apt install sudo ufw cron rsyslog mc curl wget unzip p7zip-full htop unattended-upgrades apt-listchanges bsd-mailx iptables fail2ban dos2unix locales screen dnsutils openssl gpg autossh python3-systemd xxd -y

# --- Locales ---
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

# --- Fail2ban ---
echo "Configuring Fail2ban..."
systemctl enable fail2ban.service
cat > /etc/fail2ban/fail2ban.local <<EOF
[Definition]
allowipv6 = auto
EOF

F2B_IGNORE_IPS="176.56.1.165 95.78.162.177 45.86.86.195 46.29.239.23 45.151.139.193 45.38.143.206 217.60.252.204 176.125.243.194 194.58.68.23"
if [ "$USE_SPLIT_NETWORK" == "true" ]; then
    F2B_IGNORE_IPS="$INBOUND_IP $OUTBOUND_IP $F2B_IGNORE_IPS"
fi

F2B_SSHD_LOG=""
if [ "$DEBIAN_VERSION_ID" -lt 12 ] 2>/dev/null; then
    F2B_SSHD_LOG="logpath = %(sshd_log)s"
fi

F2B_BACKEND_LINE=""
if [ "$DEBIAN_VERSION_ID" -ge 12 ] 2>/dev/null; then
    F2B_BACKEND_LINE="backend = systemd"
fi

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 7d
findtime = 180m
maxretry = 4
ignoreip = $F2B_IGNORE_IPS
$F2B_BACKEND_LINE

[sshd]
enabled = true
port = 22,24940
$F2B_SSHD_LOG
EOF

if fail2ban-client -t >/dev/null 2>&1; then
    systemctl restart fail2ban.service
    sleep 2
    if systemctl is-active --quiet fail2ban.service; then
        echo "Fail2ban is active and protecting SSH."
    else
        echo "WARNING: Fail2ban failed to start. Check 'journalctl -u fail2ban'."
    fi
else
    echo "ERROR: Fail2ban configuration invalid. Check with 'fail2ban-client -t'"
    exit 1
fi
echo ""

# --- Unattended-upgrades ---
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
if unattended-upgrade --dry-run 2>&1 | grep -qi "allowed origin"; then
    echo "Unattended-upgrades correctly configured."
else
    echo "WARNING: unattended-upgrades may not work. Check allowed origins."
fi
echo ""

# --- ~/.profile ---
if ! grep -q "screen -ls | grep -q" ~/.profile; then
    cat >> ~/.profile << 'EOF'

if screen -ls | grep -q "Detached"; then
    screen -r 2>/dev/null
fi
sleep 2
sudo mc 2>/dev/null
EOF
fi
echo ""

# --- Download, verify and extract setup.7z ---
wget -O setup.7z https://raw.githubusercontent.com/hummer74/new-server/main/setup.7z
if [ ! -s setup.7z ]; then
    echo "Error: downloaded file is empty"
    exit 1
fi

if ! dd if=setup.7z bs=1 count=6 2>/dev/null | xxd -p | grep -q "377abcaf271c"; then
    echo "Error: setup.7z is corrupted or not a valid 7z archive"
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

# --- System Passwords ---
if [ -f ~/.ssh/passwd.txt ]; then
   chpasswd < ~/.ssh/passwd.txt
fi
echo ""

# --- Create User opossum (using MASTER_PASSWORD) ---
printf "\\033[33m# Add ordinary user OPOSSUM with PASSWORD!\\033[0m\\n"
if [ $(id -u) -eq 0 ]; then
    if grep -q "^opossum:" /etc/passwd; then
        echo "User opossum already exists! Skipping creation."
    else
        pass=$(openssl passwd -6 "$MASTER_PASSWORD")
        useradd -m -p "$pass" opossum
        if [ $? -eq 0 ]; then
            echo "User opossum added to system!"
            usermod -aG sudo opossum
        else
            echo "Failed to add user!"
        fi
    fi
fi

# --- Extract opossum files (using MASTER_PASSWORD) ---
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
else
    echo "Home directory for opossum not found, skipping downloads."
fi

# Securely wipe password variable from memory
unset MASTER_PASSWORD

echo ""
systemctl --failed
systemctl reset-failed
safe_name=$(echo "$newhostname" | tr ' ' '_' | tr -cd '[:alnum:]_-')
touch "/root/zzz-$safe_name"
echo ""

# --- UFW ---
echo "Configuring UFW firewall..."
for port in 22 24940; do
    if [ "$USE_SPLIT_NETWORK" == "true" ]; then
        ufw allow to "$INBOUND_IP" port "$port" proto tcp
    else
        ufw allow proto tcp port "$port"
    fi
done
echo "SSH ports are allowed in UFW."
echo ""

# --- Reverse SSH Tunnel ---
echo "=============================================="
echo " Setting up Reverse SSH Tunnel to OpenWrt "
echo "=============================================="
KEY_PATH="/root/.ssh/ssh2router-key"
REVERSE_LOG="/root/reverse_ssh.log"
if [ ! -f "$KEY_PATH" ]; then
    echo "Warning: $KEY_PATH not found. Reverse tunnel setup skipped." | tee -a "$REVERSE_LOG"
else
    chmod 600 "$KEY_PATH"
    ROUTER_USER="tunneluser"
    ROUTER_HOST="mousehouse.ignorelist.com"
    ROUTER_PORT=24930
    LOCAL_SSH_PORT=$(ss -tlnp | grep 'sshd' | awk '{print $4}' | awk -F':' '{print $NF}' | sort -rn | head -n 1)
    if [ -z "$LOCAL_SSH_PORT" ]; then LOCAL_SSH_PORT=22; fi
    
    PRETTY_NAME="$newhostname"
    NAME_PREFIX=$(echo "$PRETTY_NAME" | grep -oE '[0-9]{2}' | head -n 1)
    DEFAULT_REVERSE_PORT=${NAME_PREFIX:+"259$NAME_PREFIX"}
    DEFAULT_REVERSE_PORT=${DEFAULT_REVERSE_PORT:-"25900"}
    
    printf "Enter REMOTE port on OpenWrt (default %s): " "$DEFAULT_REVERSE_PORT"
    read USER_INPUT_PORT
    REVERSE_PORT=${USER_INPUT_PORT:-$DEFAULT_REVERSE_PORT}

    SERVICE_TEMPLATE="/etc/systemd/system/reverse-tunnel@.service"
    SERVICE_INSTANCE="reverse-tunnel@${REVERSE_PORT}.service"
    
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
    -o "BindAddress=$OUTBOUND_IP" \\
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
    systemctl start "$SERVICE_INSTANCE"
    echo "Tunnel service $SERVICE_INSTANCE started."
fi

# --- Telemt MTProto Proxy ---
echo "# Installing telemt MTProto proxy..."
if ! command -v docker >/dev/null; then
    apt-get update && apt-get install -y docker.io docker-compose
    systemctl enable --now docker
fi

EXTERNAL_IP="$INBOUND_IP"
HOST_PORT=443
TLS_DOMAIN="saimaasailing.fi"
USERNAME="test_user"
SECRET=$(openssl rand -hex 16)
TLS_DOMAIN_HEX=$(printf "%s" "$TLS_DOMAIN" | xxd -p -c 1000 | tr -d '\\n')
FULL_SECRET="ee${SECRET}${TLS_DOMAIN_HEX}"
INSTALL_DIR="/etc/telemt-docker"
CONFIG_DIR="$INSTALL_DIR/config"
mkdir -p "$CONFIG_DIR"
cd "$INSTALL_DIR"

cat > "$CONFIG_DIR/telemt.toml" <<EOF
[general]
use_middle_proxy = false
[general.modes]
classic = false
secure = false
tls = true
[server]
port = $HOST_PORT
[server.api]
enabled = true
listen = "127.0.0.1:9091"
[censorship]
tls_domain = "$TLS_DOMAIN"
[access.users]
$USERNAME = "$SECRET"
EOF
chmod -R 777 "$CONFIG_DIR"

# Force Docker to bind ONLY to Inbound IP
TELEMT_PORT_BIND="$HOST_PORT"
if [ "$USE_SPLIT_NETWORK" == "true" ]; then
    TELEMT_PORT_BIND="$INBOUND_IP:$HOST_PORT"
fi

cat > docker-compose.yml <<EOF
version: '3.3'
services:
  telemt:
    image: whn0thacked/telemt-docker:latest
    container_name: telemt
    restart: unless-stopped
    ports:
      - "$TELEMT_PORT_BIND:$HOST_PORT"
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
EOF

if ufw status | grep -q active; then
    if [ "$USE_SPLIT_NETWORK" == "true" ]; then
        ufw allow to "$INBOUND_IP" port "$HOST_PORT" proto tcp
    else
        ufw allow proto tcp port "$HOST_PORT"
    fi
fi

docker-compose up -d
LINK="tg://proxy?server=${EXTERNAL_IP}&port=${HOST_PORT}&secret=${FULL_SECRET}"
echo "$LINK" > /root/tg-proxy_secret.txt
echo "Telemt proxy installed. Link: $LINK"

# --- Crontab ---
CRON_TMP=$(mktemp)
crontab -l 2>/dev/null > "$CRON_TMP" || echo "# New crontab" > "$CRON_TMP"
echo "*/5 * * * * systemctl reset-failed" >> "$CRON_TMP"
sort -u "$CRON_TMP" | crontab -
rm -f "$CRON_TMP"

# --- Outbound Routing Persistence ---
if [ "$USE_SPLIT_NETWORK" == "true" ]; then
    MAIN_IFACE=$(ip -4 route | grep default | awk '{print $5}' | head -n1)
    # Get gateway specifically for the Outbound IP if possible, else fallback to default
    OUTBOUND_GW=$(ip -4 route show dev "$MAIN_IFACE" | grep default | awk '{print $3}' | head -n1)
    
    if [ -n "$OUTBOUND_GW" ] && [ -n "$MAIN_IFACE" ]; then
        IP_BIN=$(command -v ip)
        cat > /etc/systemd/system/set-outbound-route.service <<EOF
[Unit]
Description=Set default outbound IP route
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$IP_BIN route replace default via $OUTBOUND_GW dev $MAIN_IFACE src $OUTBOUND_IP
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl enable set-outbound-route.service
        $IP_BIN route replace default via "$OUTBOUND_GW" dev "$MAIN_IFACE" src "$OUTBOUND_IP" || true
        echo "Outbound route configured to use $OUTBOUND_IP"
    fi
fi

echo "Finalizing..."
ufw --force enable
sleep 5
reboot now