#!/bin/bash
set -euo pipefail

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

echo "# Install all updates."
dpkg --configure -a
# Remove archived/invalid repos that break apt update (e.g. bullseye-backports)
sed -i '/-backports/d' /etc/apt/sources.list 2>/dev/null || true
sed -i '/-backports/d' /etc/apt/sources.list.d/* 2>/dev/null || true
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
echo "Creating $SWAP_FILE of size \${SWAP_SIZE_MB} MB..."
if fallocate -l "\${SWAP_SIZE_MB}M" "$SWAP_FILE" 2>/dev/null; then
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
read -n1 -s -r -p "Press any key..."; echo
read -p "Type new PRETTY hostname here: " newhostname
hostnamectl set-hostname "$newhostname" --pretty
echo ""
echo ""
echo ""
echo "# Disable ping and IPv6."
echo "blacklist ipv6" > /etc/modprobe.d/blacklist-ipv6.conf
update-initramfs -u
if grep --color 'net.ipv4.icmp_echo_ignore_all=1' /etc/sysctl.conf; then
   echo "Ping already blocked."
else
   echo "Ping will be blocked now. It's OK."
   echo "net.ipv4.icmp_echo_ignore_all=1" >> /etc/sysctl.conf
fi
if grep --color 'net.ipv6.conf.all.disable_ipv6 = 1' /etc/sysctl.conf; then
   echo "IPv6 already blocked."
else
   echo "IPv6 will be blocked now. It's OK."
   echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
fi
sysctl -p
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
    sed -i '/^#\\?PermitRootLogin/d' /etc/ssh/sshd_config
    echo "PermitRootLogin without-password" >> /etc/ssh/sshd_config
fi

if ! grep -q "^PubkeyAuthentication yes" /etc/ssh/sshd_config; then
    sed -i '/^#\\?PubkeyAuthentication/d' /etc/ssh/sshd_config
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
echo "# Install mc, curl, wget, htop, unattended-upgrades, apt-listchanges, fail2ban, ufw."
apt install sudo ufw cron rsyslog mc curl wget unzip p7zip-full htop unattended-upgrades apt-listchanges bsd-mailx iptables fail2ban dos2unix locales screen dnsutils openssl gpg -y

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
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
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
echo "Set UTF-8 locales."
sed -i 's/^# *\\(en_US.UTF-8\\)/\\1/' /etc/locale.gen
sed -i 's/^# *\\(ru_RU.UTF-8\\)/\\1/' /etc/locale.gen
locale-gen
cat <<EOF | tee /etc/default/locale
#  File generated by update-locale
LANG="ru_RU.UTF-8"
#LANG="en_US.UTF-8"
EOF
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
ufw allow 22/tcp
ufw allow 24940/tcp
echo "SSH ports 22 and 24940 are allowed."
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
FULL_SECRET="ee\${SECRET}\${TLS_DOMAIN_HEX}"
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
# Save connection link
LINK="tg://proxy?server=\${EXTERNAL_IP}&port=\${HOST_PORT}&secret=\${FULL_SECRET}"
echo "$LINK" > /root/tg-proxy_secret.txt
echo "Telemt proxy installed. Link saved to /root/tg-proxy_secret.txt"
# --- End of telemt installation ---

# --- Configure IPv6 outgoing (in-IPv4, out-IPv6) ---
printf "\\033[33m# Настроить исходящий IPv6? (не на всех серверах доступно)\\033[0m\\n"
read -p "Включить исходящий IPv6 (in-IPv4, out-IPv6)? (y/N): " enable_ip6out
if [[ "$enable_ip6out" =~ ^[Yy]$ ]]; then
    BACKUP_DIR="/root/ip6out-backup"
    mkdir -p "$BACKUP_DIR"

    IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)
    if [ -z "$IFACE" ]; then
        echo "Ошибка: не удалось определить сетевой интерфейс. Пропуск настройки IPv6."
    else
        echo "Настраиваем исходящий IPv6 на интерфейсе $IFACE..."

        # Backup current state
        cp /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf.bak"
        [ -f /etc/sysctl.d/11-disable-ipv6.conf ] && cp /etc/sysctl.d/11-disable-ipv6.conf "$BACKUP_DIR/11-disable-ipv6.conf.bak" || true
        [ -f /etc/modprobe.d/blacklist-ipv6.conf ] && cp /etc/modprobe.d/blacklist-ipv6.conf "$BACKUP_DIR/blacklist-ipv6.conf.bak" || true
        cp /etc/iproute2/rt_tables "$BACKUP_DIR/rt_tables.bak" 2>/dev/null || true
        ip6tables-save > "$BACKUP_DIR/ip6tables.bak" 2>/dev/null || true
        ip rule show > "$BACKUP_DIR/ip-rules.bak" 2>/dev/null || true
        ip -6 rule show > "$BACKUP_DIR/ip6-rules.bak" 2>/dev/null || true

        # Record what was saved
        > "$BACKUP_DIR/backup-info"
        [ -f "$BACKUP_DIR/11-disable-ipv6.conf.bak" ] && echo "saved_disable_file=yes" >> "$BACKUP_DIR/backup-info" || echo "saved_disable_file=no" >> "$BACKUP_DIR/backup-info"
        [ -f "$BACKUP_DIR/blacklist-ipv6.conf.bak" ] && echo "saved_modprobe=yes" >> "$BACKUP_DIR/backup-info" || echo "saved_modprobe=no" >> "$BACKUP_DIR/backup-info"

        # Remove IPv6 restrictions
        rm -f /etc/modprobe.d/blacklist-ipv6.conf
        rm -f /etc/sysctl.d/11-disable-ipv6.conf
        sed -i '/^net\.ipv6\.conf\.all\.disable_ipv6/d' /etc/sysctl.conf
        sed -i '/^net\.ipv6\.conf\.default\.disable_ipv6/d' /etc/sysctl.conf

        # Add provider IPv6 settings
        cat >> /etc/sysctl.conf <<IPV6EOF

# IPv6 outgoing (in-IPv4, out-IPv6)
net.ipv6.conf.$IFACE.disable_ipv6 = 0
net.ipv6.conf.$IFACE.accept_ra = 2
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.all.addr_gen_mode = 0
net.ipv6.conf.$IFACE.use_tempaddr = 0
IPV6EOF

        sysctl -p

        # Policy routing: create ipv6out table and rule
        grep -q "200.*ipv6out" /etc/iproute2/rt_tables || echo "200 ipv6out" >> /etc/iproute2/rt_tables
        ip -6 route flush table ipv6out 2>/dev/null || true
        IPV6_GW=$(ip -6 route show default | awk '{print $3}' | head -1)
        if [ -n "$IPV6_GW" ]; then
            ip -6 route add default via "$IPV6_GW" dev "$IFACE" table ipv6out
            ip -6 rule add from ::/0 lookup ipv6out priority 100 2>/dev/null || true
            echo "Policy routing настроен. IPv6 gateway: $IPV6_GW"
        else
            echo "Внимание: IPv6 gateway не найден. Policy routing не настроен."
            echo "После перезагрузки или появления IPv6 запустите: /root/ip6out-install.sh"
        fi

        # Disable IPv6 ping (echo-request)
        ip6tables -I INPUT -p icmpv6 --icmpv6-type echo-request -j DROP 2>/dev/null || true

        # Persistence: restore ip rule at boot
        cat > /etc/network/if-up.d/ip6out << 'PERSEOF'
#!/bin/sh
ip -6 rule add from ::/0 lookup ipv6out priority 100 2>/dev/null || true
PERSEOF
        chmod +x /etc/network/if-up.d/ip6out

        echo "Исходящий IPv6 настроен."
    fi
fi

# --- End of IPv6 outgoing configuration ---

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