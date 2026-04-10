#!/bin/bash

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

echo "Installing fail2ban and dependencies..."
apt update -y && apt install -y fail2ban iptables

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
findtime = 180m
maxretry = 4
ignoreip = 176.56.1.165 95.78.162.177 45.86.86.195 46.29.239.23 45.151.139.193 45.38.143.206 217.60.252.204 176.125.243.194 194.58.68.23

[sshd]
enabled = true
port = 22,24940
EOF

systemctl restart fail2ban.service
systemctl status fail2ban.service

printf "\033[33m# Don't forget to add the new SSH port (24940) in the client!\033[0m\n"
grep --color 'Port ' /etc/ssh/sshd_config
read -n1 -s -r -p "Press any key..."; echo