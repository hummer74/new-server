#!/bin/bash

echo "# Install all update."
# cat /usr/share/doc/apt/examples/sources.list > /etc/apt/sources.list
apt clean -y && rm -rf /var/lib/apt/lists/* && apt update -y && apt full-upgrade -y && apt autoremove -y && apt autoclean &&
echo ""
echo ""
echo ""
echo  -e "\033[31m# Change PRETTY hostname!!!\033[0m"
read  -p  "Press any key..."
read -p "Type new PRETTY hostname here: " newhostname
hostnamectl set-hostname $newhostname --pretty
read -p "Type new STATIC hostname here: " newhostname1
hostnamectl set-hostname $newhostname1
hostnamectl
echo ""
echo ""
echo ""
echo "# Disable ping and IPv6."
echo "blacklist ipv6 " > /etc/modprobe.d/blacklist-ipv6.conf
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
echo  -e "\033[31m# Change SSH port to 24940.\033[0m"
read  -p  "Press any key..."
grep --color '#Port ' /etc/ssh/sshd_config
sh -c "sed -i 's/#Port /Port /' /etc/ssh/sshd_config"
grep --color 'Port ' /etc/ssh/sshd_config; read -p "Current SSH port : " search
read -p "New (desired) SSH port : " replace
 sh -c "sed -i 's/Port $search/Port $replace/' /etc/ssh/sshd_config"
echo ""
echo ""
echo ""
grep --color 'PermitRootLogin yes' /etc/ssh/sshd_config
 sh -c "sed -i 's/PermitRootLogin yes/PermitRootLogin without-password/' /etc/ssh/sshd_config"
grep --color 'PermitRootLogin without-password' /etc/ssh/sshd_config
grep --color '#PubkeyAuthentication yes' /etc/ssh/sshd_config
 sh -c "sed -i 's/#PubkeyAuthentication/PubkeyAuthentication/' /etc/ssh/sshd_config"
grep --color 'PubkeyAuthentication yes' /etc/ssh/sshd_config
echo ""
echo ""
echo ""
systemctl restart ssh
systemctl status ssh
echo ""
echo ""
echo ""
echo "# Install mc, curl, wget, htop, unattended-upgrades, apt-listchanges, fail2ban."
apt install rsyslog mc curl wget unzip p7zip-full htop unattended-upgrades apt-listchanges bsd-mailx iptables fail2ban dos2unix locales screen dnsutils -y &&

egrep "sudo mc" ~/.profile >/dev/null
	if [ $? -eq 0 ]; then
		echo "Midnight Commander exists!"
	else
		echo "screen -r" >> ~/.profile
		echo "sudo mc" >> ~/.profile
	fi

echo ""
echo ""
echo ""
echo "Set UTF-8 locales."
sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^# *\(ru_RU.UTF-8\)/\1/' /etc/locale.gen
locale-gen
 cat <<EOF |  tee /etc/default/locale
#  File generated by update-locale
LANG="ru_RU.UTF-8"
#LANG="en_US.UTF-8"
EOF
echo ""
echo ""
echo ""
sysctl --system
systemctl enable fail2ban.service
 sh -c "sed -i 's/\s\s*/ /g' /etc/fail2ban/jail.conf"
 sh -c "sed -i 's/bantime = 10m/bantime = 600m/' /etc/fail2ban/jail.conf"
 sh -c "sed -i 's/findtime = 10m/findtime = 60m/' /etc/fail2ban/jail.conf"
 sh -c "sed -i 's/maxretry = 5/maxretry = 3/' /etc/fail2ban/jail.conf"
if grep --color '#allowipv6 = auto' /etc/sysctl.conf; then
   sh -c "sed -i 's/#allowipv6 = auto/allowipv6 = auto/" /etc/fail2ban/fail2ban.conf
else
   echo "allowipv6 = AUTO now. It's OK."
fi
echo '[DEFAULT]' > /etc/fail2ban/jail.local
echo 'ignoreip = 176.226.0.0 176.56.1.165 45.86.86.195 46.29.239.23 38.114.100.162' >> /etc/fail2ban/jail.local
cat /etc/fail2ban/jail.local
systemctl restart fail2ban.service
systemctl status fail2ban.service
echo -e "\033[31mDon't forget to add the new SSH port in the client!\033[0m"
grep --color 'Port ' /etc/ssh/sshd_config
read  -p  "Press any key..."
echo ""
echo ""
echo ""
wget -O setup.7z https://raw.githubusercontent.com/hummer74/new-server/main/setup.7z 
echo -e "\033[31m# Copy /root/.dir from archive.pass.\033[0m"
read  -p  "Press any key..."
7za x setup.7z -aoa
rm setup.7z
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
cat ~/.ssh/passwd.txt | chpasswd
echo ""
echo ""
echo ""
echo  -e "\033[31m# Add ordinary user OPOSSUM with PASSWORD!\033[0m"
userdel -r opossum
if [ $(id -u) -eq 0 ]; then
	read -s -p "Enter password : " password
	egrep "opossum" /etc/passwd >/dev/null
	if [ $? -eq 0 ]; then
		echo "opossum exists!"
	else
		pass=$(perl -e 'print crypt($ARGV[0], "password")' $password)
		useradd -m -p "$pass" "opossum"
		[ $? -eq 0 ] && echo "User opossum has been added to system!" || echo "Failed to add a user!"
		usermod -a -G sudo opossum
	fi
else
	echo "Only root may add a user to the system."
fi
cd /home/opossum
wget -O opossum.7z https://raw.githubusercontent.com/hummer74/new-server/main/opossum.7z
wget -O opossum.sh https://raw.githubusercontent.com/hummer74/new-server/main/opossum.sh
chmod +x opossum.sh
cd /root
echo ""
echo ""
echo ""
echo "Install VLESS, Xray-Reality."
read -p "Do you want to proceed? (Y/N. Default [N].)" yn1
if [[ "$yn1" =~ ^[yY]+$ ]]; then
   echo "# Ok. Install VLESS, Xray-Reality."
   read  -p  "Press any key..."
   wget -O up-xray.sh https://github.com/XTLS/Xray-install/raw/main/install-release.sh
   chmod +x up-xray.sh
   bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
else
    yn1='N'
    echo "Ok. Go to next point..."
fi
echo ""
echo ""
echo ""
echo "# Install 3X-UI."
echo -e "\033[31m# Opossum, StandardPass, Port: 33900\033[0m."
read -p "Do you want to proceed? (Y/N. Default [N].)" yn1
if [[ "$yn1" =~ ^[yY]+$ ]]; then
   echo "# Ok. Install 3X-UI."
   read  -p  "Press any key..."
   wget -O zz-3x-ui.sh https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh
   echo "x-ui" > up-3x-ui.sh
   chmod +x up-3x-ui.sh
   bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
else
    yn1='N'
    echo "Ok. Go to next point..."
fi
systemctl --failed
echo ""
read  -p  "Type server NAME for TOUCH...     " servname
touch zzz-$servname
echo ""
echo ""
echo ""
echo -e "\033[31mLast update.\033[0m"
read  -p  "Press any key..."
apt clean -y && rm -rf /var/lib/apt/lists/* && apt update -y && apt full-upgrade -y && apt autoremove -y && apt autoclean &&
echo ""
echo ""
echo -e "# Install WireGuard, port \033[31m33901\033[0m."
read -p "Do you want to proceed? (Y/N. Default [N].)" yn1
if [[ "$yn1" =~ ^[yY]+$ ]]; then
   echo "# Ok. Install WireGuard."
   read  -p  "Press any key..."
   wget -O up-wreguard.sh https://raw.githubusercontent.com/angristan/wireguard-install/master/wireguard-install.sh
   chmod +x up-wreguard.sh
   bash <(curl -Ls https://raw.githubusercontent.com/angristan/wireguard-install/master/wireguard-install.sh)
   sysctl --system
   systemctl restart wg-quick@wg0
   systemctl status wg-quick@wg0
else
    yn1='N'
    echo "Ok. Go to next point..."
fi
echo ""
echo ""
echo ""
echo -e "# Install OpenVPN, port \033[31m33902\033[0m."
read -p "Do you want to proceed? (Y/N. Default [N].)" yn1
if [[ "$yn1" =~ ^[yY]+$ ]]; then
   echo "# Ok. Install OpenVPN."
   read  -p  "Press any key..."
   wget -O up-openvpn.sh https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh
   chmod +x up-openvpn.sh
   bash <(curl -Ls https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh)
else
    yn1='N'
    echo "Ok. Go to next point..."
fi
echo ""
echo ""
read  -p  "Press any key for reboot..."
echo ""
echo ""
echo ""
echo "REBOOT"
echo ""
echo ""
echo ""
reboot now
