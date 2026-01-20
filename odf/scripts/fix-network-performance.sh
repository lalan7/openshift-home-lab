#!/bin/bash
# Fix network performance for RBD mounting between Server 1 and Server 2
# This addresses the mkfs.ext4 hanging issue when mounting RBD on Server 1 nodes

set -e

echo "=== Network Performance Optimization for ODF RBD ==="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root or with sudo"
    exit 1
fi

HOSTNAME=$(hostname -s)
echo "Optimizing network on: $HOSTNAME"
echo ""

# 1. Increase network buffer sizes (currently only 212KB - way too small!)
echo "1. Increasing network buffer sizes..."
sysctl -w net.core.rmem_max=16777216      # 16MB
sysctl -w net.core.wmem_max=16777216      # 16MB
sysctl -w net.core.rmem_default=262144    # 256KB
sysctl -w net.core.wmem_default=262144    # 256KB

# TCP buffer tuning
sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216"
sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216"
sysctl -w net.ipv4.tcp_mem="16777216 16777216 16777216"

# 2. Lower MTU on bridge to account for VXLAN overhead (if needed)
# VXLAN adds 50 bytes overhead, so 1500 - 50 = 1450
BRIDGE="br-hypershift"
if ip link show "$BRIDGE" &>/dev/null; then
    CURRENT_MTU=$(ip link show "$BRIDGE" | grep -oP 'mtu \K\d+')
    echo "2. Current MTU on $BRIDGE: $CURRENT_MTU"
    if [ "$CURRENT_MTU" -eq 1500 ]; then
        echo "   Lowering MTU to 1450 to prevent VXLAN fragmentation..."
        ip link set "$BRIDGE" mtu 1450
        
        # Update all VM interfaces on this bridge
        for iface in $(ip link show master "$BRIDGE" | grep -oP '^\d+: \K[^:]+'); do
            echo "   - Setting MTU 1450 on $iface"
            ip link set "$iface" mtu 1450 2>/dev/null || true
        done
    else
        echo "   MTU already optimized: $CURRENT_MTU"
    fi
else
    echo "2. Bridge $BRIDGE not found, skipping MTU adjustment"
fi

# 3. Optimize TCP settings for storage traffic
echo "3. Optimizing TCP settings for storage workloads..."
sysctl -w net.ipv4.tcp_window_scaling=1
sysctl -w net.ipv4.tcp_timestamps=1
sysctl -w net.ipv4.tcp_sack=1
sysctl -w net.core.netdev_max_backlog=5000

# 4. Make changes persistent
echo "4. Making changes persistent..."
cat > /etc/sysctl.d/99-odf-network-tuning.conf <<EOF
# ODF Network Performance Tuning
# Created: $(date)

# Network buffer sizes
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144

# TCP buffer tuning
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mem = 16777216 16777216 16777216

# TCP optimizations
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.core.netdev_max_backlog = 5000
EOF

echo ""
echo "=== Optimization Complete ==="
echo ""
echo "Current settings:"
sysctl net.core.rmem_max net.core.wmem_max
ip link show "$BRIDGE" 2>/dev/null | grep mtu || echo "Bridge not found"
echo ""
echo "Changes have been made persistent in /etc/sysctl.d/99-odf-network-tuning.conf"
echo ""
echo "NOTE: MTU changes require VM restart to take full effect"

