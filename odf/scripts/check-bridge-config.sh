#!/bin/bash
# Check Bridge/Network Configuration for OVN-Kubernetes
# Usage: ./odf/scripts/check-bridge-config.sh <node-name>

NODE="${1:-management-worker-1.hypershift.lab}"

echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║        Bridge/Network Configuration Check                              ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Node: $NODE"
echo ""

oc debug node/$NODE --to-namespace=default -- chroot /host /bin/bash -c '

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1. Promiscuous Mode Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check physical interface
PHY_IFACE=$(ip route | grep default | awk "{print \$5}" | head -1)
echo "Physical interface: $PHY_IFACE"
echo ""

# Check for PROMISC flag
echo "Interface flags:"
ip link show | grep -E "^[0-9]+:|PROMISC" | head -20
echo ""

if ip link show | grep -q PROMISC; then
    echo "✅ Promiscuous mode is ENABLED on some interfaces"
else
    echo "⚠️  Promiscuous mode NOT found"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "2. UDP Port 6081 (Geneve) Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if Geneve interface exists
if ip link show genev_sys_6081 &>/dev/null; then
    echo "✅ Geneve interface exists: genev_sys_6081"
    ip -d link show genev_sys_6081
else
    echo "❌ Geneve interface NOT found"
fi

echo ""

# Check if UDP 6081 is being listened on
echo "UDP 6081 listening:"
ss -ulnp | grep 6081 || echo "⚠️  No process listening on UDP 6081 (this is normal for Geneve)"

echo ""

# Check firewall rules for UDP 6081
echo "Firewall rules for UDP 6081:"
if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --list-ports 2>/dev/null | grep 6081 && echo "✅ UDP 6081 allowed in firewalld" || echo "⚠️  UDP 6081 not explicitly allowed"
else
    echo "Firewalld not running (normal for CoreOS with OVN)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "3. MAC Address Changes Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if MAC changes are allowed (kernel parameter)
echo "rp_filter settings (affects MAC routing):"
sysctl -a 2>/dev/null | grep "rp_filter" | head -5

echo ""

# OVS MAC learning
echo "OVS MAC learning status:"
ovs-vsctl list bridge | grep -E "name|flood|mac" | head -10

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "4. VLAN Filtering Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if VLAN filtering is enabled on bridges
echo "VLAN configuration:"
if command -v bridge &>/dev/null; then
    bridge vlan show 2>/dev/null | head -20 || echo "No VLAN filtering found (normal for OVN)"
else
    echo "bridge command not available"
fi

echo ""

# Check OVS VLAN configuration
echo "OVS Port VLAN tags:"
ovs-vsctl list port | grep -E "name|tag|vlan" | head -20

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "5. OVN Tunnel Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "Configured Geneve tunnels:"
ovs-vsctl show | grep -A 3 "type: geneve" | head -30

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "6. Network Namespace Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "Testing connectivity from host network namespace:"
ping -c 2 -W 2 10.134.4.4 2>&1 | grep -E "packets|time=" || echo "❌ Cannot reach 10.134.4.4"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "7. MTU Settings"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "MTU settings for key interfaces:"
ip link show | grep -E "mtu|^[0-9]+: (ens|eth|br-|ovn-k8s|genev)" | head -20

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "✅ Checks complete"
echo ""
echo "Next: Check why CSI plugin containers cannot reach monitors"
echo "      even though host network can reach them"
echo ""
'


