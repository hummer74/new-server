#!/bin/bash

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

#reboot now
