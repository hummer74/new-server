#!/bin/bash

echo "# Install all update."
cat /usr/share/doc/apt/examples/sources.list > /etc/apt/sources.list
apt update -y && apt full-upgrade -y && apt autoremove -y && apt autoclean &&
echo ""
echo ""
echo ""
echo  -e "\033[31m# Change PRETTY hostname!!!\033[0m"
read  -p  "Press Enter for process..."
read -p "Type new PRETTY hostname here: " newhostname
hostnamectl set-hostname $newhostname --pretty
hostnamectl
echo ""
echo ""
echo ""
echo "# Disable ping and IPv6."
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
systemctl restart ssh
systemctl status ssh
echo ""
echo ""
echo ""
echo "# Install mc, curl, wget, htop, unattended-upgrades, apt-listchanges, fail2ban."
apt install mc curl wget unzip p7zip-full htop unattended-upgrades apt-listchanges bsd-mailx iptables fail2ban dos2unix locales -y &&
echo "sudo mc" >> ~/.profile
echo ""
echo ""
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
echo ""
echo ""
echo ""
sysctl --system
systemctl enable fail2ban.service
sudo sh -c "sed -i 's/\s\s*/ /g' /etc/fail2ban/jail.conf"
sudo sh -c "sed -i 's/bantime = 10m/bantime = 600m/' /etc/fail2ban/jail.conf"
sudo sh -c "sed -i 's/findtime = 10m/findtime = 60m/' /etc/fail2ban/jail.conf"
sudo sh -c "sed -i 's/maxretry = 5/maxretry = 3/' /etc/fail2ban/jail.conf"
echo ignoreip = 176.226.xxx.xxx 176.56.1.165 95.215.8.184 45.86.86.195 38.114.100.162 > /etc/fail2ban/jail.local
cat /etc/fail2ban/jail.local
systemctl restart fail2ban.service
echo ""
echo ""
echo ""
echo -e "\033[31mDon't forget to add the new SSH port in the client!\033[0m"
grep --color 'Port ' /etc/ssh/sshd_config
echo -e "\033[31mDon't forget new root password! ROOT IDENTITY in Termius!\033[0m"
echo ""
echo ""
echo ""
echo "# Copy .directory from 7z archive."
read  -p  "Press Enter for continue..."
curl -O https://raw.githubusercontent.com/hummer74/new-server/main/setup.7z 
7za x setup.7z -aoa
echo ""
rm ~/setup.7z
echo "Fix directory permissions"
chmod 700 ~/.config/htop
chmod 700 ~/.config/mc
chmod 700 ~/.ssh
echo ""
echo "Fix all key permissions"
chmod 600 ~/.ssh/*
chmod 644 ~/.ssh/*.pub
echo ""
echo "Fix special files permissions"
chmod 644 ~/.ssh/authorized_keys
chmod 644 ~/.ssh/known_hosts
chmod 644 ~/.ssh/config
echo ""
echo ""
echo ""
echo  -e "\033[31m# Change root password to 'ROOT identity'!\033[0m"
read  -p  "Press Enter for process..."
cat ~/.ssh/passwd.txt | chpasswd
echo ""
echo ""
echo ""
echo ""
echo "Install VLESS, Xray-Reality."
read -p "Do you want to proceed? (y/n)" yn1
if [[ "$yn1" =~ ^[yY]+$ ]]; then
   echo "# Ok. Install VLESS, Xray-Reality."
   read  -p  "Press Enter for process..."
   wget -O up-xray.sh https://github.com/XTLS/Xray-install/raw/main/install-release.sh
   chmod +x up-xray.sh
   bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
else
    echo "Ok. Go to next point..."
fi
echo ""
echo ""
echo ""
echo "# Install 3X-UI."
echo -e "\033[31m# Opossum, StandardPass, Port: 33900\033[0m."
read -p "Do you want to proceed? (y/n)" yn1
if [[ "$yn1" =~ ^[yY]+$ ]]; then
   echo "# Ok. Install 3X-UI."
   read  -p  "Press Enter for process..."
   wget -O up-3x-ui.sh https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh
   chmod +x up-3x-ui.sh
   bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
else
    echo "Ok. Go to next point..."
fi
echo ""
echo ""
echo ""
echo -e "# Install WireGuard, port \033[31m33901\033[0m."
read -p "Do you want to proceed? (y/n)" yn1
if [[ "$yn1" =~ ^[yY]+$ ]]; then
   echo "# Ok. Install WireGuard."
   read  -p  "Press Enter for process..."
   wget -O up-wreguard.sh https://raw.githubusercontent.com/angristan/wireguard-install/master/wireguard-install.sh
   chmod +x up-wreguard.sh
   bash <(curl -Ls https://raw.githubusercontent.com/angristan/wireguard-install/master/wireguard-install.sh)
   sysctl --system
   systemctl restart wg-quick@wg0
   systemctl status wg-quick@wg0
else
    echo "Ok. Go to next point..."
fi
echo ""
echo ""
echo ""
echo -e "# Install OpenVPN, port \033[31m33902\033[0m."
read -p "Do you want to proceed? (y/n)" yn1
if [[ "$yn1" =~ ^[yY]+$ ]]; then
   echo "# Ok. Install OpenVPN."
   read  -p  "Press Enter for process..."
   wget -O up-openvpn.sh https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh
   chmod +x up-openvpn.sh
   bash <(curl -Ls https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh)
else
    echo "Ok. Go to next point..."
fi
echo ""
echo ""
systemctl --failed
read  -p  "Press Enter for process..."
systemctl reset-failed
systemctl --failed
echo ""
echo -e "\033[31mLast update and reboot...\033[0m"
read  -p  "Press Enter for last update and reboot..."
apt update -y && apt full-upgrade -y && apt autoremove -y && apt autoclean
echo ""
echo ""
echo "REBOOT..."
reboot now
