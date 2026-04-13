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

# --- Определяем версию Debian ---
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

# --- APT источники ---
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
if [ -d /etc/apt/sources.list.d ]; then
    mkdir -p /root/apt-backups
    for listfile in /etc/apt/sources.list.d/*.list; do
        if [ -f "$listfile" ]; then
            echo "Удаляем конфликтующий .list файл: $listfile"
            mv "$listfile" "/root/apt-backups/$(basename "$listfile").bak-$(date +%Y%m%d%H%M%S)"
        fi
    done
fi
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
if [ "$DEBIAN_VERSION_ID" -lt 12 ] 2>/dev/null; then
    sed -i 's/ non-free-firmware//g' /etc/apt/sources.list
fi
sed -i '/-backports/d' /etc/apt/sources.list 2>/dev/null || true
echo "APT-источники исправлены."

# --- Обновления ---
echo "# Install all updates."
dpkg --configure -a
apt clean -y && rm -rf /var/lib/apt/lists/*
apt update -y || { echo "ERROR: apt update failed"; exit 1; }
apt full-upgrade -y || { echo "ERROR: apt full-upgrade failed"; exit 1; }
apt autoremove -y && apt autoclean
apt autoremove --purge -y

# --- Swap ---
echo "# Creating swap file (512 MB)..."
swaps=$(swapon --show=NAME,TYPE --noheadings --raw | awk '$2=="file" {print $1}')
if [ -n "$swaps" ]; then
    for file in $swaps; do
        swapoff "$file" 2>/dev/null || true
        rm -f "$file"
    done
fi
SWAP_FILE="/swapfile"
SWAP_SIZE_MB=512
if fallocate -l "${SWAP_SIZE_MB}M" "$SWAP_FILE" 2>/dev/null; then
    echo "Using fallocate."
else
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB" status=progress
fi
chmod 600 "$SWAP_FILE"
mkswap "$SWAP_FILE"
swapon "$SWAP_FILE"
cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d%H%M%S)
sed -i "\\#^$SWAP_FILE#d" /etc/fstab
echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab

# --- Hostname ---
printf "\\033[33m# Change PRETTY hostname!!!\\033[0m\\n"
while true; do
    read -p "Type new PRETTY hostname here: " newhostname
    if [ -n "$newhostname" ]; then break; else echo "Hostname cannot be empty."; fi
done
hostnamectl set-hostname "$newhostname" --pretty

# --- ПУНКТ 1 и 2: Жёсткое отключение IPv6 и блокировка ICMP ---
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

# --- ПУНКТ 3: SSH (с учетом Debian 12 drop-ins) ---
printf "\\033[33m# Configure SSH to listen on $INBOUND_IP ports 22 and 24940.\\033[0m\\n"
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-custom.conf <<EOF
Port 22
Port 24940
ListenAddress $INBOUND_IP
PermitRootLogin without-password
PubkeyAuthentication yes
EOF

# Очищаем основной конфиг от дублей
sed -i '/^Port /d' /etc/ssh/sshd_config
sed -i '/^ListenAddress /d' /etc/ssh/sshd_config
sed -i '/^#\?PermitRootLogin/d' /etc/ssh/sshd_config
sed -i '/^#\?PubkeyAuthentication/d' /etc/ssh/sshd_config

if sshd -t; then
    systemctl reload ssh
else
    echo "SSH config error!"
fi

# --- Установка пакетов (Исправление: добавлен docker.io и docker-compose) ---
echo "# Install tools and Docker..."
apt install sudo ufw cron rsyslog mc curl wget unzip p7zip-full htop unattended-upgrades apt-listchanges bsd-mailx iptables fail2ban dos2unix locales screen dnsutils openssl gpg autossh docker.io docker-compose python3-systemd -y

# --- Локали ---
echo "Set UTF-8 locales."
locale-gen en_US.UTF-8 ru_RU.UTF-8
cat > /etc/default/locale <<EOF
LANG=ru_RU.UTF-8
EOF
export LANG=ru_RU.UTF-8

# --- ПУНКТ 4: Fail2ban (привязка к IP) ---
echo "Configuring Fail2ban..."
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 7d
findtime = 180m
maxretry = 4
ignoreip = 127.0.0.1/8 $INBOUND_IP $OUTBOUND_IP 176.56.1.165 95.78.162.177 45.86.86.195 46.29.239.23 45.151.139.193 45.38.143.206 217.60.252.204 176.125.243.194 194.58.68.23
$([ "$DEBIAN_VERSION_ID" -ge 12 ] && echo "backend = systemd")

[sshd]
enabled = true
port = 22,24940
EOF
systemctl restart fail2ban

# --- Unattended-upgrades ---
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl restart unattended-upgrades

# --- ~/.profile ---
if ! grep -q "screen -ls" ~/.profile; then
    cat >> ~/.profile << 'EOF'
if screen -ls | grep -q "Detached"; then screen -r 2>/dev/null; fi
sleep 2
sudo mc 2>/dev/null
EOF
fi

# --- Скачивание и проверка setup.7z ---
wget -O setup.7z https://raw.githubusercontent.com/hummer74/new-server/main/setup.7z
if [ -s setup.7z ]; then
    for attempt in {1..5}; do
        read -s -p "Enter password for setup.7z ($attempt/5): " PASSWORD
        echo
        if 7za x -p"$PASSWORD" setup.7z -aoa >/dev/null 2>&1; then
            echo "Extracted."
            break
        fi
        [ $attempt -eq 5 ] && exit 1
    done
    rm -f setup.7z
fi
chmod 700 ~/.ssh && chmod 600 ~/.ssh/* 2>/dev/null && chmod 644 ~/.ssh/*.pub 2>/dev/null

# --- Пароли и Пользователь opossum ---
[ -f ~/.ssh/passwd.txt ] && chpasswd < ~/.ssh/passwd.txt
if ! grep -q "^opossum:" /etc/passwd; then
    read -s -p "Enter password for user opossum: " password
    echo
    pass=$(openssl passwd -6 "$password")
    useradd -m -p "$pass" opossum
    usermod -aG sudo opossum
fi

# Извлечение файлов opossum
if [ -d /home/opossum ] && [ -f /root/opossum.7z ]; then
    cp /root/opossum.7z /home/opossum/
    cd /home/opossum && 7za x opossum.7z -aoa && rm opossum.7z
    chown -R opossum:opossum /home/opossum
    cd /root
fi

# --- ПУНКТ 5: Reverse SSH tunnel (BindAddress) ---
echo "Setting up Reverse Tunnel..."
KEY_PATH="/root/.ssh/ssh2router-key"
if [ -f "$KEY_PATH" ]; then
    chmod 600 "$KEY_PATH"
    NAME_PREFIX=$(echo "$newhostname" | grep -oE '[0-9]{2}' | head -n 1)
    REVERSE_PORT="259${NAME_PREFIX:-00}"
    LOCAL_SSH_PORT=24940
    
    cat > /etc/systemd/system/reverse-tunnel@.service <<EOF
[Unit]
Description=Reverse SSH Tunnel on port %i
After=network.target

[Service]
User=root
Environment="AUTOSSH_GATETIME=0"
ExecStart=/usr/bin/autossh -M 0 -N \\
    -o "StrictHostKeyChecking=no" \\
    -o "UserKnownHostsFile=/dev/null" \\
    -o "BindAddress=$INBOUND_IP" \\
    -o "ServerAliveInterval=60" \\
    -o "ExitOnForwardFailure=yes" \\
    -i $KEY_PATH \\
    -p 24930 \\
    -R %i:127.0.0.1:$LOCAL_SSH_PORT \\
    tunneluser@mousehouse.ignorelist.com
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "reverse-tunnel@${REVERSE_PORT}.service"
    systemctl start "reverse-tunnel@${REVERSE_PORT}.service"
fi

# --- ПУНКТ 6: Telemt (Bind к Inbound IP) ---
echo "Installing telemt..."
HOST_PORT=8443
SECRET=$(openssl rand -hex 16)
INSTALL_DIR="/etc/telemt-docker"
mkdir -p "$INSTALL_DIR/config"
cat > "$INSTALL_DIR/config/telemt.toml" <<EOF
[server]
port = $HOST_PORT
[censorship]
tls_domain = "github.com"
[access.users]
proxy_user = "$SECRET"
EOF
cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
version: '3.3'
services:
  telemt:
    image: whn0thacked/telemt-docker:latest
    container_name: telemt
    restart: unless-stopped
    ports:
      - "$INBOUND_IP:$HOST_PORT:$HOST_PORT"
    volumes:
      - ./config:/etc/telemt
    command: ["/etc/telemt/telemt.toml"]
EOF
cd "$INSTALL_DIR" && docker-compose up -d
LINK="tg://proxy?server=${INBOUND_IP}&port=${HOST_PORT}&secret=ee${SECRET}$(printf "github.com" | xxd -p)"
echo "$LINK" > /root/tg-proxy_secret.txt

# --- ПУНКТ 4 и Исправление: UFW (Привязка к IP + перенос активации в конец) ---
echo "Configuring UFW rules..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
# Разрешаем только на Inbound IP
ufw allow to "$INBOUND_IP" port 22/tcp
ufw allow to "$INBOUND_IP" port 24940/tcp
ufw allow to "$INBOUND_IP" port "$HOST_PORT"/tcp

# Настройка Outbound маршрутизации (Исправление: универсальный путь ip)
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
fi

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
# --- Финализация (Включение UFW и Ребут) ---
echo "Enabling UFW and finalizing..."
ufw --force enable

printf "\\033[33mLast update and Reboot...\\033[0m\\n"
apt clean -y && rm -rf /var/lib/apt/lists/* && apt update -y && apt full-upgrade -y && apt autoremove --purge -y && apt autoclean
echo "REBOOT... 30s"
sleep 30
reboot now
