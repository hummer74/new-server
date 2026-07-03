#!/bin/bash

# Script must be run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root." >&2
    exit 1
fi

# Array of lines to add (use consistent delimiter style)
lines=(
    "@reboot            date >> /root/reboot.log"
    "0 0 1 * *          date > /root/reboot.log"
    "1 */2 * * *        /root/telemt-update.sh"
    "5 */3 * * *        /root/auto-update.sh"
    "*/5 * * * *        systemctl reset-failed"
)

# Create a temporary file and ensure it is deleted
temp_crontab=$(mktemp)
trap 'rm -f "$temp_crontab"' EXIT

# Save current crontab
crontab -l 2>/dev/null > "$temp_crontab"

added=0
for line in "${lines[@]}"; do
    if grep -Fx "$line" "$temp_crontab" >/dev/null; then
        echo "Line already exists: $line"
    else
        echo "$line" >> "$temp_crontab"
        echo "Added line: $line"
        ((added++))
    fi
done

if [ $added -gt 0 ]; then
    crontab "$temp_crontab"
    echo "Done. Added $added line(s)."
else
    echo "Nothing added. All lines are already present."
fi