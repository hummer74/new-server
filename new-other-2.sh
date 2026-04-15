#!/bin/bash
set -euo pipefail

# === Log all output to /var/log/new-other.log ===
LOG_FILE="/var/log/new-other.log"
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

# --- APT Sources ---
echo "Checking and fixing APT sources..."
if [ -d /etc/apt/sources.list.d ]; then
    mkdir -p /root/apt-backups
    for src in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
        if [ -f "$src" ]; then
            echo "Moving $src to /root/apt-backups/"
            mv "$src" "/root/apt-backups/$(basename "$src").bak-$(date +%Y%m%d%H%M%S)"
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
echo "APT sources fixed."

# --- Updates ---
echo "# Updating package lists and upgrading system..."
dpkg --configure -a
apt clean -y && rm -rf /var/lib/apt/lists/*
apt update -y || { echo "ERROR: apt update failed"; exit 1; }
apt full-upgrade -y || { echo "ERROR: apt full-upgrade failed"; exit 1; }
apt autoremove -y && apt autoclean
apt autoremove --purge -y

# --- Swap ---
echo "# Configuring swap file (512 MB)..."
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
[ -f /etc/fstab ] && cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d%H%M%S)
sed -i "\\#^$SWAP_FILE#d" /etc/fstab
echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab

# --- Hostname ---
printf "\\033[33m# Change PRETTY hostname\\033[0m\\n"
read -p "Type new PRETTY hostname: " newhostname
if [ -n "$newhostname" ]; then
    hostnamectl set-hostname "$newhostname" --pretty
fi

# --- Hard-disable IPv6 and block ICMP ---
echo "Hard-disabling IPv6 and blocking ICMP..."
cat > /etc/sysctl.d/99-hardened.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv4.icmp_echo_ignore_all = 1
EOF

if [ -f /etc/default/grub ]; then
    if ! grep -q "ipv6.disable=1" /etc/default/grub; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="ipv6.disable=1 /' /etc/default/grub
        update-grub || true
    fi
fi
sysctl --system

# --- SSH Configuration ---
echo "Configuring SSH..."
mkdir -p /etc/ssh/sshd_config.d
SSH_LISTEN_EXTRA=""
if [ "$USE_SPLIT_NETWORK" == "true" ]; then
    SSH_LISTEN_EXTRA="ListenAddress 127.0.0.1
ListenAddress $INBOUND_IP"
fi

cat > /etc/ssh/sshd_config.d/99-custom.conf <<EOF
Port 22
Port 24940
$SSH_LISTEN_EXTRA
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
EOF

if ! grep -q "^Include /etc/ssh/sshd_config.d/\*.conf" /etc/ssh/sshd_config; then
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
fi

if sshd -t; then
    systemctl reload ssh
else
    echo "SSH configuration syntax error."
fi

# --- Install Packages ---
echo "# Installing standard tools and security packages..."
apt install sudo ufw cron rsyslog mc curl wget unzip p7zip-full htop unattended-upgrades apt-listchanges bsd-mailx iptables fail2ban dos2unix locales screen dnsutils openssl gpg python3-systemd -y

# --- Locales ---
echo "Setting UTF-8 locales..."
locale-gen en_US.UTF-8 ru_RU.UTF-8
if ! locale -a | grep -qi "ru_ru\.utf8\|ru_ru\.utf-8"; then
    sed -i 's/^# ru_RU.UTF-8/ru_RU.UTF-8/' /etc/locale.gen
    locale-gen ru_RU.UTF-8
fi
echo "LANG=ru_RU.UTF-8" > /etc/default/locale
export LANG=ru_RU.UTF-8

# --- Fail2ban ---
echo "Configuring Fail2ban..."
systemctl enable fail2ban.service
cat > /etc/fail2ban/fail2ban.local <<EOF
[Definition]
allowipv6 = auto
EOF

F2B_SSHD_LOG=""
[ "$DEBIAN_VERSION_ID" -lt 12 ] && F2B_SSHD_LOG="logpath = %(sshd_log)s"
F2B_BACKEND_LINE=""
[ "$DEBIAN_VERSION_ID" -ge 12 ] && F2B_BACKEND_LINE="backend = systemd"

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 7d
findtime = 180m
maxretry = 4
$F2B_BACKEND_LINE

[sshd]
enabled = true
port = 22,24940
$F2B_SSHD_LOG
EOF

if fail2ban-client -t >/dev/null 2>&1; then
    systemctl restart fail2ban.service
fi

# --- Unattended-upgrades ---
echo "Configuring unattended-upgrades..."
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
EOF
systemctl enable unattended-upgrades
systemctl restart unattended-upgrades

# --- ~/.profile ---
if ! grep -q "sudo mc" ~/.profile; then
    cat >> ~/.profile << 'EOF'

# Launch mc after a short delay
sleep 2
sudo mc 2>/dev/null
EOF
fi

# --- Maintenance Scripts ---
echo "Creating maintenance scripts..."

# 1. auto-update.sh
cat > /root/auto-update.sh << 'EOF'
#!/bin/bash
set -euo pipefail
LOGFILE="/var/log/auto-update.log"
echo "[$(date)] Starting system update..." >> "$LOGFILE"
apt clean -y
rm -rf /var/lib/apt/lists/*
apt update -y
upgradable=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)
if [ "$upgradable" -eq 0 ]; then
    echo "[$(date)] No updates available." >> "$LOGFILE"
else
    echo "[$(date)] Found $upgradable package(s) to upgrade." >> "$LOGFILE"
    apt full-upgrade -y >> "$LOGFILE" 2>&1
fi
apt autoremove -y && apt autoclean -y
echo "[$(date)] Update completed." >> "$LOGFILE"
EOF
chmod +x /root/auto-update.sh

# 2. telemt-update.sh
cat > /root/telemt-update.sh << 'EOF'
#!/bin/bash
set -euo pipefail
PROJECT_DIR="/etc/telemt-docker"
LOG_FILE="/var/log/telemt-update.log"
MAX_LOG_LINES=1000
[ "$EUID" -ne 0 ] && exit 1
if command -v docker-compose >/dev/null; then COMPOSE_CMD="docker-compose";
elif docker compose version >/dev/null 2>&1; then COMPOSE_CMD="docker compose";
else exit 1; fi
get_image_id() { docker inspect --format='{{.Id}}' "whn0thacked/telemt-docker:latest" 2>/dev/null | sed 's/sha256://'; }
log_single() {
    local msg="$1"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$ts - $msg" >> "$LOG_FILE"
}
cd "$PROJECT_DIR" || exit 1
OLD_ID=$(get_image_id)
$COMPOSE_CMD pull --quiet >/dev/null 2>&1 || exit 2
NEW_ID=$(get_image_id)
if [ "$OLD_ID" != "$NEW_ID" ]; then
    log_single "🔄 New version found! Restarting container..."
    $COMPOSE_CMD up -d --remove-orphans >/dev/null 2>&1 && log_single "✅ Telemt updated" || log_single "❌ Restart failed"
fi
docker image prune -f &>/dev/null || true
if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt "$MAX_LOG_LINES" ]; then
    tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi
EOF
chmod +x /root/telemt-update.sh

# --- Telemt MTProto Proxy (Docker) ---
echo "# Installing telemt MTProto proxy..."
if ! command -v docker >/dev/null; then
    apt-get update && apt-get install -y docker.io
    systemctl enable --now docker
fi
if command -v docker-compose >/dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
elif docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker compose"
else
    apt-get update && apt-get install -y docker-compose
    DOCKER_COMPOSE_CMD="docker-compose"
fi

if [ "$USE_SPLIT_NETWORK" == "true" ]; then
    EXTERNAL_IP="$INBOUND_IP"
else
    EXTERNAL_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || echo "127.0.0.1")
fi

HOST_PORT=8443
TLS_DOMAIN="github.com"
USERNAME="proxy_user"
SECRET=$(openssl rand -hex 16)
TLS_DOMAIN_HEX=$(printf "%s" "$TLS_DOMAIN" | xxd -p -c 1000 | tr -d '\n')
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
[ "$USE_SPLIT_NETWORK" == "true" ] && TELEMT_PORT_BIND="$INBOUND_IP:$HOST_PORT"

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

$DOCKER_COMPOSE_CMD up -d
LINK="tg://proxy?server=${EXTERNAL_IP}&port=${HOST_PORT}&secret=${FULL_SECRET}"
echo "$LINK" > /root/tg-proxy_secret.txt
echo "Telemt proxy installed. Link saved to /root/tg-proxy_secret.txt"

# --- Crontab ---
CRON_TMP=$(mktemp)
crontab -l 2>/dev/null > "$CRON_TMP" || echo "# New crontab" > "$CRON_TMP"
add_cron_job() {
    grep -Fxq "$1" "$CRON_TMP" || echo "$1" >> "$CRON_TMP"
}
add_cron_job "@reboot         date >> /root/reboot.log"
add_cron_job "0 0 1 * *       date > /root/reboot.log"
add_cron_job "1 */2 * * *     /root/telemt-update.sh"
add_cron_job "5 */3 * * *     /root/auto-update.sh"
add_cron_job "*/5 * * * *     systemctl reset-failed"
crontab "$CRON_TMP"
rm -f "$CRON_TMP"

# --- UFW ---
echo "Configuring UFW..."
for port in 22 24940 "$HOST_PORT"; do
    if [ "$USE_SPLIT_NETWORK" == "true" ]; then
        ufw allow to "$INBOUND_IP" port "$port" proto tcp
    else
        ufw allow "$port/tcp"
    fi
done

# Outbound routing (split-network)
if [ "$USE_SPLIT_NETWORK" == "true" ]; then
    MAIN_IFACE=$(ip -4 route | grep default | awk '{print $5}' | head -n1)
    GATEWAY=$(ip -4 route | grep default | awk '{print $3}' | head -n1)
    if [ -n "$GATEWAY" ] && [ -n "$MAIN_IFACE" ]; then
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
        $IP_BIN route replace default via "$GATEWAY" dev "$MAIN_IFACE" src "$OUTBOUND_IP" || true
    fi
fi

echo "Enabling UFW..."
ufw --force enable

# Create a marker file with the pretty hostname
safe_name=$(echo "$newhostname" | tr ' ' '_' | tr -cd '[:alnum:]_-')
touch "/root/zzz-$safe_name"

echo "Finalizing..."
apt clean -y && apt autoremove --purge -y

echo "Done. REBOOT in 5s..."
sleep 5
reboot now
