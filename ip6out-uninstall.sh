#!/bin/bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
fi

BACKUP_DIR="/root/ip6out-backup"
mkdir -p "$BACKUP_DIR"

# Detect primary network interface
IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)
if [ -z "$IFACE" ]; then
    echo "Error: Could not detect primary network interface." >&2
    exit 1
fi
echo "Primary interface: $IFACE"

# --- Backup current state ---
echo "Backing up current state to $BACKUP_DIR ..."

cp /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf.bak"

if [ -f /etc/sysctl.d/11-disable-ipv6.conf ]; then
    cp /etc/sysctl.d/11-disable-ipv6.conf "$BACKUP_DIR/11-disable-ipv6.conf.bak"
    echo "saved_disable_file=yes" > "$BACKUP_DIR/backup-info"
else
    echo "saved_disable_file=no" > "$BACKUP_DIR/backup-info"
fi

if [ -f /etc/modprobe.d/blacklist-ipv6.conf ]; then
    cp /etc/modprobe.d/blacklist-ipv6.conf "$BACKUP_DIR/blacklist-ipv6.conf.bak"
    echo "saved_modprobe=yes" >> "$BACKUP_DIR/backup-info"
else
    echo "saved_modprobe=no" >> "$BACKUP_DIR/backup-info"
fi

# Backup routing and firewall state
cp /etc/iproute2/rt_tables "$BACKUP_DIR/rt_tables.bak" 2>/dev/null || true
ip6tables-save > "$BACKUP_DIR/ip6tables.bak" 2>/dev/null || true
ip rule show > "$BACKUP_DIR/ip-rules.bak" 2>/dev/null || true
ip -6 rule show > "$BACKUP_DIR/ip6-rules.bak" 2>/dev/null || true

echo "Backup complete."

# --- Remove IPv6 restrictions ---
echo ""
echo "Removing IPv6 restrictions..."
rm -f /etc/modprobe.d/blacklist-ipv6.conf
rm -f /etc/sysctl.d/11-disable-ipv6.conf
sed -i '/^net\.ipv6\.conf\.all\.disable_ipv6/d' /etc/sysctl.conf
sed -i '/^net\.ipv6\.conf\.default\.disable_ipv6/d' /etc/sysctl.conf
echo "IPv6 restrictions removed."

# --- Add provider's IPv6 settings ---
echo ""
echo "Configuring IPv6 for interface $IFACE..."

# Remove old provider entries to avoid duplicates
sed -i "/^net\.ipv6\.conf\.$IFACE\.disable_ipv6/d" /etc/sysctl.conf
sed -i "/^net\.ipv6\.conf\.$IFACE\.accept_ra/d" /etc/sysctl.conf
sed -i '/^net\.ipv6\.conf\.all\.forwarding/d' /etc/sysctl.conf
sed -i '/^net\.ipv6\.conf\.all\.addr_gen_mode/d' /etc/sysctl.conf
sed -i "/^net\.ipv6\.conf\.$IFACE\.use_tempaddr/d" /etc/sysctl.conf

cat >> /etc/sysctl.conf <<IPV6EOF

# IPv6 outgoing (in-IPv4, out-IPv6) - provider settings
net.ipv6.conf.$IFACE.disable_ipv6 = 0
net.ipv6.conf.$IFACE.accept_ra = 2
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.all.addr_gen_mode = 0
net.ipv6.conf.$IFACE.use_tempaddr = 0
IPV6EOF

sysctl -p
echo "sysctl settings applied."

# --- Policy routing ---
echo ""
echo "Setting up policy routing..."

grep -q "200.*ipv6out" /etc/iproute2/rt_tables || echo "200 ipv6out" >> /etc/iproute2/rt_tables
ip -6 route flush table ipv6out 2>/dev/null || true

IPV6_GW=$(ip -6 route show default | awk '{print $3}' | head -1)
if [ -n "$IPV6_GW" ]; then
    ip -6 route add default via "$IPV6_GW" dev "$IFACE" table ipv6out
    ip -6 rule add from ::/0 lookup ipv6out priority 100 2>/dev/null || true
    echo "Policy routing configured. IPv6 gateway: $IPV6_GW"
else
    echo "Warning: No IPv6 gateway detected."
    echo "After reboot or when IPv6 appears, run: /root/ip6out-install.sh"
fi

# --- Disable IPv6 ping ---
echo ""
echo "Blocking IPv6 ping (echo-request)..."
ip6tables -I INPUT -p icmpv6 --icmpv6-type echo-request -j DROP 2>/dev/null || true
echo "IPv6 ping blocked."

# --- Persistence: restore ip rule at boot ---
cat > /etc/network/if-up.d/ip6out << 'PERSEOF'
#!/bin/sh
ip -6 rule add from ::/0 lookup ipv6out priority 100 2>/dev/null || true
PERSEOF
chmod +x /etc/network/if-up.d/ip6out

echo ""
echo "IPv6 outgoing (in-IPv4, out-IPv6) configured successfully."
echo "Backup saved to: $BACKUP_DIR"
echo "To rollback: /root/ip6out-uninstall.sh"