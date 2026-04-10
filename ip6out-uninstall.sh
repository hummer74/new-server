#!/bin/bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
fi

BACKUP_DIR="/root/ip6out-backup"

if [ ! -d "$BACKUP_DIR" ]; then
    echo "Error: Backup directory $BACKUP_DIR not found. Nothing to rollback." >&2
    exit 1
fi

if [ ! -f "$BACKUP_DIR/sysctl.conf.bak" ]; then
    echo "Error: Backup file sysctl.conf.bak not found. Cannot rollback safely." >&2
    exit 1
fi

echo "Rolling back IPv6 outgoing configuration..."

# --- Remove policy routing rules and table ---
echo ""
echo "Removing policy routing rules..."
ip -6 rule del lookup ipv6out priority 100 2>/dev/null || true
ip -6 route flush table ipv6out 2>/dev/null || true

# Remove ipv6out entry from rt_tables
sed -i '/^200.*ipv6out/d' /etc/iproute2/rt_tables 2>/dev/null || true
echo "Policy routing removed."

# --- Restore rt_tables if backup exists ---
if [ -f "$BACKUP_DIR/rt_tables.bak" ]; then
    cp "$BACKUP_DIR/rt_tables.bak" /etc/iproute2/rt_tables
    echo "rt_tables restored from backup."
fi

# --- Restore sysctl.conf from backup ---
cp "$BACKUP_DIR/sysctl.conf.bak" /etc/sysctl.conf
echo "sysctl.conf restored from backup."

# --- Restore IPv6 restrictions based on what was saved ---
if [ -f "$BACKUP_DIR/backup-info" ]; then
    # Restore 11-disable-ipv6.conf
    if grep -q "saved_disable_file=yes" "$BACKUP_DIR/backup-info"; then
        if [ -f "$BACKUP_DIR/11-disable-ipv6.conf.bak" ]; then
            cp "$BACKUP_DIR/11-disable-ipv6.conf.bak" /etc/sysctl.d/11-disable-ipv6.conf
            echo "11-disable-ipv6.conf restored."
        fi
    fi

    # Restore blacklist-ipv6.conf
    if grep -q "saved_modprobe=yes" "$BACKUP_DIR/backup-info"; then
        if [ -f "$BACKUP_DIR/blacklist-ipv6.conf.bak" ]; then
            mkdir -p /etc/modprobe.d
            cp "$BACKUP_DIR/blacklist-ipv6.conf.bak" /etc/modprobe.d/blacklist-ipv6.conf
            echo "blacklist-ipv6.conf restored."
        fi
    fi
else
    echo "Warning: backup-info not found, cannot selectively restore IPv6 restrictions."
fi

# Apply sysctl changes
sysctl -p 2>/dev/null || true

# Rebuild initramfs if blacklist was restored
if [ -f "$BACKUP_DIR/backup-info" ] && grep -q "saved_modprobe=yes" "$BACKUP_DIR/backup-info"; then
    update-initramfs -u 2>/dev/null || true
    echo "initramfs updated."
fi

# --- Restore ip6tables ---
if [ -f "$BACKUP_DIR/ip6tables.bak" ]; then
    ip6tables-restore < "$BACKUP_DIR/ip6tables.bak" 2>/dev/null || true
    echo "ip6tables restored from backup."
fi

# --- Remove persistence script ---
rm -f /etc/network/if-up.d/ip6out
echo "Boot persistence script removed."

echo ""
echo "IPv6 outgoing configuration rolled back successfully."
echo "Backup preserved at: $BACKUP_DIR"
echo "Remove manually when verified: rm -rf $BACKUP_DIR"
