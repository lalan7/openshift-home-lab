#!/bin/bash
# Revert network changes back to original settings

set -e

echo "=== Reverting Network Changes ==="
echo ""

if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root or with sudo"
    exit 1
fi

HOSTNAME=$(hostname -s)
echo "Reverting changes on: $HOSTNAME"
echo ""

# 1. Restore MTU to 1500 on bridge
BRIDGE="br-hypershift"
if ip link show "$BRIDGE" &>/dev/null; then
    echo "1. Restoring MTU to 1500 on $BRIDGE..."
    ip link set "$BRIDGE" mtu 1500
    
    # Update all VM interfaces on this bridge
    for iface in $(ip link show master "$BRIDGE" 2>/dev/null | grep -oP '^\d+: \K[^:]+' || true); do
        echo "   - Setting MTU 1500 on $iface"
        ip link set "$iface" mtu 1500 2>/dev/null || true
    done
else
    echo "1. Bridge $BRIDGE not found, skipping MTU revert"
fi

# 2. Remove the persistent configuration file
echo "2. Removing persistent configuration..."
if [ -f /etc/sysctl.d/99-odf-network-tuning.conf ]; then
    rm -f /etc/sysctl.d/99-odf-network-tuning.conf
    echo "   Removed /etc/sysctl.d/99-odf-network-tuning.conf"
else
    echo "   Configuration file not found"
fi

# 3. Restore original sysctl values (default RHEL values)
echo "3. Restoring original sysctl values..."
sysctl -w net.core.rmem_max=212992
sysctl -w net.core.wmem_max=212992
sysctl -w net.core.rmem_default=212992
sysctl -w net.core.wmem_default=212992
sysctl -w net.ipv4.tcp_rmem="4096 87380 6291456"
sysctl -w net.ipv4.tcp_wmem="4096 16384 4194304"
sysctl -w net.ipv4.tcp_mem="1541289 2055052 3082578"

echo ""
echo "=== Revert Complete ==="
echo ""
echo "Current settings:"
sysctl net.core.rmem_max net.core.wmem_max
ip link show "$BRIDGE" 2>/dev/null | grep mtu || echo "Bridge not found"
echo ""
echo "NOTE: VM restart required for MTU changes to take full effect"

