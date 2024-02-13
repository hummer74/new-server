#!/bin/bash
# shellcheck disable=SC1091,SC2164,SC2034,SC1072,SC1073,SC1009

echo "Set UTF-8 locales."
echo "export LC_ALL=en_US.UTF-8" >> ~/.bashrc
echo "export LANG=en_US.UTF-8" >> ~/.bashrc
echo "export LANGUAGE=en_US.UTF-8" >> ~/.bashrc
echo "export LC_ALL=en_US.UTF-8" >> ~/.profile
echo "export LANG=en_US.UTF-8" >> ~/.profile
echo "export LANGUAGE=en_US.UTF-8" >> ~/.profile
echo "sudo LANG=ru_RU.UTF-8 mc" >> ~/.profile
echo ""
echo ""
echo ""
read  -p  "Press Enter for last update and reboot..."
apt update -y && apt full-upgrade -y && apt autoremove -y && apt autoclean -y && reboot now
echo ""