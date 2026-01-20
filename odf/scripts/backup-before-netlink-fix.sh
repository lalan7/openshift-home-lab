#!/bin/bash
# Backup Current Configuration Before Applying Netlink Fix
#
# This script creates a comprehensive backup of the current state
# before applying the OVS netlink buffer fix

set -euo pipefail

BACKUP_DIR="/tmp/netlink-backup-$(date +%Y%m%d-%H%M%S)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Pre-Flight Backup - OVS Netlink Buffer Fix"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📁 Backup directory: $BACKUP_DIR"
echo ""

mkdir -p "$BACKUP_DIR"

# 1. Backup current buffer settings from all nodes
echo "📊 Step 1/7: Backing up buffer settings from nodes..."
for NODE in hosted-worker7 hosted-worker8 hosted-worker9; do
    echo "  → $NODE.hypershift.lab"
    oc debug node/$NODE.hypershift.lab --to-namespace=default -- chroot /host bash -c "
        echo '=== $NODE Buffer Settings $(date) ==='
        echo ''
        echo 'Netlink Buffers:'
        sysctl net.core.rmem_default net.core.rmem_max
        sysctl net.core.wmem_default net.core.wmem_max
        echo ''
        echo 'Netdev Settings:'
        sysctl net.core.netdev_budget net.core.netdev_budget_usecs net.core.netdev_max_backlog
        echo ''
        echo 'All network sysctls:'
        sysctl -a 2>/dev/null | grep -E 'net.core.(r|w)mem|netdev'
    " 2>&1 | grep -v "Starting\|To use\|Removing" > "$BACKUP_DIR/$NODE-buffers.txt"
done
echo "  ✅ Done"
echo ""

# 2. Backup network interface statistics (baseline for packet loss)
echo "📊 Step 2/7: Backing up network interface statistics..."
for NODE in hosted-worker7 hosted-worker8 hosted-worker9; do
    echo "  → $NODE.hypershift.lab"
    oc debug node/$NODE.hypershift.lab --to-namespace=default -- chroot /host bash -c "
        echo '=== $NODE Network Stats $(date) ==='
        echo ''
        echo 'Geneve tunnel (pod-to-pod):'
        ip -s link show genev_sys_6081
        echo ''
        echo 'All interfaces:'
        ip -s link show
    " 2>&1 | grep -v "Starting\|To use\|Removing" > "$BACKUP_DIR/$NODE-network-stats.txt"
done
echo "  ✅ Done"
echo ""

# 3. Backup MachineConfigs
echo "📊 Step 3/7: Backing up MachineConfigs..."
oc get mc -o yaml > "$BACKUP_DIR/all-machineconfigs.yaml"
echo "  ✅ Done ($(oc get mc --no-headers | wc -l) MachineConfigs)"
echo ""

# 4. Backup MCP state
echo "📊 Step 4/7: Backing up MachineConfigPool state..."
oc get mcp -o yaml > "$BACKUP_DIR/all-mcp.yaml"
oc get mcp worker -o yaml > "$BACKUP_DIR/mcp-worker.yaml"
echo "  ✅ Done"
echo ""

# 5. Backup cluster state
echo "📊 Step 5/7: Backing up cluster state..."
oc get nodes > "$BACKUP_DIR/nodes.txt"
oc get nodes -o yaml > "$BACKUP_DIR/nodes-full.yaml"
oc get pods -A | grep -v Running > "$BACKUP_DIR/non-running-pods.txt" || echo "All pods running" > "$BACKUP_DIR/non-running-pods.txt"
echo "  ✅ Done ($(oc get nodes --no-headers | wc -l) nodes)"
echo ""

# 6. Backup ODF/Ceph status
echo "📊 Step 6/7: Backing up ODF/Ceph status..."
TOOLS_POD=$(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name | head -1)
if [[ -n "$TOOLS_POD" ]]; then
    oc rsh -n openshift-storage $TOOLS_POD ceph status > "$BACKUP_DIR/ceph-status.txt" 2>/dev/null || echo "Could not get Ceph status" > "$BACKUP_DIR/ceph-status.txt"
    oc rsh -n openshift-storage $TOOLS_POD ceph health detail > "$BACKUP_DIR/ceph-health.txt" 2>/dev/null || echo "Could not get Ceph health" > "$BACKUP_DIR/ceph-health.txt"
else
    echo "Ceph tools pod not found" > "$BACKUP_DIR/ceph-status.txt"
fi
oc get pods -n openshift-storage -o wide > "$BACKUP_DIR/odf-pods.txt"
echo "  ✅ Done"
echo ""

# 7. Create summary
echo "📊 Step 7/7: Creating backup summary..."
cat > "$BACKUP_DIR/README.txt" << EOF
OVS Netlink Buffer Fix - Pre-Flight Backup
===========================================

Backup Date: $(date)
Backup Location: $BACKUP_DIR

Contents:
---------
1. Node buffer settings:
   - hosted-worker7-buffers.txt
   - hosted-worker8-buffers.txt
   - hosted-worker9-buffers.txt

2. Network statistics (baseline packet loss):
   - hosted-worker7-network-stats.txt
   - hosted-worker8-network-stats.txt
   - hosted-worker9-network-stats.txt

3. MachineConfigs:
   - all-machineconfigs.yaml (full backup)
   - all-mcp.yaml (all pools)
   - mcp-worker.yaml (worker pool specific)

4. Cluster state:
   - nodes.txt (node list)
   - nodes-full.yaml (full node details)
   - non-running-pods.txt (problem pods)

5. ODF/Ceph state:
   - ceph-status.txt
   - ceph-health.txt
   - odf-pods.txt

How to Use This Backup:
-----------------------
If you need to rollback:

1. Quick rollback (delete MachineConfig):
   oc delete mc 99-worker-netlink-buffers

2. Emergency manual rollback (no reboot):
   See: odf/docs/OVS-Fix-Backup-And-Rollback-Plan.md

3. Compare before/after:
   Compare these files to post-update state

Current Baseline Packet Loss:
------------------------------
$(grep -A 1 "TX:" $BACKUP_DIR/*-network-stats.txt | grep -E "bytes|errors|dropped" || echo "See individual files")

Next Steps:
-----------
1. Apply MachineConfig: oc apply -f odf/manifests/99-worker-netlink-buffers.yaml
2. Monitor MCP: watch -n 5 'oc get mcp worker'
3. After update: Run odf/scripts/verify-netlink-buffers.sh
4. Compare results to this backup

EOF
echo "  ✅ Done"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ BACKUP COMPLETE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📁 Backup saved to: $BACKUP_DIR"
echo ""
echo "📋 Backup includes:"
echo "   • Node buffer settings (current: 212KB)"
echo "   • Network packet statistics"
echo "   • MachineConfigs & MCP state"
echo "   • Cluster & ODF state"
echo ""
echo "📊 Current Packet Loss Summary:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
for NODE in hosted-worker7 hosted-worker8 hosted-worker9; do
    echo "  $NODE:"
    grep -A 1 "TX:" "$BACKUP_DIR/$NODE-network-stats.txt" | tail -1 | awk '{print "    Errors: " $4 ", Dropped: " $5}'
done
echo ""
echo "🛡️  Rollback Plan:"
echo "   See: odf/docs/OVS-Fix-Backup-And-Rollback-Plan.md"
echo ""
echo "▶️  Ready to proceed with fix!"
echo "   Run: odf/scripts/fix-ovs-netlink-buffers.sh"
echo ""

