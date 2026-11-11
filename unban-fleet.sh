#!/bin/bash
# unban-fleet.sh — unban given IPs from the fail2ban sshd jail.
# Usage (on the box, as root): unban-fleet.sh <ip> [...]
# Example: unban-fleet.sh 100.74.74.5 45.86.86.195
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
[ $# -ge 1 ] || { echo "Usage: $0 <ip> [...]" >&2; exit 1; }

for ip in "$@"; do
    if fail2ban-client set sshd unbanip "$ip" 2>&1 | grep -qiE "^(ok|1)$|unbanned"; then
        echo "unbanned: $ip"
    else
        echo "note: $ip (was it banned?)"
    fi
done
echo "--- current sshd jail:"
fail2ban-client status sshd
