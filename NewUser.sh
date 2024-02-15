#!/bin/bash

clear
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
chown opossum /home/opossum/opossum.*
cd /root
echo ""
