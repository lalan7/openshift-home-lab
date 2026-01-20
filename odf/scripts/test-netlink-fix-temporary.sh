#!/bin/bash
# Test Netlink Buffer Fix TEMPORARILY (No MCP Update)
#
# This applies the netlink buffer increase WITHOUT a MachineConfig
# so you can test if it solves the problem before committing to a
# MCP update that will reboot nodes.
#
# Settings will NOT persist across node reboots!

set -euo pipefail

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Temporary Netlink Buffer Fix (TEST MODE)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "⚠️  WARNING: This is a TEMPORARY test!"
echo ""
echo "📋 What this does:"
echo "   • Increases netlink buffers to 4MB"
echo "   • Takes effect IMMEDIATELY (no reboot)"
echo "   • Does NOT persist (lost on reboot)"
echo "   • Safe to test without MCP update"
echo ""
echo "🎯 Purpose:"
echo "   Test if larger buffers fix RBD issues"
echo "   before committing to MachineConfig"
echo ""

read -p "Continue with temporary test? (yes/no): " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    echo "❌ Aborted"
    exit 1
fi

echo ""
echo "📊 Step 1: Checking current settings..."
echo ""

for NODE in hosted-worker7.hypershift.lab hosted-worker8.hypershift.lab hosted-worker9.hypershift.lab; do
    echo "━━━ $NODE ━━━"
    oc debug node/$NODE --to-namespace=default -- chroot /host bash -c "
        echo 'Before:'
        sysctl net.core.rmem_max net.core.wmem_max net.core.netdev_budget
    " 2>&1 | grep -v "Starting\|To use\|Removing"
    echo ""
done

echo ""
echo "📊 Step 2: Applying temporary buffer increase..."
echo ""

for NODE in hosted-worker7.hypershift.lab hosted-worker8.hypershift.lab hosted-worker9.hypershift.lab; do
    echo "  → Fixing $NODE..."
    
    oc debug node/$NODE --to-namespace=default -- chroot /host bash -c "
        # Apply new values (TEMPORARY - not persistent!)
        sysctl -w net.core.rmem_default=4194304
        sysctl -w net.core.rmem_max=4194304
        sysctl -w net.core.wmem_default=4194304
        sysctl -w net.core.wmem_max=4194304
        sysctl -w net.core.netdev_budget=600
        sysctl -w net.core.netdev_budget_usecs=8000
        sysctl -w net.core.netdev_max_backlog=5000
    " 2>&1 | grep -v "Starting\|To use\|Removing" > /dev/null
    
    echo "    ✅ Applied"
done

echo ""
echo "📊 Step 3: Verifying new settings..."
echo ""

ALL_GOOD=true
for NODE in hosted-worker7.hypershift.lab hosted-worker8.hypershift.lab hosted-worker9.hypershift.lab; do
    echo "━━━ $NODE ━━━"
    RMEM=$(oc debug node/$NODE --to-namespace=default -- chroot /host sysctl -n net.core.rmem_max 2>&1 | grep -v "Starting\|To use\|Removing" | tail -1)
    WMEM=$(oc debug node/$NODE --to-namespace=default -- chroot /host sysctl -n net.core.wmem_max 2>&1 | grep -v "Starting\|To use\|Removing" | tail -1)
    BUDGET=$(oc debug node/$NODE --to-namespace=default -- chroot /host sysctl -n net.core.netdev_budget 2>&1 | grep -v "Starting\|To use\|Removing" | tail -1)
    
    if [[ "$RMEM" == "4194304" ]] && [[ "$WMEM" == "4194304" ]] && [[ "$BUDGET" == "600" ]]; then
        echo "  ✅ rmem_max: $RMEM (4MB)"
        echo "  ✅ wmem_max: $WMEM (4MB)"
        echo "  ✅ netdev_budget: $BUDGET"
    else
        echo "  ❌ Something went wrong!"
        echo "     rmem_max: $RMEM (expected: 4194304)"
        echo "     wmem_max: $WMEM (expected: 4194304)"
        echo "     netdev_budget: $BUDGET (expected: 600)"
        ALL_GOOD=false
    fi
    echo ""
done

if [[ "$ALL_GOOD" != "true" ]]; then
    echo "❌ Fix was not applied correctly!"
    exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ TEMPORARY FIX APPLIED!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📊 Buffers increased:"
echo "   • 212 KB → 4 MB (20x increase)"
echo ""
echo "⚠️  IMPORTANT:"
echo "   • This is TEMPORARY (lost on node reboot)"
echo "   • Test RBD operations now"
echo "   • If it works, apply permanent MachineConfig"
echo ""
echo "🧪 TEST RBD NOW:"
echo ""
echo "   # Create test PVC"
echo "   cat > /tmp/test-rbd-temp.yaml << 'EOF'"
echo "   apiVersion: v1"
echo "   kind: PersistentVolumeClaim"
echo "   metadata:"
echo "     name: test-rbd-after-temp-fix"
echo "     namespace: default"
echo "   spec:"
echo "     accessModes:"
echo "     - ReadWriteOnce"
echo "     resources:"
echo "       requests:"
echo "         storage: 1Gi"
echo "     storageClassName: ocs-storagecluster-ceph-rbd-kvm"
echo "   EOF"
echo ""
echo "   oc apply -f /tmp/test-rbd-temp.yaml"
echo "   oc get pvc test-rbd-after-temp-fix -w"
echo ""
echo "📈 RESULTS:"
echo ""
echo "   ✅ If PVC binds successfully:"
echo "      → Buffer fix works!"
echo "      → Apply permanent: odf/scripts/fix-ovs-netlink-buffers.sh"
echo ""
echo "   ❌ If PVC still hangs:"
echo "      → Buffer size is not the issue"
echo "      → Investigate other root causes"
echo ""
echo "🔄 TO REVERT:"
echo "   Just reboot the nodes (settings will be lost)"
echo "   Or run:"
echo "     for n in hosted-worker{7..9}; do"
echo "       oc debug node/\$n.hypershift.lab -- chroot /host \\"
echo "         sysctl -w net.core.rmem_max=212992"
echo "     done"
echo ""

