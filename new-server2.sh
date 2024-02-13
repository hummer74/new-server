#!/bin/bash
# shellcheck disable=SC1091,SC2164,SC2034,SC1072,SC1073,SC1009

echo "# Install all update."
apt update -y && apt full-upgrade -y && apt autoremove -y && apt autoclean -y &&
echo ""
echo ""
echo ""

echo "# Install VLESS, Xray-Reality."
read  -p  "Press Enter for process..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install &&
echo ""
echo ""
echo ""

echo "# Install 3X-UI. opossum, standard, port 33900."
read  -p  "Press Enter for process..."
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) &&
echo ""
echo ""
echo ""

echo "# Install WireGuard, port 33901."
read  -p  "Press Enter for process..."
curl -O https://raw.githubusercontent.com/angristan/wireguard-install/master/wireguard-install.sh
chmod +x wireguard-install.sh
./wireguard-install.sh &&
echo ""
echo ""
echo ""
sysctl --system
systemctl restart wg-quick@wg0
systemctl status wg-quick@wg0
echo ""
echo ""
echo ""

echo "# Install OpenVPN, port 33902."
read  -p  "Press Enter for process..."
curl -O https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh
chmod +x openvpn-install.sh
./openvpn-install.sh &&
echo ""
echo ""
echo ""

read  -p  "Press Enter for last update and reboot..."
apt update -y && apt full-upgrade -y && apt autoremove -y && apt autoclean -y && reboot now
echo ""
echo ""
echo ""