#!/bin/bash

clear
echo ""
chown opossum:opossum opossum.7z
7za x opossum.7z -aoa
rm opossum.7z
echo "Fix directory permissions"
chmod 700 ~/.ssh
echo ""
echo "Fix all key permissions"
chmod 600 ~/.ssh/*
chmod 644 ~/.ssh/*.pub
echo ""
echo "Fix special files permissions"
chmod 644 ~/.ssh/authorized_keys
chmod 644 ~/.ssh/known_hosts
#chown -R opossum /home/opossum
#chown -R opossum /home/opossum/*
echo ""
