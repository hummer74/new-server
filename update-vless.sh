#!/bin/bash
# shellcheck disable=SC1091,SC2164,SC2034,SC1072,SC1073,SC1009

curl -O https://github.com/XTLS/Xray-install/raw/main/install-release.sh 
mv install-release.sh xtls-update.sh 
chmod +x xtls-update.sh 
curl -O https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh 
mv install.sh 3x-update.sh 
chmod +x 3x-update.sh 


./xtls-update.sh 
./3x-update.sh 

rm xtls-update.sh 
rm 3x-update.sh 

pause

# reboot now
