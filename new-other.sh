#!/bin/bash
set -euo pipefail

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

# --- Определяем версию Debian и формат APT-источников ---
if [ -f /etc/os-release ]; then
    source /etc/os-release
    DEBIAN_VERSION_ID="${VERSION_ID:-0}"
    DEBIAN_CODENAME="${VERSION_CODENAME:-unknown}"
else
    echo "Ошибка: не удалось определить версию Debian (/etc/os-release отсутствует)."
    exit 1
fi

echo "Определена ОС: ${PRETTY_NAME:-$NAME $VERSION} (кодовое имя: $DEBIAN_CODENAME)"

# Определяем, используется ли формат deb822 по умолчанию (Debian 12+)
if [ "$DEBIAN_VERSION_ID" -ge 12 ] 2>/dev/null; then
    USE_DEB822="true"
else
    USE_DEB822="false"
fi

# Проверяем целостность .sources файлов
BROKEN_DEB822_FOUND="false"
if [ -d /etc/apt/sources.list.d ]; then
    for src in /etc/apt/sources.list.d/*.sources; do
        if [ -f "$src" ] && grep -q "^Suite:" "$src" 2>/dev/null; then
            # Проверяем синтаксис APT
            if ! apt-get update --print-uris 2>&1 | grep -q "Malformed"; then
                USE_DEB822="true"
            else
                echo "Обнаружен повреждённый deb822-файл: $src"
                BROKEN_DEB822_FOUND="true"
            fi
        fi
    done
fi

# --- Исправляем репозитории, если они сломаны или формат не deb822 ---
if [ "$BROKEN_DEB822_FOUND" = "true" ] || [ "$USE_DEB822" = "false" ]; then
    echo "Восстанавливаем стандартные репозитории в формате sources.list ..."
    # Создаём резервную копию повреждённых/старых файлов
    for f in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
        [ -f "$f" ] && mv "$f" "$f.bak-$(date +%Y%m%d%H%M%S)"
    done

    # Генерируем корректный sources.list в зависимости от версии Debian
    cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${DEBIAN_CODENAME} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${DEBIAN_CODENAME}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${DEBIAN_CODENAME}-security main contrib non-free non-free-firmware
EOF
    # Для старых версий (без non-free-firmware) компонент просто игнорируется
    if [ "$DEBIAN_VERSION_ID" -lt 12 ] 2>/dev/null; then
        sed -i 's/ non-free-firmware//g' /etc/apt/sources.list
    fi
    echo "Создан файл /etc/apt/sources.list для версии $DEBIAN_CODENAME."
fi

# Удаляем заведомо сломанные backports (если есть)
sed -i '/-backports/d' /etc/apt/sources.list 2>/dev/null || true
sed -i '/-backports/d' /etc/apt/sources.list.d/* 2>/dev/null || true

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

# --- IPv6 handling: full disable only (no questions) ---
echo "# Disable ping and IPv6 completely."
echo "blacklist ipv6" > /etc/modprobe.d/blacklist-ipv6.conf
update-initramfs -u
if grep --color 'net.ipv4.icmp_echo_ignore_all=1' /etc/sysctl.conf; then
    echo "Ping already blocked."
else
    echo "Blocking IPv4 ping."
    echo "net.ipv4.icmp_echo_ignore_all=1" >> /etc/sysctl.conf
fi
if grep --color 'net.ipv6.conf.all.disable_ipv6 = 1' /etc/sysctl.conf; then
    echo "IPv6 already disabled in sysctl."
else
    echo "Disabling IPv6."
    echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
fi
sysctl -p
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

# Allow root login with password (as requested)
if ! grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config; then
    sed -i '/^#\?PermitRootLogin/d' /etc/ssh/sshd_config
    echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
fi

if ! grep -q "^PasswordAuthentication yes" /etc/ssh/sshd_config; then
    sed -i '/^#\?PasswordAuthentication/d' /etc/ssh/sshd_config
    echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
fi

# Reload SSH only if config is valid
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
apt install sudo ufw cron rsyslog mc curl wget unzip p7zip-full htop unattended-upgrades apt-listchanges bsd-mailx iptables fail2ban dos2unix locales screen dnsutils openssl gpg autossh python3-systemd -y

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

# Create auto-update.sh script (no forced reboot)
cat > /root/auto-update.sh << 'EOF'
#!/bin/bash

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root." >&2
    exit 1
fi

LOGFILE="/var/log/auto-update.log"
echo "[$(date)] Starting system update..." >> "$LOGFILE"

apt clean -y
rm -rf /var/lib/apt/lists/*
apt update -y

upgradable=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)
if [ "$upgradable" -eq 0 ]; then
    echo "[$(date)] No updates available." >> "$LOGFILE"
    apt autoremove -y
    apt autoclean -y
    exit 0
fi

echo "[$(date)] Found $upgradable package(s) to upgrade." >> "$LOGFILE"
apt full-upgrade -y >> "$LOGFILE" 2>&1
apt autoremove -y
apt autoclean -y

echo "[$(date)] Update completed." >> "$LOGFILE"
EOF

chmod +x /root/auto-update.sh
echo "Script /root/auto-update.sh created."

# Improved ~/.profile additions (only sudo mc, no screen auto-attach)
if ! grep -q "sudo mc" ~/.profile; then
    cat >> ~/.profile << 'EOF'

# Launch mc after a short delay
sleep 2
sudo mc 2>/dev/null
EOF
    echo "mc launch added to ~/.profile"
else
    echo "mc launch already present in ~/.profile"
fi

echo ""
echo ""
echo ""
echo "Set UTF-8 locales."
locale-gen en_US.UTF-8 ru_RU.UTF-8
update-locale LANG=ru_RU.UTF-8
echo ""
echo ""
echo ""
sysctl --system

# --- Configure Fail2ban (no hardcoded ignoreip) ---
echo "Configuring Fail2ban..."
systemctl enable fail2ban.service

cat > /etc/fail2ban/fail2ban.local <<EOF
[Definition]
allowipv6 = auto
EOF

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1440m
findtime = 90m
maxretry = 2
ignoreip =

[sshd]
enabled = true
port = 22,24940
EOF

systemctl restart fail2ban.service
echo "Fail2ban configured (no ignored IPs)."

# Fix permissions for ~/.ssh (if exists)
if [ -d ~/.ssh ]; then
    echo "Fixing SSH directory permissions..."
    chmod 700 ~/.ssh
    chmod 600 ~/.ssh/* 2>/dev/null || true
    chmod 644 ~/.ssh/*.pub 2>/dev/null || true
    chmod 600 ~/.ssh/authorized_keys 2>/dev/null || true
    chmod 644 ~/.ssh/known_hosts 2>/dev/null || true
    chmod 644 ~/.ssh/config 2>/dev/null || true
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