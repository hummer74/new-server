#!/bin/bash
set -euo pipefail

# === Log all output to /root/snikket-update.log ===
LOG_FILE="/root/snikket-update.log"
exec 3>&1 4>&2
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== Script started at $(date '+%Y-%m-%d %H:%M:%S') ===" >&3

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

if [ ! -d "/etc/snikket" ]; then
    echo "Error: /etc/snikket not found. Is Snikket installed?"
    exit 1
fi

echo "=== Updating Snikket Containers ==="
cd /etc/snikket

echo "# Pulling latest images..."
docker compose pull || { echo "ERROR: docker compose pull failed"; exit 1; }

echo "# Restarting services..."
docker compose up -d || { echo "ERROR: docker compose up failed"; exit 1; }

echo "# Verifying status..."
sleep 5
if docker compose ps | grep -q "Up"; then
    echo "Snikket updated successfully."
else
    echo "ERROR: Snikket containers are not running after update. Check logs."
    docker compose logs --tail=50
    exit 1
fi

echo "=== Update Finished ==="
