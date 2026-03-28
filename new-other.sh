#!/bin/bash

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

echo "# Install all updates."
dpkg --configure -a
apt clean -y && rm -rf /var/lib/apt/lists/* && apt update -y && apt full-upgrade -y && apt autoremove -y && apt autoclean && apt purge ~c -y
echo ""
echo ""
echo ""
printf "\033[33m# Change PRETTY hostname!!!\033[0m\n"
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
printf "\033[33m# Configure SSH to listen on ports 22 and 24940.\033[0m\n"
read -n1 -s -r -p "Press any key..."; echo

# Check if ports are already configured to avoid duplicate entries
if ! grep -q "^Port 22$" /etc/ssh/sshd_config || ! grep -q "^Port 24940$" /etc/ssh/sshd_config; then
    sed -i '/^Port /d' /etc/ssh/sshd_config
    echo "Port 22" >> /etc/ssh/sshd_config
    echo "Port 24940" >> /etc/ssh/sshd_config
    echo "Ports 22 and 24940 configured in sshd_config."
else
    echo "Ports 22 and 24940 are already configured."
fi

# Set PermitRootLogin without-password and PubkeyAuthentication yes
if ! grep -q "^PermitRootLogin without-password" /etc/ssh/sshd_config; then
    sed -i '/^#\?PermitRootLogin/d' /etc/ssh/sshd_config
    echo "PermitRootLogin without-password" >> /etc/ssh/sshd_config
fi

if ! grep -q "^PubkeyAuthentication yes" /etc/ssh/sshd_config; then
    sed -i '/^#\?PubkeyAuthentication/d' /etc/ssh/sshd_config
    echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
fi

# Keep password authentication as originally in new-other.sh
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
grep -q '^PasswordAuthentication' /etc/ssh/sshd_config || echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config

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
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
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

# Create auto-update.sh script
cat > /root/auto-update.sh << 'EOF'
#!/bin/bash

# Check root privileges
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root." >&2
    exit 1
fi

echo "Starting system update and cleanup..."

# 1. Clean and update package cache
apt clean -y
rm -rf /var/lib/apt/lists/*
apt update -y

# 2. Check for available updates
upgradable_count=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)

if [ "$upgradable_count" -eq 0 ]; then
    echo "No updates available. Performing cleanup only, no reboot."
    # Final cleanup
    apt autoremove -y
    apt autoclean -y
    apt autoremove --purge -y
    exit 0
fi

echo "Found $upgradable_count package(s) to upgrade. Proceeding with full upgrade..."

# 3. Perform full system upgrade
apt full-upgrade -y
upgrade_status=$?

# 4. Final cleanup after upgrade
apt autoremove -y
apt autoclean -y
apt autoremove --purge -y

# 5. Check upgrade result
if [ $upgrade_status -eq 0 ]; then
    echo "Update completed successfully. Rebooting in 15 seconds (Ctrl+C to cancel)..."
    sleep 15
    reboot now
else
    echo "Update failed. Reboot aborted." > /root/auto-update.log
    exit 2
fi
EOF

# Make the script executable
chmod +x /root/auto-update.sh
echo "Script auto-update.sh created and made executable."
echo ""

# Improved ~/.profile additions (including screen)
if ! grep -q "screen -ls | grep -q" ~/.profile; then
    cat >> ~/.profile << 'EOF'

# Attach to a detached screen session if available
if screen -ls | grep -q "Detached"; then
    screen -r 2>/dev/null
fi

# Launch mc after a short delay
sleep 1
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
sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^# *\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
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

# Configure Fail2ban (do not modify original jail.conf/fail2ban.conf)
systemctl enable fail2ban.service

# Create fail2ban.local to set allowipv6 (do not touch fail2ban.conf)
cat > /etc/fail2ban/fail2ban.local <<EOF
[Definition]
allowipv6 = auto
EOF

# Create jail.local with main settings (do not touch jail.conf)
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 7d
findtime = 120m
maxretry = 4
ignoreip = 127.0.0.1 192.168.0.0/16
[sshd]
enabled = true
port = 22,24940
EOF

systemctl restart fail2ban.service
systemctl status fail2ban.service
printf "\033[33m# Don't forget to add the new SSH port (24940) in the client!\033[0m\n"
grep --color 'Port ' /etc/ssh/sshd_config
read -n1 -s -r -p "Press any key..."; echo
echo ""
echo ""
echo ""

# Fix permissions for files in ~/.ssh (if they exist)
if [ -d ~/.ssh ]; then
    echo "Fix directory permissions"
    chmod 700 ~/.ssh
    echo "Fix key permissions"
    chmod 600 ~/.ssh/* 2>/dev/null
    chmod 644 ~/.ssh/*.pub 2>/dev/null
    echo "Fix special files permissions"
    chmod 600 ~/.ssh/authorized_keys 2>/dev/null
    chmod 644 ~/.ssh/known_hosts 2>/dev/null
    chmod 644 ~/.ssh/config 2>/dev/null
fi

echo ""
echo ""
echo ""

systemctl --failed
echo ""
systemctl reset-failed
# Create a marker file with the pretty hostname
safe_name=$(echo "$newhostname" | tr ' ' '_' | tr -cd '[:alnum:]_-')
touch "zzz-$safe_name"
echo ""
echo ""
echo ""
echo ""
echo ""

# Configure UFW firewall – add rules and ask whether to enable
echo "Configuring UFW firewall..."
# Add rules for SSH ports
ufw allow 22/tcp
ufw allow 24940/tcp
echo "SSH ports 22 and 24940 are allowed."
# Interactive prompt to enable
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

# Set new cron jobs, completely replacing the current crontab
crontab - <<EOF
@reboot		date >> /root/reboot.log
* * * * *	systemctl reset-failed
0 1 * * *	/root/auto-update.sh
0 0 1 * *	date > /root/reboot.log
EOF

echo "Crontab successfully updated."
echo ""
echo ""
echo ""
printf "\033[33mLast update.\033[0m\n"
read -n1 -s -r -p "Press any key..."; echo
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
reboot now