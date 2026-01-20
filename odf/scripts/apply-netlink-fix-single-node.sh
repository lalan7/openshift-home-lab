#!/bin/bash
# Apply Netlink Fix to Single Node (Test First!)
#
# This applies the fix to ONE node for testing
# Recommended: Start with hosted-worker9 (has most packet loss)
# Then expand to other nodes if successful

set -euo pipefail

# Default to worker9 (has most packet loss: 2768 errors, 683 drops)
NODE="${1:-hosted-worker9.hypershift.lab}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Apply Netlink Fix to Single Node"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "🎯 Target Node: $NODE"
echo ""
echo "💡 Why single node first?"
echo "   • Test on one node before all"
echo "   • worker9 has highest packet loss (2768 errors)"
echo "   • Safer approach"
echo "   • Can expand to others if successful"
echo ""

# Check if we have direct SSH access
SSH_ACCESS=false
if ssh -q -o BatchMode=yes -o ConnectTimeout=2 core@$NODE exit 2>/dev/null; then
    SSH_ACCESS=true
    echo "✅ Direct SSH access available"
    echo "   Will use: ssh core@$NODE"
else
    echo "⚠️  No direct SSH access"
    echo "   Will use: oc debug"
fi
echo ""

read -p "Apply fix to $NODE? (yes/no): " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    echo "❌ Aborted"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 1: Check BEFORE state"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [[ "$SSH_ACCESS" == "true" ]]; then
    echo "Current buffer settings:"
    ssh core@$NODE "sudo sysctl net.core.rmem_max net.core.wmem_max net.core.netdev_budget"
    
    echo ""
    echo "Current packet loss:"
    ssh core@$NODE "sudo ip -s link show genev_sys_6081" | grep -A 1 "TX:"
else
    echo "Current buffer settings:"
    oc debug node/$NODE --to-namespace=default -- chroot /host bash -c "
        sysctl net.core.rmem_max net.core.wmem_max net.core.netdev_budget
    " 2>&1 | grep -v "Starting\|To use\|Removing"
    
    echo ""
    echo "Current packet loss:"
    oc debug node/$NODE --to-namespace=default -- chroot /host bash -c "
        ip -s link show genev_sys_6081
    " 2>&1 | grep -v "Starting\|To use\|Removing" | grep -A 1 "TX:"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 2: Apply fix"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

SYSCTL_CONFIG='# OVS Netlink Buffer Fix
# Applied: '$(date)'
# Node: '$NODE'
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
'

if [[ "$SSH_ACCESS" == "true" ]]; then
    echo "Applying via SSH..."
    
    # Create config file
    echo "$SYSCTL_CONFIG" | ssh core@$NODE "sudo tee /etc/sysctl.d/99-ovs-netlink.conf > /dev/null"
    
    # Apply immediately
    ssh core@$NODE "sudo sysctl -p /etc/sysctl.d/99-ovs-netlink.conf"
else
    echo "Applying via oc debug..."
    
    oc debug node/$NODE --to-namespace=default -- chroot /host bash -c "
        # Create config file
        cat > /etc/sysctl.d/99-ovs-netlink.conf << 'EOFCONFIG'
$SYSCTL_CONFIG
EOFCONFIG
        
        # Apply immediately
        sysctl -p /etc/sysctl.d/99-ovs-netlink.conf
    " 2>&1 | grep -v "Starting pod\|To use host\|Removing debug"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 3: Verify AFTER state"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [[ "$SSH_ACCESS" == "true" ]]; then
    echo "New buffer settings:"
    ssh core@$NODE "sudo sysctl net.core.rmem_max net.core.wmem_max net.core.netdev_budget"
    
    echo ""
    echo "Verification:"
    RMEM=$(ssh core@$NODE "sudo sysctl -n net.core.rmem_max")
    WMEM=$(ssh core@$NODE "sudo sysctl -n net.core.wmem_max")
    BUDGET=$(ssh core@$NODE "sudo sysctl -n net.core.netdev_budget")
else
    echo "New buffer settings:"
    RMEM=$(oc debug node/$NODE --to-namespace=default -- chroot /host sysctl -n net.core.rmem_max 2>&1 | grep -v "Starting\|To use\|Removing" | tail -1)
    WMEM=$(oc debug node/$NODE --to-namespace=default -- chroot /host sysctl -n net.core.wmem_max 2>&1 | grep -v "Starting\|To use\|Removing" | tail -1)
    BUDGET=$(oc debug node/$NODE --to-namespace=default -- chroot /host sysctl -n net.core.netdev_budget 2>&1 | grep -v "Starting\|To use\|Removing" | tail -1)
    
    echo "  rmem_max: $RMEM"
    echo "  wmem_max: $WMEM"
    echo "  netdev_budget: $BUDGET"
fi

echo ""
if [[ "$RMEM" == "4194304" ]] && [[ "$WMEM" == "4194304" ]] && [[ "$BUDGET" == "600" ]]; then
    echo "✅ Fix applied successfully!"
else
    echo "❌ Fix may not have applied correctly!"
    echo "   Expected: rmem_max=4194304, wmem_max=4194304, netdev_budget=600"
    echo "   Got: rmem_max=$RMEM, wmem_max=$WMEM, netdev_budget=$BUDGET"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ FIX APPLIED TO $NODE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📊 Changes:"
echo "   • Buffers: 212KB → 4MB (20x increase)"
echo "   • File: /etc/sysctl.d/99-ovs-netlink.conf"
echo "   • Applied: Immediately (via sysctl -p)"
echo ""
echo "🧪 NEXT STEPS:"
echo ""
echo "1️⃣  Monitor packet loss on $NODE:"
echo ""
if [[ "$SSH_ACCESS" == "true" ]]; then
    echo "   watch -n 5 'ssh core@$NODE sudo ip -s link show genev_sys_6081 | grep -A 1 TX'"
else
    echo "   watch -n 5 'oc debug node/$NODE -- chroot /host ip -s link show genev_sys_6081 | grep -A 1 TX'"
fi
echo ""
echo "   Look for: TX errors/dropped should STOP increasing!"
echo ""
echo "2️⃣  Test RBD mount (pod will likely schedule to $NODE):"
echo ""
echo "   oc apply -f - << 'EOF'"
echo "   apiVersion: v1"
echo "   kind: PersistentVolumeClaim"
echo "   metadata:"
echo "     name: test-rbd-worker9-fix"
echo "     namespace: default"
echo "   spec:"
echo "     accessModes: [ReadWriteOnce]"
echo "     resources:"
echo "       requests:"
echo "         storage: 1Gi"
echo "     storageClassName: ocs-storagecluster-ceph-rbd-kvm"
echo "   EOF"
echo ""
echo "   oc get pvc test-rbd-worker9-fix -w"
echo ""
echo "3️⃣  If successful, apply to other nodes:"
echo ""
echo "   # Apply to worker7"
echo "   $0 hosted-worker7.hypershift.lab"
echo ""
echo "   # Apply to worker8"
echo "   $0 hosted-worker8.hypershift.lab"
echo ""
echo "   # Or apply to all at once"
echo "   ./odf/scripts/apply-netlink-fix-to-vm.sh"
echo ""
echo "📈 Expected Results:"
echo "   • Packet loss should drop to near-zero"
echo "   • RBD mounts should succeed (though slow due to KVM)"
echo "   • Ceph monitors should have stable communication"
echo ""
echo "⏱️  Give it 5-10 minutes to see improvement!"
echo ""

