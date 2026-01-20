#!/bin/bash
# Fix OVS Netlink Buffer Overflow
# 
# This script applies a MachineConfig to increase netlink buffers
# which fixes packet loss in OVN-Kubernetes networking
#
# Impact: Nodes will reboot sequentially (MCP update)
# Time: 30-60 minutes
#
# Root cause: Default netlink buffers (200KB) are too small for
# ODF/Ceph traffic, causing packet drops on Geneve tunnels

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/../manifests/99-worker-netlink-buffers.yaml"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  OVS Netlink Buffer Overflow Fix"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📊 Current Issue:"
echo "   - Packet loss on Geneve tunnels"
echo "   - Netlink buffers too small (200KB)"
echo "   - Causing Ceph/RBD timeouts"
echo ""
echo "🔧 Fix:"
echo "   - Increase netlink buffers to 4MB (20x)"
echo "   - Increase netdev budget to 600"
echo "   - Increase backlog queue to 5000"
echo ""
echo "⚠️  WARNING:"
echo "   - This will trigger a MachineConfig update"
echo "   - Worker nodes will reboot sequentially"
echo "   - Expected time: 30-60 minutes"
echo "   - Workloads will be rescheduled"
echo ""

read -p "Continue with MachineConfig application? (yes/no): " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    echo "❌ Aborted by user"
    exit 1
fi

echo ""
echo "📋 Step 1: Checking current packet loss..."
echo ""

for NODE in hosted-worker7.hypershift.lab hosted-worker8.hypershift.lab hosted-worker9.hypershift.lab; do
    echo "Checking $NODE..."
    oc debug node/$NODE --to-namespace=default -- chroot /host bash -c \
        "ip -s link show genev_sys_6081 2>/dev/null | grep -A 1 'TX:'" 2>&1 | \
        grep -E "TX:|bytes|errors|dropped" || true
    echo ""
done

echo ""
echo "📋 Step 2: Checking current MCP status..."
echo ""
oc get mcp worker

echo ""
echo "📋 Step 3: Applying MachineConfig..."
echo ""

if [[ ! -f "$MANIFEST" ]]; then
    echo "❌ Error: Manifest not found: $MANIFEST"
    exit 1
fi

oc apply -f "$MANIFEST"

echo ""
echo "✅ MachineConfig applied!"
echo ""
echo "📊 Step 4: Monitoring MCP update..."
echo ""
echo "Watch the MCP update progress:"
echo "  oc get mcp worker -w"
echo ""
echo "Or use this command to monitor:"
echo "  watch -n 5 'oc get mcp worker; echo ""; oc get nodes | grep hosted-worker'"
echo ""
echo "⏳ Wait for:"
echo "   - UPDATING: True → False"
echo "   - UPDATED: False → True"
echo "   - DEGRADED: False (should stay False)"
echo ""
echo "When complete, verify with:"
echo "  $SCRIPT_DIR/verify-netlink-buffers.sh"
echo ""

