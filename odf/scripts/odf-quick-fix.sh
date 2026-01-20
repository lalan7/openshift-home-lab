#!/bin/bash
# ODF Quick Fix Script
# Fixes immediate issues: CSI plugin failures and monitors OSD recovery

set -e

NAMESPACE="openshift-storage"
TOOLS_POD=$(oc get pod -n ${NAMESPACE} -l app=rook-ceph-tools -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║                    ODF Quick Fix                                      ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""

# Check if logged in
if ! oc whoami &>/dev/null; then
    echo "❌ Not logged into OpenShift"
    exit 1
fi

# Check if MCP update is in progress
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 Checking MCP Update Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

MCP_UPDATING=$(oc get machineconfigpool worker -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}' 2>/dev/null || echo "False")
if [ "$MCP_UPDATING" = "True" ]; then
    echo "⚠️  MCP Update in Progress!"
    echo ""
    echo "⚠️  IMPORTANT: Do not interfere with ongoing MCP update"
    echo "   - HEALTH_WARN during update is expected"
    echo "   - OSD/Monitor issues will auto-recover after update"
    echo "   - Wait for update to complete before taking action"
    echo ""
    echo "📊 Monitor update progress:"
    oc get machineconfigpool worker
    echo ""
    echo "✅ Skipping fixes during MCP update"
    echo "   Run this script again after update completes"
    echo ""
    exit 0
else
    echo "✅ No MCP update in progress - proceeding with fixes"
fi

echo ""

# Check current health
echo "📊 Current Ceph Health:"
if [ -n "$TOOLS_POD" ]; then
    CURRENT_HEALTH=$(oc exec -n ${NAMESPACE} ${TOOLS_POD} -- ceph health 2>/dev/null | head -1 || echo "UNKNOWN")
    echo "$CURRENT_HEALTH"
else
    echo "⚠️  Cannot check health (tools pod not available)"
fi
echo ""

# Fix 1: Restart failed CSI plugins
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔧 Fix 1: Restart Failed CSI Plugins"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

FAILED_RBD=$(oc get pods -n ${NAMESPACE} -l app=csi-rbdplugin --field-selector=status.phase!=Running --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || echo "")
FAILED_CEPHFS=$(oc get pods -n ${NAMESPACE} -l app=csi-cephfsplugin --field-selector=status.phase!=Running --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || echo "")

if [ -n "$FAILED_RBD" ]; then
    echo "🔧 Restarting failed RBD plugins:"
    for pod in $FAILED_RBD; do
        echo "   Deleting pod: $pod"
        oc delete pod -n ${NAMESPACE} $pod
    done
    echo "   ⏳ Waiting for pods to restart..."
    sleep 10
    oc wait --for=condition=ready pod -l app=csi-rbdplugin -n ${NAMESPACE} --timeout=120s || echo "⚠️  Some RBD pods may still be starting"
else
    echo "✅ No failed RBD plugins found"
fi

if [ -n "$FAILED_CEPHFS" ]; then
    echo "🔧 Restarting failed CephFS plugins:"
    for pod in $FAILED_CEPHFS; do
        echo "   Deleting pod: $pod"
        oc delete pod -n ${NAMESPACE} $pod
    done
    echo "   ⏳ Waiting for pods to restart..."
    sleep 10
    oc wait --for=condition=ready pod -l app=csi-cephfsplugin -n ${NAMESPACE} --timeout=120s || echo "⚠️  Some CephFS pods may still be starting"
else
    echo "✅ No failed CephFS plugins found"
fi

echo ""

# Fix 2: Check and report on Ceph cluster issues
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 Fix 2: Ceph Cluster Status Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -z "$TOOLS_POD" ]; then
    echo "⚠️  Ceph tools pod not available"
    echo "   Checking cluster CR status:"
    oc get cephcluster -n ${NAMESPACE}
else
    echo "📊 OSD Status:"
    oc exec -n ${NAMESPACE} ${TOOLS_POD} -- ceph osd tree 2>/dev/null || echo "❌ Cannot get OSD status"
    echo ""
    
    echo "📊 Monitor Status:"
    oc exec -n ${NAMESPACE} ${TOOLS_POD} -- ceph mon stat 2>/dev/null || echo "❌ Cannot get monitor status"
    echo ""
    
    echo "📊 Health Details:"
    HEALTH_DETAIL=$(oc exec -n ${NAMESPACE} ${TOOLS_POD} -- ceph health detail 2>/dev/null || echo "")
    if echo "$HEALTH_DETAIL" | grep -q "MON_DOWN"; then
        echo "⚠️  Monitor down detected - check monitor pods:"
        oc get pods -n ${NAMESPACE} -l app=rook-ceph-mon
        echo ""
        echo "💡 To fix: Restart failed monitor pod or check node status"
    fi
    
    if echo "$HEALTH_DETAIL" | grep -q "OSD_DOWN"; then
        echo "⚠️  OSD down detected"
        echo ""
        echo "💡 To fix:"
        echo "   1. Check if node is down: oc get nodes"
        echo "   2. If node will recover: Wait for automatic recovery"
        echo "   3. If node is permanently down: Mark OSD as out"
        echo "      oc exec -n ${NAMESPACE} ${TOOLS_POD} -- ceph osd out osd.X"
    fi
    
    if echo "$HEALTH_DETAIL" | grep -q "PG_DEGRADED"; then
        echo "⚠️  Placement groups degraded"
        echo ""
        echo "💡 To fix:"
        echo "   - Wait for automatic recovery after OSD/monitor issues are resolved"
        echo "   - Check recovery progress: oc exec -n ${NAMESPACE} ${TOOLS_POD} -- ceph pg stat"
    fi
fi

echo ""

# Fix 3: Verify CSI plugins are healthy
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Fix 3: Verify CSI Plugins"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

RBD_READY=$(oc get pods -n ${NAMESPACE} -l app=csi-rbdplugin --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
RBD_TOTAL=$(oc get pods -n ${NAMESPACE} -l app=csi-rbdplugin --no-headers 2>/dev/null | wc -l)

CEPHFS_READY=$(oc get pods -n ${NAMESPACE} -l app=csi-cephfsplugin --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
CEPHFS_TOTAL=$(oc get pods -n ${NAMESPACE} -l app=csi-cephfsplugin --no-headers 2>/dev/null | wc -l)

echo "📊 RBD Plugins: $RBD_READY/$RBD_TOTAL Running"
echo "📊 CephFS Plugins: $CEPHFS_READY/$CEPHFS_TOTAL Running"

if [ "$RBD_READY" -eq "$RBD_TOTAL" ] && [ "$CEPHFS_READY" -eq "$CEPHFS_TOTAL" ]; then
    echo "✅ All CSI plugins are Running"
else
    echo "⚠️  Some CSI plugins are not Running"
    echo "   Wait a few minutes and check again: oc get pods -n ${NAMESPACE} -l 'app in (csi-rbdplugin,csi-cephfsplugin)'"
fi

echo ""

# Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "✅ CSI plugin restarts completed"
echo ""
echo "⚠️  Ceph Cluster Issues:"
echo "   - Review health details above"
echo "   - Most issues require manual intervention based on root cause"
echo ""
echo "📖 Next Steps:"
echo "   1. Review Ceph health details above"
echo "   2. Fix OSD/monitor issues if needed"
echo "   3. Run health check: ./odf-health-check.sh"
echo "   4. See detailed analysis: docs/ODF-Health-Analysis-and-Recommendations.md"
echo ""

if [ -n "$TOOLS_POD" ]; then
    FINAL_HEALTH=$(oc exec -n ${NAMESPACE} ${TOOLS_POD} -- ceph health 2>/dev/null | head -1 || echo "UNKNOWN")
    echo "📊 Final Ceph Health: $FINAL_HEALTH"
fi

echo ""
echo "✅ Quick fix complete"
echo ""

