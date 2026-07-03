#!/bin/bash

# Check root privileges
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root." >&2
    exit 1
fi

echo "Starting system update and cleanup..."

# 1. Clean and update package cache
apt clean -y
rm -rf /var/lib/apt/lists/*
apt update -y

# 2. Check for available updates
#    The command apt list --upgradable lists upgradable packages.
#    The first line is "Listing..." so we skip it with tail.
upgradable_count=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)

if [ "$upgradable_count" -eq 0 ]; then
    echo "No updates available. Performing cleanup only, no reboot."
    # Final cleanup (unneeded packages, cache)
    apt autoremove -y
    apt autoclean -y
    apt autoremove --purge -y
    exit 0
fi

echo "Found $upgradable_count package(s) to upgrade. Proceeding with full upgrade..."

# 3. Perform full system upgrade
apt full-upgrade -y
upgrade_status=$?

# 4. Final cleanup after upgrade
apt autoremove -y
apt autoclean -y
apt autoremove --purge -y

# 5. Check upgrade result
if [ $upgrade_status -eq 0 ]; then
    echo "Update completed successfully. Rebooting in 15 seconds (Ctrl+C to cancel)..."
    sleep 15
    reboot now
else
    echo "Update failed. Reboot aborted." > ~/auto-update.log
    exit 2
fi