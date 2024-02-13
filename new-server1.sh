#!/bin/bash
# shellcheck disable=SC1091,SC2164,SC2034,SC1072,SC1073,SC1009

echo "# Install all update."
cp /usr/share/doc/apt/examples/sources.list /etc/apt/sources.list
apt update -y && apt full-upgrade -y && apt autoremove -y && apt autoclean &&
echo ""
echo ""
echo ""

echo "# Disable ping and IPv6."
read  -p  "Press Enter for process..."
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

echo  -e "\033[31m# Change SSH port to 24940.\033[0m"
read  -p  "Press Enter for process..."
grep --color '#Port ' /etc/ssh/sshd_config
sudo sh -c "sed -i 's/#Port /Port /' /etc/ssh/sshd_config"
grep --color 'Port ' /etc/ssh/sshd_config; read -p "Current SSH port : " search
read -p "New (desired) SSH port : " replace
sudo sh -c "sed -i 's/Port $search/Port $replace/' /etc/ssh/sshd_config"
echo ""
echo ""
echo ""
systemctl restart ssh
systemctl status ssh
echo ""
echo ""
echo ""

echo "# Install mc, curl, wget, htop, unattended-upgrades, apt-listchanges, fail2ban."
read  -p  "Press Enter for process..."
apt install mc curl wget htop unattended-upgrades apt-listchanges bsd-mailx iptables fail2ban dos2unix locales -y &&
echo ""
echo "Set UTF-8 locales."
sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^# *\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
locale-gen
sudo cat <<EOF | sudo tee /etc/default/locale
#  File generated by update-locale
LANG="ru_RU.UTF-8"
#LANG="en_US.UTF-8"
EOF


echo "sudo mc" >> ~/.profile
echo ""
echo ""
sysctl --system
systemctl enable fail2ban.service
echo "Old fail2ban setting:"
grep --color 'bantime ' /etc/fail2ban/jail.conf
grep --color 'findtime ' /etc/fail2ban/jail.conf
grep --color 'maxretry ' /etc/fail2ban/jail.conf
sudo sh -c "sed -i 's/\s\s*/ /g' /etc/fail2ban/jail.conf"
sudo sh -c "sed -i 's/bantime = 10m/bantime = 360m/' /etc/fail2ban/jail.conf"
sudo sh -c "sed -i 's/findtime = 10m/findtime = 60m/' /etc/fail2ban/jail.conf"
sudo sh -c "sed -i 's/maxretry = 5/maxretry = 3/' /etc/fail2ban/jail.conf"
echo ""
echo ""
echo ""
echo "New fail2ban setting:"
grep --color 'bantime = ' /etc/fail2ban/jail.conf
grep --color 'findtime = ' /etc/fail2ban/jail.conf
grep --color 'maxretry = ' /etc/fail2ban/jail.conf
read  -p  "Press Enter for process..."
systemctl restart fail2ban.service
systemctl status fail2ban.service


echo ""
echo ""
echo "# Change root password to 'ROOT identity'."
read  -p  "Press Enter for process..."
echo "root:Ux8H29XWFSTvbnfb5X" | chpasswd
echo ""
echo ""
echo ""

echo -e "\033[31mDon't forget to add the new SSH port in the client!\033[0m"
grep --color 'Port ' /etc/ssh/sshd_config
echo ""
echo -e "\033[31mDon't forget new root password! ROOT IDENTITY in Termius!\033[0m"
echo ""
echo ""
echo ""
echo ""
echo ""
echo ""

echo "# Please copy '.ssh' directory from your LOCAL-MACHINE to REMOTE /home directory!!!"
read  -p  "Press Enter for continue..."
echo ""
echo ""
echo ""
echo ""
echo ""
echo ""
echo "Fix directory permissions"
# Fix directory permissions
chmod 700 ~/.ssh
echo ""
echo "Fix all key permissions"
# Fix all key permissions
chmod 600 ~/.ssh/*
chmod 644 ~/.ssh/*.pub
echo ""
echo "Fix special files permissions"
# Fix special files permissions
chmod 644 ~/.ssh/authorized_keys
chmod 644 ~/.ssh/known_hosts
chmod 644 ~/.ssh/config
echo ""
echo ""
echo ""
echo ""
read  -p  "Press Enter for last update and reboot..."
apt update -y && apt full-upgrade -y && apt autoremove -y && apt autoclean && reboot now
echo ""
echo ""
echo ""
