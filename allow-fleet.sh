#!/bin/bash
# allow-fleet.sh — ensure given IPs/CIDRs are in fail2ban sshd ignoreip (idempotent).
# Usage (on the box, as root): allow-fleet.sh <ip-or-cidr> [...]
# Example: allow-fleet.sh 100.74.74.0/24 45.86.86.195 46.29.239.23
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
[ $# -ge 1 ] || { echo "Usage: $0 <ip-or-cidr> [...]" >&2; exit 1; }

JAIL=/etc/fail2ban/jail.local
[ -f "$JAIL" ] || { echo "ERROR: $JAIL not found (fail2ban not configured?)." >&2; exit 1; }
grep -q "^ignoreip = " "$JAIL" || { echo "ERROR: no 'ignoreip = ' line in $JAIL." >&2; exit 1; }

CHANGED=0
for net in "$@"; do
    if grep -qF "$net" "$JAIL"; then
        echo "already ignored: $net"
    else
        echo "adding to ignoreip: $net"
        sed -i "0,/^ignoreip = /s|^ignoreip = |&$net |" "$JAIL"
        grep -qF "$net" "$JAIL" || { echo "ERROR: failed to add $net" >&2; exit 1; }
        CHANGED=1
    fi
done

if [ "$CHANGED" -eq 1 ]; then
    fail2ban-client -t >/dev/null || { echo "ERROR: fail2ban config test failed, NOT reloading." >&2; exit 1; }
    fail2ban-client reload >/dev/null
    echo "reloaded."
else
    echo "nothing to do."
fi
grep "^ignoreip = " "$JAIL"
