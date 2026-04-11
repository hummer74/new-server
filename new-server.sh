#!/bin/bash
set -euo pipefail

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

# --- Определяем версию Debian ---
if [ -f /etc/os-release ]; then
    source /etc/os-release
    DEBIAN_VERSION_ID="${VERSION_ID:-0}"
    DEBIAN_CODENAME="${VERSION_CODENAME:-unknown}"
else
    echo "Ошибка: не удалось определить версию Debian (/etc/os-release отсутствует)."
    exit 1
fi

echo "Определена ОС: ${PRETTY_NAME:-$NAME $VERSION} (кодовое имя: $DEBIAN_CODENAME)"

# --- Принудительно убираем все deb822 .sources файлы ---
echo "Проверяем и исправляем APT-источники..."
if [ -d /etc/apt/sources.list.d ]; then
    for src in /etc/apt/sources.list.d/*.sources; do
        if [ -f "$src" ]; then
            echo "Найден deb822-файл: $src – перемещаем в /root/apt-backups/"
            mkdir -p /root/apt-backups
            mv "$src" "/root/apt-backups/$(basename "$src").bak-$(date +%Y%m%d%H%M%S)"
        fi
    done
fi

# Создаём стандартный sources.list (он надёжнее)
cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${DEBIAN_CODENAME} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${DEBIAN_CODENAME}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${DEBIAN_CODENAME}-security main contrib non-free non-free-firmware
EOF

# Для версий младше 12 убираем non-free-firmware
if [ "$DEBIAN_VERSION_ID" -lt 12 ] 2>/dev/null; then
    sed -i 's/ non-free-firmware//g' /etc/apt/sources.list
fi

# Удаляем backports (если вдруг остались)
sed -i '/-backports/d' /etc/apt/sources.list 2>/dev/null || true

echo "APT-источники исправлены."

echo "# Install all updates."
dpkg --configure -a
apt clean -y && rm -rf /var/lib/apt/lists/* && apt update -y && apt full-upgrade -y && apt autoremove -y && apt autoclean && apt purge ~c -y
echo ""
echo ""
echo ""

# --- Start of automated swap creation (512 MB, non‑interactive) ---
echo "# Creating swap file (512 MB)..."

# Remove all file‑based swap devices without confirmation
swaps=$(swapon --show=NAME,TYPE --noheadings --raw | awk '$2=="file" {print $1}')
if [ -n "$swaps" ]; then
    echo "Removing existing file‑based swap devices: $swaps"
    for file in $swaps; do
        swapoff "$file" 2>/dev/null || true
        rm -f "$file"
    done
fi

# Create new swap file of 512 MB
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

# Update /etc/fstab: remove old entries for /swapfile and add new one
cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d%H%M%S)
sed -i "\\#^$SWAP_FILE#d" /etc/fstab
echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
echo "Swap configured."
# --- End of swap creation ---

printf "\\033[33m# Change PRETTY hostname!!!\\033[0m\\n"
read -p "Type new PRETTY hostname here: " newhostname
hostnamectl set-hostname "$newhostname" --pretty
echo ""
echo ""
echo ""

# --- IPv6 handling: user chooses between full disable or active with restrictions ---
echo ""
echo "=============================================="
echo " IPv6 Configuration "
echo "=============================================="
echo "Choose IPv6 mode:"
echo "  1) Disable IPv6 completely (recommended if provider blocks outgoing IPv6)"
echo "  2) Keep IPv6 active but block all incoming connections/pings"
read -p "Enter 1 or 2 (default 2): " ipv6_mode

# Block IPv4 ping in any case
if grep --color 'net.ipv4.icmp_echo_ignore_all=1' /etc/sysctl.conf; then
    echo "IPv4 ping already blocked."
else
    echo "Blocking IPv4 ping."
    echo "net.ipv4.icmp_echo_ignore_all=1" >> /etc/sysctl.conf
fi
sysctl -p

if [[ "$ipv6_mode" == "1" ]]; then
    echo "# Disabling IPv6 completely."
    echo "blacklist ipv6" > /etc/modprobe.d/blacklist-ipv6.conf
    update-initramfs -u
    if grep --color 'net.ipv6.conf.all.disable_ipv6 = 1' /etc/sysctl.conf; then
        echo "IPv6 already disabled in sysctl."
    else
        echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
    fi
    sysctl -p
else
    # Default: active IPv6 with incoming restrictions
    echo "# Keeping IPv6 stack active, but dropping all incoming IPv6 traffic (except established)."
    # Remove any global disable settings that might conflict
    sed -i '/^net\.ipv6\.conf\.all\.disable_ipv6/d' /etc/sysctl.conf
    sed -i '/^net\.ipv6\.conf\.default\.disable_ipv6/d' /etc/sysctl.conf
    sysctl -p

    # Set up ip6tables rules
    ip6tables -P INPUT DROP
    ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A INPUT -p icmpv6 --icmpv6-type echo-request -j DROP
    # Save rules for persistence
    mkdir -p /etc/iptables
    command -v ip6tables-save >/dev/null && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
fi
# --- End of IPv6 configuration ---

echo ""
echo ""
echo ""
printf "\\033[33m# Configure SSH to listen on ports 22 and 24940.\\033[0m\\n"

# Check if ports are already configured to avoid duplicate entries or unnecessary file modifications
if ! grep -q "^Port 22$" /etc/ssh/sshd_config || ! grep -q "^Port 24940$" /etc/ssh/sshd_config; then
    sed -i '/^Port /d' /etc/ssh/sshd_config
    echo "Port 22" >> /etc/ssh/sshd_config
    echo "Port 24940" >> /etc/ssh/sshd_config
    echo "Ports 22 and 24940 configured in sshd_config."
else
    echo "Ports 22 and 24940 are already configured."
fi

# Allow root login only with keys, ensuring idempotency
if ! grep -q "^PermitRootLogin without-password" /etc/ssh/sshd_config; then
    sed -i '/^#\?PermitRootLogin/d' /etc/ssh/sshd_config
    echo "PermitRootLogin without-password" >> /etc/ssh/sshd_config
fi

if ! grep -q "^PubkeyAuthentication yes" /etc/ssh/sshd_config; then
    sed -i '/^#\?PubkeyAuthentication/d' /etc/ssh/sshd_config
    echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
fi

# Safely apply SSH configuration changes without dropping current connections
if sshd -t; then
    systemctl reload ssh
    echo "SSH service reloaded successfully."
else
    echo "SSH configuration syntax error. Reload aborted. Please check /etc/ssh/sshd_config."
fi

echo ""
echo ""
echo ""
echo "# Install mc, curl, wget, htop, unattended-upgrades, apt-listchanges, fail2ban, ufw, autossh."
apt install sudo ufw cron rsyslog mc curl wget unzip p7zip-full htop unattended-upgrades apt-listchanges bsd-mailx iptables fail2ban dos2unix locales screen dnsutils openssl gpg autossh -y

# --- Настройка Fail2ban (адаптировано из f2b-install.sh) ---
echo "Configuring Fail2ban..."
systemctl enable fail2ban.service

cat > /etc/fail2ban/fail2ban.local <<EOF
[Definition]
allowipv6 = auto
EOF

# Определяем, нужно ли добавлять backend = systemd (для Debian 12+)
if [ "$DEBIAN_VERSION_ID" -ge 12 ] 2>/dev/null; then
    BACKEND_LINE="backend = systemd"
else
    BACKEND_LINE=""
fi

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 7d
findtime = 180m
maxretry = 4
ignoreip = 176.56.1.165 95.78.162.177 45.86.86.195 46.29.239.23 45.151.139.193 45.38.143.206 217.60.252.204 176.125.243.194 194.58.68.23

[sshd]
enabled = true
port = 22,24940
$BACKEND_LINE
EOF

systemctl restart fail2ban.service
sleep 2
if systemctl is-active --quiet fail2ban.service; then
    echo "Fail2ban is active and protecting SSH."
else
    echo "WARNING: Fail2ban failed to start. Check 'journalctl -u fail2ban'."
fi

printf "\033[1;33m# Don't forget to add the new SSH port (24940) in the client!\033[0m\n"
grep --color 'Port ' /etc/ssh/sshd_config
read -n1 -s -r -p "Press any key..."; echo
# --- Конец настройки Fail2ban ---

# Configure unattended-upgrades (automatic security updates)
echo ""
echo "# Configuring unattended-upgrades..."
echo ""

# Basic periodic settings
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# Allow only security updates (and ESM if available)
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

# Enable and start the service
systemctl enable unattended-upgrades
systemctl restart unattended-upgrades

echo "Unattended-upgrades configured."
echo ""

# Improved ~/.profile additions
if ! grep -q "screen -ls | grep -q" ~/.profile; then
    cat >> ~/.profile << 'EOF'

# Attach to a detached screen session if available
if screen -ls | grep -q "Detached"; then
    screen -r 2>/dev/null
fi

# Launch mc after a short delay
sleep 2
sudo mc 2>/dev/null
EOF
    echo "Enhanced commands added to ~/.profile"
else
    echo "Enhanced commands already present in ~/.profile"
fi
echo ""
echo ""
echo ""

# --- Настройка локалей (ru_RU.UTF-8 без warning'ов) ---
echo "Set UTF-8 locales."
locale-gen en_US.UTF-8 ru_RU.UTF-8

# Устанавливаем локаль глобально
update-locale LANG=ru_RU.UTF-8 LC_ALL=ru_RU.UTF-8

# Дополнительно прописываем в /etc/environment (для systemd и cron)
if ! grep -q "^LANG=" /etc/environment 2>/dev/null; then
    echo "LANG=ru_RU.UTF-8" >> /etc/environment
    echo "LC_ALL=ru_RU.UTF-8" >> /etc/environment
fi

# Применяем к текущей сессии
export LANG=ru_RU.UTF-8
export LC_ALL=ru_RU.UTF-8
unset LC_CTYPE LC_MESSAGES 2>/dev/null || true

echo ""
echo ""
echo ""
sysctl --system

# Download setup.7z and check success
wget -O setup.7z https://raw.githubusercontent.com/hummer74/new-server/main/setup.7z
if [ ! -f setup.7z ]; then
    echo "Error: failed to download setup.7z"
    exit 1
fi

printf "\\033[33m# Copy /root/.dir from archive.\\033[0m\\n"
7za x setup.7z -aoa
rm setup.7z
echo "Fix directory permissions"
chmod 700 ~/.config/htop
chmod 700 ~/.config/mc
chmod 700 ~/.ssh
echo ""
echo "Fix all key permissions"
chmod 600 ~/.ssh/* 2>/dev/null
chmod 644 ~/.ssh/*.pub
echo ""
echo "Fix special files permissions"
chmod 600 ~/.ssh/authorized_keys
chmod 644 ~/.ssh/known_hosts
chmod 644 ~/.ssh/config
echo ""

# Make all .sh files in /root executable
chmod +x ~/*.sh 2>/dev/null

# WARNING: Ensure ~/.ssh/passwd.txt contains line "username:password"
if [ -f ~/.ssh/passwd.txt ]; then
   chpasswd < ~/.ssh/passwd.txt
else
   echo "~/.ssh/passwd.txt not found, password not changed."
fi
echo ""
echo ""
echo ""

# Create ordinary user opossum
printf "\\033[33m# Add ordinary user OPOSSUM with PASSWORD!\\033[0m\\n"
# Removed destructive 'userdel' to ensure idempotency and prevent data loss on script rerun
if [ $(id -u) -eq 0 ]; then
    if grep -q "^opossum:" /etc/passwd; then
        echo "User opossum already exists! Skipping creation."
    else
        read -s -p "Enter password for user opossum: " password
        echo
        pass=$(openssl passwd -6 "$password")
        useradd -m -p "$pass" opossum
        if [ $? -eq 0 ]; then
            echo "User opossum added to system!"
            usermod -aG sudo opossum
        else
            echo "Failed to add user!"
        fi
        unset password
    fi
else
    echo "Only root may add a user to the system."
fi

# Extract files for opossum from setup archive (opossum.7z is inside setup.7z)
if [ -d /home/opossum ]; then
    if [ -f /root/opossum.7z ]; then
        cp /root/opossum.7z /home/opossum/
        cd /home/opossum
        7za x opossum.7z -aoa
        rm -f opossum.7z
        chmod +x opossum.sh
        chown -R opossum:opossum /home/opossum
        cd /root
    else
        echo "/root/opossum.7z not found (was it inside setup.7z?), skipping opossum setup."
    fi
else
    echo "Home directory for opossum not found, skipping downloads."
fi
echo ""
echo ""
echo ""
systemctl --failed
echo ""
systemctl reset-failed
# Create a marker file with the pretty hostname
safe_name=$(echo "$newhostname" | tr ' ' '_' | tr -cd '[:alnum:]_-')
touch "/root/zzz-$safe_name"
echo ""
echo ""
echo ""
echo ""
echo ""

# Configure UFW firewall – add rules and ask whether to enable
echo "Configuring UFW firewall..."

# Determine current SSH listening ports to prevent lockout
CURRENT_SSH_PORTS=$(ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | sed -E 's/.*://' | sort -u)
if [ -z "$CURRENT_SSH_PORTS" ]; then
    echo "Warning: Could not determine current SSH ports. Allowing default 22 and 24940."
    ufw allow 22/tcp
    ufw allow 24940/tcp
else
    echo "Current SSH listening ports: $CURRENT_SSH_PORTS"
    for port in $CURRENT_SSH_PORTS; do
        ufw allow "$port"/tcp
        echo "Allowed SSH port $port/tcp in UFW."
    done
    # Also ensure standard ports are allowed
    ufw allow 22/tcp 2>/dev/null || true
    ufw allow 24940/tcp 2>/dev/null || true
fi

echo "SSH ports are allowed."
read -p "Do you want to enable UFW now? (y/N): " enable_ufw
if [[ "$enable_ufw" =~ ^[Yy]$ ]]; then
    echo "Enabling UFW..."
    ufw --force enable
    echo "UFW is now enabled and active."
    ufw status verbose
else
    echo "UFW rules have been added but the firewall is not enabled."
    echo "You can enable it later with: sudo ufw enable"
fi

echo ""

# --- Reverse SSH tunnel to OpenWrt router (moved after UFW) ---
echo "=============================================="
echo " Setting up Reverse SSH Tunnel to OpenWrt "
echo "=============================================="

# Ensure autossh is installed
if ! command -v autossh &> /dev/null; then
    echo "Installing autossh..."
    apt install autossh -y
fi

KEY_PATH="/root/.ssh/ssh2router-key"
REVERSE_LOG="/root/reverse_ssh.log"

if [ ! -f "$KEY_PATH" ]; then
    echo "Warning: $KEY_PATH not found. Reverse tunnel setup skipped." | tee -a "$REVERSE_LOG"
else
    chmod 600 "$KEY_PATH"

    ROUTER_USER="tunneluser"
    ROUTER_HOST="mousehouse.ignorelist.com"
    ROUTER_PORT=24930

    # 1. Local SSH port (highest)
    LOCAL_SSH_PORT=$(ss -tlnp | grep 'sshd' | awk '{print $4}' | awk -F':' '{print $NF}' | sort -rn | head -n 1)
    if [ -z "$LOCAL_SSH_PORT" ]; then
        LOCAL_SSH_PORT=22
    fi
    echo "Local SSH port: $LOCAL_SSH_PORT" | tee -a "$REVERSE_LOG"

    # 2. Remote port from pretty hostname
    PRETTY_NAME="$newhostname"
    NAME_PREFIX=$(echo "$PRETTY_NAME" | grep -oE '[0-9]{2}' | head -n 1)
    if [ -z "$NAME_PREFIX" ]; then
        DEFAULT_REVERSE_PORT="25900"
        echo "Could not extract digits from '$PRETTY_NAME', using 25900." | tee -a "$REVERSE_LOG"
    else
        DEFAULT_REVERSE_PORT="259$NAME_PREFIX"
        echo "Prefix '$NAME_PREFIX' -> default remote port $DEFAULT_REVERSE_PORT" | tee -a "$REVERSE_LOG"
    fi

    printf "Enter REMOTE port on OpenWrt (default %s): " "$DEFAULT_REVERSE_PORT"
    read USER_INPUT_PORT
    REVERSE_PORT=${USER_INPUT_PORT:-$DEFAULT_REVERSE_PORT}

    if ! [[ "$REVERSE_PORT" =~ ^[0-9]+$ ]]; then
        echo "Error: port must be a number, skipping tunnel setup." | tee -a "$REVERSE_LOG"
    else
        SERVICE_TEMPLATE="/etc/systemd/system/reverse-tunnel@.service"
        SERVICE_INSTANCE="reverse-tunnel@${REVERSE_PORT}.service"

        # Manage existing services
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
                    IDX=$((ACTION-1))
                    if [ "$IDX" -ge 0 ] && [ "$IDX" -lt "${#EXISTING_SERVICES[@]}" ]; then
                        SELECTED_SVC="${EXISTING_SERVICES[$IDX]}"
                        systemctl stop "$SELECTED_SVC" 2>/dev/null || true
                        systemctl disable "$SELECTED_SVC" 2>/dev/null || true
                    fi
                    ;;
            esac
        fi

        # Create systemd template
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

        # Verify service started successfully
        sleep 2
        if systemctl is-active --quiet "$SERVICE_INSTANCE"; then
            STATUS_MSG="Tunnel service $SERVICE_INSTANCE is active."
            echo "$STATUS_MSG" | tee -a "$REVERSE_LOG"
        else
            STATUS_MSG="ERROR: Tunnel service $SERVICE_INSTANCE failed to start."
            echo "$STATUS_MSG" | tee -a "$REVERSE_LOG"
        fi

        TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
        LOG_ENTRY="[$TIMESTAMP] REVERSE Tunnel: ${ROUTER_HOST}:${REVERSE_PORT} -> ${PRETTY_NAME}:${LOCAL_SSH_PORT} (Status: $(systemctl is-active "$SERVICE_INSTANCE"))"
        echo "$LOG_ENTRY" >> "$REVERSE_LOG"
        echo "Check status: systemctl status $SERVICE_INSTANCE"
    fi
fi
# --- End of reverse SSH tunnel ---

# --- Start of automated telemt installation (non‑interactive, defaults) ---
echo "# Installing telemt MTProto proxy (non‑interactive)..."
# Check for Docker Engine
if ! command -v docker >/dev/null; then
    echo "Docker not found. Installing docker.io..."
    apt-get update
    apt-get install -y docker.io
    systemctl enable --now docker
fi
if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon not running. Starting..."
    systemctl start docker
fi
# Determine Docker Compose command
if command -v docker-compose >/dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
elif docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker compose"
else
    apt-get update
    apt-get install -y docker-compose
    DOCKER_COMPOSE_CMD="docker-compose"
fi
# Install dependencies
command -v apparmor_parser >/dev/null || { apt-get update && apt-get install -y apparmor; }
command -v openssl >/dev/null || { apt-get update && apt-get install -y openssl; }
command -v xxd >/dev/null || { apt-get update && apt-get install -y xxd; }
command -v curl >/dev/null || { apt-get update && apt-get install -y curl; }
if ! command -v ufw >/dev/null; then
    apt-get update && apt-get install -y ufw
fi
# Determine external IP
EXTERNAL_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || curl -s icanhazip.com)
if [ -z "$EXTERNAL_IP" ]; then
    echo "Could not automatically determine external IP. Using fallback 127.0.0.1."
    EXTERNAL_IP="127.0.0.1"
fi
# Default values
HOST_PORT=8443
TLS_DOMAIN="github.com"
USERNAME="proxy_user"
# Generate secret
SECRET=$(openssl rand -hex 16)
TLS_DOMAIN_HEX=$(printf "%s" "$TLS_DOMAIN" | xxd -p -c 1000 | tr -d '\\n')
FULL_SECRET="ee${SECRET}${TLS_DOMAIN_HEX}"
# Create directories and config
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
cat > docker-compose.yml <<EOF
version: '3.3'
services:
  telemt:
    image: whn0thacked/telemt-docker:latest
    container_name: telemt
    restart: unless-stopped
    ports:
      - "$HOST_PORT:$HOST_PORT"
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
# Open port in UFW if active
if ufw status | grep -q active; then
    ufw allow "$HOST_PORT/tcp"
fi
echo "$HOST_PORT" > "$INSTALL_DIR/ufw_port.txt"
# Start container
$DOCKER_COMPOSE_CMD up -d
# Wait a moment and check if container is running
sleep 5
if docker ps --format '{{.Names}}' | grep -q "^telemt$"; then
    echo "Telemt container is running."
else
    echo "ERROR: Telemt container failed to start. Check logs with 'docker logs telemt'."
fi
# Save connection link
LINK="tg://proxy?server=${EXTERNAL_IP}&port=${HOST_PORT}&secret=${FULL_SECRET}"
echo "$LINK" > /root/tg-proxy_secret.txt
echo "Telemt proxy installed. Link saved to /root/tg-proxy_secret.txt"
# --- End of telemt installation ---

# Set new cron jobs, completely replacing the current crontab
crontab - <<EOF
@reboot         date >> /root/reboot.log
0 0 1 * *       date > /root/reboot.log
1 */2 * * *     /root/telemt-update.sh
5 */3 * * *     /root/auto-update.sh
*/5 * * * *     systemctl reset-failed
EOF

echo "Crontab successfully updated."
echo ""
echo ""
echo ""
printf "\\033[33mLast update.\\033[0m\\n"
apt clean -y && rm -rf /var/lib/apt/lists/* && apt update -y && apt full-upgrade -y && apt autoremove -y && apt autoclean && apt purge ~c -y
read -n1 -s -r -p "Press any key for reboot..."; echo
echo ""
echo ""
echo ""
echo "REBOOT"
echo ""
echo ""
echo ""
echo ""
echo ""
echo ""
echo ""
echo ""
echo ""
echo ""
echo ""
echo ""
reboot now