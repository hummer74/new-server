#!/bin/bash
echo ""
echo ""
echo ""
echo "Install VLESS, Xray-Reality."
read -p "Do you want to proceed? (y/n) " yn1
if [[ "$yn1" == "y" ]] || [["$yn1" == "Y"]]; then
   echo "# Ok. Install VLESS, Xray-Reality."
   read  -p  "Press Enter for process..."
   curl -O https://github.com/XTLS/Xray-install/raw/main/install-release.sh
   chmod +x install-release.sh
   ./install-release.sh &&
fi
    echo "Ok. Go to next point..."
    break
fi
echo ""
echo ""
echo ""
echo "# Install 3X-UI. opossum, standard, port 33900."
read -p "Do you want to proceed? (y/n) " yn2
if [[ "$yn2" = [y] && "$yn2" -gt 0 ]]; then
   echo "# Ok. Install 3X-UI."
   read  -p  "Press Enter for process..."
   bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

else
    echo "Ok. Go to next point..."
    break
fi
echo ""
echo ""
echo ""
echo "# Install WireGuard, port 33901."
read -p "Do you want to proceed? (y/n) " yn3
if [[ "$yn3" = [y] && "$yn3" -gt 0 ]]; then
   echo "# Ok. Install 3X-UI."
   read  -p  "Press Enter for process..."
   curl -O https://raw.githubusercontent.com/angristan/wireguard-install/master/wireguard-install.sh
   chmod +x wireguard-install.sh
   ./wireguard-install.sh &&
   sysctl --system
   systemctl restart wg-quick@wg0
   systemctl status wg-quick@wg0
else
    echo "Ok. Go to next point..."
    break
fi
echo ""
echo ""
echo ""
echo "# Install OpenVPN, port 33902."
read -p "Do you want to proceed? (y/n) " yn4
if [[ "$yn4" = [y] && "$yn4" -gt 0 ]]; then
   echo "# Ok. Install 3X-UI."
   read  -p  "Press Enter for process..."
   curl -O https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh
   chmod +x openvpn-install.sh
   ./openvpn-install.sh &&
else
    echo "Ok. Go to next point..."
    break
fi
echo ""
echo ""
echo ""
echo -e "\033[31mLast update and reboot...\033[0m"
read  -p  "Press Enter for last update and reboot..."
apt update -y && apt full-upgrade -y && apt autoremove -y && apt autoclean && #reboot now
echo ""
echo ""
echo ""
