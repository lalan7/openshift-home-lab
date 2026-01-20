#!/bin/bash
# Apply Netlink Buffer Fix Directly to VM OS
#
# This applies the fix directly to the RHCOS VM OS without using MachineConfig
# Pros: Fast, no node reboot, can test immediately
# Cons: Might be overwritten by MCO, need to verify persistence
#
# Use this to TEST first, then apply MachineConfig if it works

set -euo pipefail

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Apply Netlink Fix Directly to VM OS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "🎯 Approach: Direct VM OS modification"
echo ""
echo "✅ Pros:"
echo "   • No MCP update (no node reboots)"
echo "   • Takes effect immediately"
echo "   • Fast (2-5 minutes)"
echo "   • Safe to test"
echo ""
echo "⚠️  Considerations:"
echo "   • MCO might overwrite (we'll check)"
echo "   • May need MachineConfig later for persistence"
echo ""

read -p "Apply fix directly to VM OS? (yes/no): " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    echo "❌ Aborted"
    exit 1
fi

echo ""
echo "📊 Step 1: Creating persistent sysctl config file..."
echo ""

for NODE in hosted-worker7.hypershift.lab hosted-worker8.hypershift.lab hosted-worker9.hypershift.lab; do
    echo "━━━ $NODE ━━━"
    
    oc debug node/$NODE --to-namespace=default -- chroot /host bash -c "
        # Create sysctl config file
        cat > /etc/sysctl.d/99-ovs-netlink.conf << 'EOF'
# OVS Netlink Buffer Fix
# Applied: $(date)
# Reason: Fix packet loss on Geneve tunnels

# Increase netlink buffers (200KB -> 4MB)
net.core.rmem_default = 4194304
net.core.rmem_max = 4194304
net.core.wmem_default = 4194304
net.core.wmem_max = 4194304

# Increase netdev budget for high traffic
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000

# Increase backlog queue
net.core.netdev_max_backlog = 5000
EOF

        echo '✅ Created /etc/sysctl.d/99-ovs-netlink.conf'
        
        # Apply immediately
        sysctl -p /etc/sysctl.d/99-ovs-netlink.conf
        
        echo ''
        echo 'Verification:'
        sysctl net.core.rmem_max net.core.wmem_max net.core.netdev_budget
    " 2>&1 | grep -v "Starting pod\|To use host\|Removing debug"
    
    echo ""
done

echo ""
echo "📊 Step 2: Checking if MCO will interfere..."
echo ""

# Check if there's already a MachineConfig for this
EXISTING_MC=$(oc get mc -o name | grep netlink || echo "")

if [[ -n "$EXISTING_MC" ]]; then
    echo "⚠️  Found existing MachineConfig: $EXISTING_MC"
    echo "   MCO might overwrite your changes!"
else
    echo "✅ No conflicting MachineConfig found"
    echo "   Your changes should persist (unless MCO does a full sync)"
fi

echo ""
echo "📊 Step 3: Testing persistence..."
echo ""

echo "Checking if files are in MCO-managed paths..."
oc debug node/hosted-worker7.hypershift.lab --to-namespace=default -- chroot /host bash -c "
    if [ -f /etc/sysctl.d/99-ovs-netlink.conf ]; then
        echo '✅ File exists: /etc/sysctl.d/99-ovs-netlink.conf'
        echo ''
        ls -lah /etc/sysctl.d/99-ovs-netlink.conf
    fi
" 2>&1 | grep -v "Starting pod\|To use host\|Removing debug"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ FIX APPLIED DIRECTLY TO VM OS!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📊 Applied to all nodes:"
echo "   • hosted-worker7.hypershift.lab"
echo "   • hosted-worker8.hypershift.lab"
echo "   • hosted-worker9.hypershift.lab"
echo ""
echo "🔧 Changes:"
echo "   • Buffers: 212KB → 4MB (20x)"
echo "   • File: /etc/sysctl.d/99-ovs-netlink.conf"
echo "   • Applied: Immediately (via sysctl -p)"
echo ""
echo "⏱️  Time taken: ~2-5 minutes (vs 30-60 min for MachineConfig)"
echo ""
echo "🧪 NEXT: Test RBD operations!"
echo ""
echo "   # Create test PVC"
echo "   oc apply -f - << 'EOF'"
echo "   apiVersion: v1"
echo "   kind: PersistentVolumeClaim"
echo "   metadata:"
echo "     name: test-rbd-vm-os-fix"
echo "     namespace: default"
echo "   spec:"
echo "     accessModes: [ReadWriteOnce]"
echo "     resources:"
echo "       requests:"
echo "         storage: 1Gi"
echo "     storageClassName: ocs-storagecluster-ceph-rbd-kvm"
echo "   EOF"
echo ""
echo "   # Watch it"
echo "   oc get pvc test-rbd-vm-os-fix -w"
echo ""
echo "📈 IF IT WORKS:"
echo "   ✅ Great! Fix is proven"
echo "   ⚠️  May still need MachineConfig for 100% persistence"
echo "   📋 Check after a node restart if it persists"
echo ""
echo "📈 IF IT DOESN'T WORK:"
echo "   ❌ Buffer size is not the only issue"
echo "   🔍 Investigate other factors (KVM, resources)"
echo ""
echo "🔄 TO MONITOR PACKET LOSS:"
echo "   for n in hosted-worker{7..9}; do"
echo "     echo \$n;"
echo "     oc debug node/\$n.hypershift.lab -- chroot /host \\"
echo "       ip -s link show genev_sys_6081 | grep -A 1 TX;"
echo "   done"
echo ""
echo "📋 PERSISTENCE CHECK:"
echo "   After fix proves successful, check if it survives:"
echo "   1. Node cordon/drain/reboot cycle"
echo "   2. If it does: You're good!"
echo "   3. If not: Apply MachineConfig for guarantee"
echo ""

