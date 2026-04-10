#!/bin/sh
SCRIPT=$(curl -fsSL https://raw.githubusercontent.com/hummer74/new-server/main/new-server.sh) || { echo "Download failed"; exit 1; }
bash -c "$SCRIPT"