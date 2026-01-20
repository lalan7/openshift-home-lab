#!/bin/bash
# Verify Netlink Buffer Fix
#
# This script verifies that netlink buffers have been properly increased
# after the MachineConfig update

set -euo pipefail

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Verify OVS Netlink Buffer Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Expected values
EXPECTED_RMEM=4194304
EXPECTED_WMEM=4194304
EXPECTED_BUDGET=600
EXPECTED_BACKLOG=5000

ALL_PASS=true

for NODE in hosted-worker7.hypershift.lab hosted-worker8.hypershift.lab hosted-worker9.hypershift.lab; do
    echo "━━━ $NODE ━━━"
    
    # Get values
    RMEM=$(oc debug node/$NODE --to-namespace=default -- chroot /host sysctl -n net.core.rmem_max 2>&1 | grep -v "Starting\|To use\|Removing" | tail -1)
    WMEM=$(oc debug node/$NODE --to-namespace=default -- chroot /host sysctl -n net.core.wmem_max 2>&1 | grep -v "Starting\|To use\|Removing" | tail -1)
    BUDGET=$(oc debug node/$NODE --to-namespace=default -- chroot /host sysctl -n net.core.netdev_budget 2>&1 | grep -v "Starting\|To use\|Removing" | tail -1)
    BACKLOG=$(oc debug node/$NODE --to-namespace=default -- chroot /host sysctl -n net.core.netdev_max_backlog 2>&1 | grep -v "Starting\|To use\|Removing" | tail -1)
    
    # Check rmem
    if [[ "$RMEM" == "$EXPECTED_RMEM" ]]; then
        echo "  ✅ net.core.rmem_max: $RMEM (4MB)"
    else
        echo "  ❌ net.core.rmem_max: $RMEM (expected: $EXPECTED_RMEM)"
        ALL_PASS=false
    fi
    
    # Check wmem
    if [[ "$WMEM" == "$EXPECTED_WMEM" ]]; then
        echo "  ✅ net.core.wmem_max: $WMEM (4MB)"
    else
        echo "  ❌ net.core.wmem_max: $WMEM (expected: $EXPECTED_WMEM)"
        ALL_PASS=false
    fi
    
    # Check budget
    if [[ "$BUDGET" == "$EXPECTED_BUDGET" ]]; then
        echo "  ✅ net.core.netdev_budget: $BUDGET"
    else
        echo "  ⚠️  net.core.netdev_budget: $BUDGET (expected: $EXPECTED_BUDGET)"
    fi
    
    # Check backlog
    if [[ "$BACKLOG" == "$EXPECTED_BACKLOG" ]]; then
        echo "  ✅ net.core.netdev_max_backlog: $BACKLOG"
    else
        echo "  ⚠️  net.core.netdev_max_backlog: $BACKLOG (expected: $EXPECTED_BACKLOG)"
    fi
    
    echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [[ "$ALL_PASS" == "true" ]]; then
    echo "✅ All netlink buffers configured correctly!"
    echo ""
    echo "Next: Monitor for packet drops"
    echo "  watch -n 5 'for n in hosted-worker{7..9}; do echo \$n; oc debug node/\$n.hypershift.lab -- chroot /host ip -s link show genev_sys_6081 2>&1 | grep -E \"TX:|\dropped\"; done'"
else
    echo "❌ Some configurations are incorrect!"
    echo ""
    echo "Check MachineConfig:"
    echo "  oc get mc 99-worker-netlink-buffers"
    echo ""
    echo "Check MCP status:"
    echo "  oc get mcp worker"
    echo ""
    echo "If MCP is not updated, wait and try again."
fi

echo ""

