#!/bin/bash
# Monitor MCP Update and ODF Recovery
# Usage: ./monitor-mcp-update.sh

set -e

NAMESPACE="openshift-storage"
TOOLS_POD=$(oc get pod -n ${NAMESPACE} -l app=rook-ceph-tools -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║              MCP Update & ODF Recovery Monitor                        ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""

# Check if logged in
if ! oc whoami &>/dev/null; then
    echo "❌ Not logged into OpenShift"
    exit 1
fi

echo "✅ Logged in as: $(oc whoami)"
echo ""

# Check MCP Status
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Machine Config Pool Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
oc get machineconfigpool -o custom-columns=NAME:.metadata.name,UPDATING:.status.conditions[?\(@.type==\"Updating\"\)].status,READY:.status.conditions[?\(@.type==\"Updated\"\)].status,UPDATED:.status.updatedMachineCount,READY_COUNT:.status.readyMachineCount,TOTAL:.status.machineCount

echo ""

# Check nodes being updated
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Node Update Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
UPDATING_NODES=$(oc get nodes -o json | jq -r '.items[] | select(.spec.unschedulable == true) | .metadata.name' 2>/dev/null || echo "")
if [ -n "$UPDATING_NODES" ]; then
    echo "⚠️  Nodes being updated (cordoned):"
    for node in $UPDATING_NODES; do
        echo "   - $node"
        NODE_STATUS=$(oc get node $node -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        echo "     Status: $NODE_STATUS"
    done
else
    echo "✅ No nodes currently being updated"
fi

echo ""

# Check ODF/Ceph Status
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 ODF/Ceph Cluster Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -z "$TOOLS_POD" ]; then
    echo "⚠️  Ceph tools pod not available"
    oc get cephcluster -n ${NAMESPACE} -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,HEALTH:.status.ceph.health
else
    echo "📊 Ceph Health:"
    HEALTH=$(oc exec -n ${NAMESPACE} ${TOOLS_POD} -- ceph health 2>/dev/null | head -1 || echo "UNKNOWN")
    echo "$HEALTH"
    
    if echo "$HEALTH" | grep -q "HEALTH_OK"; then
        echo "✅ Ceph cluster is healthy"
    elif echo "$HEALTH" | grep -q "HEALTH_WARN"; then
        echo "⚠️  Ceph cluster in HEALTH_WARN (expected during node updates)"
        echo ""
        echo "   Checking details..."
        oc exec -n ${NAMESPACE} ${TOOLS_POD} -- ceph health detail 2>/dev/null | head -10 || echo "   Cannot get details"
    elif echo "$HEALTH" | grep -q "HEALTH_ERR"; then
        echo "❌ Ceph cluster in HEALTH_ERR - ACTION REQUIRED"
    fi
fi

echo ""

# Check Monitor Pods
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Monitor Pods"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
oc get pods -n ${NAMESPACE} -l app=rook-ceph-mon -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[*].ready,NODE:.spec.nodeName

MON_PENDING=$(oc get pods -n ${NAMESPACE} -l app=rook-ceph-mon --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
if [ "$MON_PENDING" -gt 0 ]; then
    echo ""
    echo "⚠️  $MON_PENDING monitor pod(s) pending (waiting for node update to complete)"
fi

echo ""

# Check OSD Pods
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 OSD Pods"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
oc get pods -n ${NAMESPACE} -l app=rook-ceph-osd -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[*].ready,NODE:.spec.nodeName

echo ""

# Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Summary & Recommendations"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

MCP_UPDATING=$(oc get machineconfigpool worker -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}' 2>/dev/null || echo "False")
if [ "$MCP_UPDATING" = "True" ]; then
    UPDATED=$(oc get machineconfigpool worker -o jsonpath='{.status.updatedMachineCount}' 2>/dev/null || echo "0")
    TOTAL=$(oc get machineconfigpool worker -o jsonpath='{.status.machineCount}' 2>/dev/null || echo "0")
    echo "⚠️  MCP Update in Progress: $UPDATED/$TOTAL nodes updated"
    echo ""
    echo "✅ Expected Behavior:"
    echo "   - HEALTH_WARN during update is normal"
    echo "   - Monitor pods pending is expected"
    echo "   - Wait for update to complete"
    echo ""
    echo "📊 Monitor with:"
    echo "   watch -n 10 'oc get machineconfigpool worker'"
    echo "   watch -n 30 './monitor-mcp-update.sh'"
else
    echo "✅ MCP Update Complete"
    echo ""
    echo "📊 Verify Ceph Recovery:"
    echo "   ./odf-health-check.sh"
    echo ""
    if [ -n "$TOOLS_POD" ]; then
        CURRENT_HEALTH=$(oc exec -n ${NAMESPACE} ${TOOLS_POD} -- ceph health 2>/dev/null | head -1 || echo "UNKNOWN")
        if echo "$CURRENT_HEALTH" | grep -q "HEALTH_WARN"; then
            echo "⚠️  Still in HEALTH_WARN - Recovery may take 5-15 minutes"
            echo "   Monitor: oc exec -n ${NAMESPACE} ${TOOLS_POD} -- ceph health"
        elif echo "$CURRENT_HEALTH" | grep -q "HEALTH_OK"; then
            echo "✅ Ceph cluster recovered to HEALTH_OK"
        fi
    fi
fi

echo ""
echo "✅ Monitor complete"
echo ""

