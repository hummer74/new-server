#!/bin/bash
# set-password.sh — interactive password change for a local user.
# Security: password is read twice from the terminal (no echo), never
# passed via argv/env, never written to logs or files. Nothing secret
# is stored in the repo by this script.
set -euo pipefail

TARGET_USER="${1:-opossum}"

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: run as root." >&2
    exit 1
fi
if [ ! -t 0 ]; then
    echo "ERROR: stdin is not a terminal (piped passwords refused)." >&2
    exit 1
fi
if ! id "$TARGET_USER" >/dev/null 2>&1; then
    echo "ERROR: user '$TARGET_USER' not found." >&2
    exit 1
fi

read_secret() { # $1 = prompt, echoes value on stdout
    local prompt="$1" val1 val2
    while true; do
        printf "%s: " "$prompt" >&2
        stty -echo
        IFS= read -r val1
        stty echo
        printf "\n%s (repeat): " "$prompt" >&2
        stty -echo
        IFS= read -r val2
        stty echo
        printf "\n" >&2
        if [ -z "$val1" ]; then
            echo "Empty password, try again." >&2
            continue
        fi
        if [ ${#val1} -lt 12 ]; then
            echo "Too short (min 12 chars), try again." >&2
            continue
        fi
        if [ "$val1" != "$val2" ]; then
            echo "Mismatch, try again." >&2
            continue
        fi
        printf "%s" "$val1"
        val1=""; val2=""
        return 0
    done
}

echo "Setting password for user '$TARGET_USER'."
PW="$(read_secret "New password")"
printf "%s:%s" "$TARGET_USER" "$PW" | chpasswd
PW=""
echo "Password updated."
passwd -S "$TARGET_USER" || true
if passwd -S "$TARGET_USER" 2>/dev/null | grep -q " L "; then
    echo "NOTE: account is locked — unlock with: passwd -u $TARGET_USER"
fi
