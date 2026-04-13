#!/bin/bash
set -euo pipefail

# === Логирование всего вывода в файл /root/new-server.log ===
LOG_FILE="/root/new-server.log"
exec 3>&1 4>&2
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== Script started at $(date '+%Y-%m-%d %H:%M:%S') ===" >&3

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

# --- Определяем версию Debian (исправлен пункт 1) ---
if [ -f /etc/os-release ]; then
    source /etc/os-release
    DEBIAN_VERSION_ID="${VERSION_ID:-0}"
    if [ -z "$VERSION_CODENAME" ] && [ -n "$VERSION" ]; then
        DEBIAN_CODENAME=$(echo "$VERSION" | sed -n 's/.*(\(.*\)).*/\1/p')
    else
        DEBIAN_CODENAME="${VERSION_CODENAME:-unknown}"
    fi
else
    echo "Ошибка: не удалось определить версию Debian (/etc/os-release отсутствует)."
    exit 1
fi

if [ "$DEBIAN_CODENAME" = "unknown" ]; then
    echo "Ошибка: не удалось определить кодовое имя Debian."
    exit 1
fi

echo "Определена ОС: ${PRETTY_NAME:-$NAME $VERSION} (кодовое имя: $DEBIAN_CODENAME)"

# --- ПУНКТ 0: Автоопределение IP (Inbound/Outbound) ---
echo "--- Network Analysis ---"
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
    
    read -p "Do you want to use Inbound/Outbound split technology? (y/N): " use_split
    if [[ "$use_split" =~ ^[Yy]$ ]]; then
        USE_SPLIT_NETWORK="true"
        read -p "Select index for INBOUND IP (services will listen here): " in_idx
        read -p "Select index for OUTBOUND IP (internet access from here): " out_idx
        INBOUND_IP=${IPV4_LIST[$in_idx]}
        OUTBOUND_IP=${IPV4_LIST[$out_idx]}
    else
        INBOUND_IP=${IPV4_LIST[0]}
        OUTBOUND_IP=${IPV4_LIST[0]}
    fi
else
    INBOUND_IP=${IPV4_LIST[0]}
    OUTBOUND_IP=${IPV4_LIST[0]}
fi

# Сохраняем конфиг для будущих обновлений
cat > /root/.network_config <<EOF
USE_SPLIT_NETWORK=$USE_SPLIT_NETWORK
INBOUND_IP=$INBOUND_IP
OUTBOUND_IP=$OUTBOUND_IP
EOF

# --- APT источники (универсальный блок) ---
echo "Проверяем и исправляем APT-источники..."

# 1. Обрабатываем deb822-файлы .sources
if [ -d /etc/apt/sources.list.d ]; then
    for src in /etc/apt/sources.list.d/*.sources; do
        if [ -f "$src" ]; then
            echo "Найден deb822-файл: $src – перемещаем в /root/apt-backups/"
            mkdir -p /root/apt-backups
            mv "$src" "/root/apt-backups/$(basename "$src").bak-$(date +%Y%m%d%H%M%S)"
        fi
    done
fi

# 2. Удаляем ВСЕ .list файлы (они могут содержать устаревшие или конфликтующие репозитории)
if [ -d /etc/apt/sources.list.d ]; then
    mkdir -p /root/apt-backups
    for listfile in /etc/apt/sources.list.d/*.list; do
        if [ -f "$listfile" ]; then
            echo "Удаляем конфликтующий .list файл: $listfile"
            mv "$listfile" "/root/apt-backups/$(basename "$listfile").bak-$(date +%Y%m%d%H%M%S)"
        fi
    done
fi

# 3. Генерация sources.list в зависимости от версии Debian
if [ "$DEBIAN_VERSION_ID" -le 10 ] 2>/dev/null; then
    # Debian 10 и старше используют archive (без security)
    cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian ${DEBIAN_CODENAME} main contrib non-free non-free-firmware
deb http://archive.debian.org/debian ${DEBIAN_CODENAME}-updates main contrib non-free non-free-firmware
# Security updates for oldoldstable are not available in archive, skipping
EOF
else
    # Debian 11+ используют стандартные зеркала
    cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${DEBIAN_CODENAME} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${DEBIAN_CODENAME}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${DEBIAN_CODENAME}-security main contrib non-free non-free-firmware
EOF
fi

# 4. Для версий младше 12 убираем non-free-firmware
if [ "$DEBIAN_VERSION_ID" -lt 12 ] 2>/dev/null; then
    sed -i 's/ non-free-firmware//g' /etc/apt/sources.list
fi

# 5. Удаляем backports (на всякий случай, если вдруг остались в основном файле)
sed -i '/-backports/d' /etc/apt/sources.list 2>/dev/null || true

echo "APT-источники исправлены."

# --- Обновления (исправлен пункт 3) ---
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

# --- Swap (пункт 4 – не трогаем) ---
echo "# Creating swap file (512 MB)..."
swaps=$(swapon --show=NAME,TYPE --noheadings --raw | awk '$2=="file" {print $1}')
if [ -n "$swaps" ]; then
    echo "Removing existing file‑based swap devices: $swaps"
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

# --- Hostname (исправлен пункт 5) ---
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

# --- Жёсткое отключение IPv6 и блокировка ICMP ---
echo "Hard-disabling IPv6 and blocking ICMP..."
cat > /etc/sysctl.d/99-hardened.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv4.icmp_echo_ignore_all = 1
EOF

# Отключаем IPv6 на уровне ядра через GRUB для надежности
if ! grep -q "ipv6.disable=1" /etc/default/grub; then
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="ipv6.disable=1 /' /etc/default/grub
    update-grub || true
fi
sysctl --system

echo ""
printf "\\033[33m# Configure SSH to listen on ports 22 and 24940.\\033[0m\\n"
mkdir -p /etc/ssh/sshd_config.d
SSH_LISTEN_LINE=""
if [ "$USE_SPLIT_NETWORK" == "true" ]; then
    SSH_LISTEN_LINE="ListenAddress $INBOUND_IP"
fi
cat > /etc/ssh/sshd_config.d/99-custom.conf <<EOF
Port 22
Port 24940
 $SSH_LISTEN_LINE
PermitRootLogin without-password
PubkeyAuthentication yes
EOF

# Ensure drop-in is included (for older Debian if needed)
if ! grep -q "^Include /etc/ssh/sshd_config.d/\*.conf" /etc/ssh/sshd_config; then
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
fi

if sshd -t; then
    systemctl reload ssh
    echo "SSH service reloaded successfully."
else
    echo "SSH configuration syntax error. Reload aborted. Please check /etc/ssh/sshd_config.d/99-custom.conf."
fi
echo ""

# --- Установка пакетов (пункт 9 – добавлен python3-systemd) ---
echo "# Install mc, curl, wget, htop, unattended-upgrades, apt-listchanges, fail2ban, ufw, autossh."
apt install sudo ufw cron rsyslog mc curl wget unzip p7zip-full htop unattended-upgrades apt-listchanges bsd-mailx iptables fail2ban dos2unix locales screen dnsutils openssl gpg autossh python3-systemd -y

# --- Локали (исправлен пункт 10) ---
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

# --- Fail2ban (исправлен пункт 11 + исправлена совместимость Debian 12) ---
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

# Для Debian 12+ (systemd backend) logpath использовать НЕЛЬЗЯ!
F2B_SSHD_LOG=""
if [ "$DEBIAN_VERSION_ID" -lt 12 ] 2>/dev/null; then
    F2B_SSHD_LOG="logpath = %(sshd_log)s"
fi

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 7d
findtime = 180m
maxretry = 4
ignoreip = $F2B_IGNORE_IPS
 $([ "$DEBIAN_VERSION_ID" -ge 12 ] && echo "backend = systemd")

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
printf "\033[1;33m# Don't forget to add the new SSH port (24940) in the client!\033[0m\n"
grep --color 'Port ' /etc/ssh/sshd_config.d/99-custom.conf
read -n1 -s -r -p "Press any key..."; echo

# --- Unattended-upgrades (исправлен пункт 12) ---
echo ""
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
echo "Testing unattended-upgrades configuration..."
if unattended-upgrade --dry-run 2>&1 | grep -qi "allowed origin"; then
    echo "Unattended-upgrades correctly configured."
else
    echo "WARNING: unattended-upgrades may not work. Check allowed origins."
fi
echo "Unattended-upgrades configured."
echo ""

# --- ~/.profile (пункт 13 – не трогаем) ---
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

# --- Скачивание и проверка setup.7z (исправлен пункт 14 + цикл пароля) ---
wget -O setup.7z https://raw.githubusercontent.com/hummer74/new-server/main/setup.7z
if [ ! -s setup.7z ]; then
    echo "Error: downloaded file is empty"
    exit 1
fi

# Устанавливаем xxd, если отсутствует
if ! command -v xxd >/dev/null; then
    apt update && apt install xxd -y
fi

# Проверка сигнатуры 7z (первые 6 байт: 0x37 0x7A 0xBC 0xAF 0x27 0x1C)
if ! dd if=setup.7z bs=1 count=6 2>/dev/null | xxd -p | grep -q "377abcaf271c"; then
    echo "Error: setup.7z is corrupted or not a valid 7z archive"
    exit 1
fi

printf "\\033[33m# Extract /root/.dir from archive (password required).\\033[0m\\n"
# Цикл ввода пароля до 5 попыток
for attempt in {1..5}; do
    read -s -p "Enter password for setup.7z (attempt $attempt/5): " PASSWORD
    echo
    if 7za x -p"$PASSWORD" setup.7z -aoa >/dev/null 2>&1; then
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
echo "Fix directory permissions"
chmod 700 ~/.config/htop
chmod 700 ~/.config/mc
chmod 700 ~/.ssh
echo "Fix all key permissions"
chmod 600 ~/.ssh/* 2>/dev/null
chmod 644 ~/.ssh/*.pub
echo "Fix special files permissions"
chmod 600 ~/.ssh/authorized_keys
chmod 644 ~/.ssh/known_hosts
chmod 644 ~/.ssh/config
echo ""
chmod +x ~/*.sh 2>/dev/null

# --- Пароли (пункт 15 – не трогаем) ---
if [ -f ~/.ssh/passwd.txt ]; then
   chpasswd < ~/.ssh/passwd.txt
else
   echo "~/.ssh/passwd.txt not found, password not changed."
fi
echo ""

# --- Пользователь opossum (пункт 16 – не трогаем) ---
printf "\\033[33m# Add ordinary user OPOSSUM with PASSWORD!\\033[0m\\n"
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

# --- Извлечение файлов opossum (пункт 17 – не трогаем) ---
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
systemctl --failed
echo ""
systemctl reset-failed
safe_name=$(echo "$newhostname" | tr ' ' '_' | tr -cd '[:alnum:]_-')
touch "/root/zzz-$safe_name"
echo ""

# --- UFW (пункт 18 – убран парсинг ss, используются порты из конфига SSH) ---
echo "Configuring UFW firewall..."
# Мы жестко задали порты 22 и 24940 в sshd_config, поэтому просто разрешаем их
for port in 22 24940; do
    if [ "$USE_SPLIT_NETWORK" == "true" ]; then
        ufw allow to "$INBOUND_IP" port "$port" proto tcp
    else
        ufw allow proto tcp port "$port"
    fi
    echo "Allowed SSH port $port in UFW."
done
echo "SSH ports are allowed."
echo ""

# --- Reverse SSH tunnel (пункт 19 – добавлен BindAddress) ---
echo "=============================================="
echo " Setting up Reverse SSH Tunnel to OpenWrt "
echo "=============================================="
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
    LOCAL_SSH_PORT=$(ss -tlnp | grep 'sshd' | awk '{print $4}' | awk -F':' '{print $NF}' | sort -rn | head -n 1)
    if [ -z "$LOCAL_SSH_PORT" ]; then
        LOCAL_SSH_PORT=22
    fi
    echo "Local SSH port: $LOCAL_SSH_PORT" | tee -a "$REVERSE_LOG"
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
        
        BIND_LINE=""
        if [ "$USE_SPLIT_NETWORK" == "true" ]; then
            BIND_LINE="    -o \"BindAddress=$OUTBOUND_IP\" \\"
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
 $BIND_LINE
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

# --- Telemt (пункт 20 – оставлен docker.io, добавлен привязанный порт) ---
echo "# Installing telemt MTProto proxy (non‑interactive)..."
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
if command -v docker-compose >/dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
elif docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker compose"
else
    apt-get update
    apt-get install -y docker-compose
    DOCKER_COMPOSE_CMD="docker-compose"
fi
command -v apparmor_parser >/dev/null || { apt-get update && apt-get install -y apparmor; }
command -v openssl >/dev/null || { apt-get update && apt-get install -y openssl; }
command -v xxd >/dev/null || { apt-get update && apt-get install -y xxd; }
command -v curl >/dev/null || { apt-get update && apt-get install -y curl; }
if ! command -v ufw >/dev/null; then
    apt-get update && apt-get install -y ufw
fi
EXTERNAL_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || curl -s icanhazip.com)
if [ -z "$EXTERNAL_IP" ]; then
    echo "Could not automatically determine external IP. Using fallback 127.0.0.1."
    EXTERNAL_IP="127.0.0.1"
fi
HOST_PORT=8443
TLS_DOMAIN="github.com"
USERNAME="proxy_user"
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
if ufw status | grep -q active; then
    if [ "$USE_SPLIT_NETWORK" == "true" ]; then
        ufw allow to "$INBOUND_IP" port "$HOST_PORT" proto tcp
    else
        ufw allow proto tcp port "$HOST_PORT"
    fi
fi
echo "$HOST_PORT" > "$INSTALL_DIR/ufw_port.txt"
 $DOCKER_COMPOSE_CMD up -d
sleep 5
if docker ps --format '{{.Names}}' | grep -q "^telemt$"; then
    echo "Telemt container is running."
else
    echo "ERROR: Telemt container failed to start. Check logs with 'docker logs telemt'."
fi
LINK="tg://proxy?server=${EXTERNAL_IP}&port=${HOST_PORT}&secret=${FULL_SECRET}"
echo "$LINK" > /root/tg-proxy_secret.txt
echo "Telemt proxy installed. Link saved to /root/tg-proxy_secret.txt"

# --- Crontab (исправлен пункт 21) ---
CRON_TMP=$(mktemp)
crontab -l 2>/dev/null > "$CRON_TMP" || echo "# New crontab" > "$CRON_TMP"

add_cron_job() {
    local job="$1"
    if ! grep -Fxq "$job" "$CRON_TMP"; then
        echo "$job" >> "$CRON_TMP"
    fi
}

add_cron_job "@reboot         date >> /root/reboot.log"
add_cron_job "0 0 1 * *       date > /root/reboot.log"
add_cron_job "1 */2 * * *     /root/telemt-update.sh"
add_cron_job "5 */3 * * *     /root/auto-update.sh"
add_cron_job "*/5 * * * *     systemctl reset-failed"

crontab "$CRON_TMP"
rm -f "$CRON_TMP"
echo "Crontab successfully updated (existing jobs preserved)."

echo ""
printf "\\033[33mLast update and finalizing.\\033[0m\\n"
apt clean -y && rm -rf /var/lib/apt/lists/* && apt update -y && apt full-upgrade -y && apt autoremove -y && apt autoclean
apt autoremove --purge -y

# Настройка Outbound маршрутизации (если была выбрана split-сеть)
if [ "$USE_SPLIT_NETWORK" == "true" ]; then
    MAIN_IFACE=$(ip -4 route | grep default | awk '{print $5}' | head -n1)
    GATEWAY=$(ip -4 route | grep default | awk '{print $3}' | head -n1)
    IP_BIN=$(command -v ip)
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
    $IP_BIN route replace default via "$GATEWAY" dev "$MAIN_IFACE" src "$OUTBOUND_IP"
    echo "Outbound route configured to use $OUTBOUND_IP"
fi

echo "Enabling UFW..."
ufw --force enable
ufw status verbose

echo "REBOOT in 5s..."
sleep 5
reboot now