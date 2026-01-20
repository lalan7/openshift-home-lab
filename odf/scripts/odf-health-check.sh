#!/bin/bash
# ODF Health Check Script
# Usage: ./odf-health-check.sh

set -e

NAMESPACE="openshift-storage"
TOOLS_POD=$(oc get pod -n ${NAMESPACE} -l app=rook-ceph-tools -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║                    ODF Health Check                                    ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""

# Check if logged in
if ! oc whoami &>/dev/null; then
    echo "❌ Not logged into OpenShift"
    exit 1
fi

echo "✅ Logged in as: $(oc whoami)"
echo ""

# Check Ceph Cluster Status
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 Ceph Cluster Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -z "$TOOLS_POD" ]; then
    echo "⚠️  Ceph tools pod not found, checking cluster CR..."
    oc get cephcluster -n ${NAMESPACE} -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,HEALTH:.status.ceph.health
else
    echo "📊 Cluster Health:"
    oc exec -n ${NAMESPACE} ${TOOLS_POD} -- ceph health 2>/dev/null || echo "❌ Cannot connect to Ceph"
    echo ""
    
    echo "📊 Cluster Status:"
    oc exec -n ${NAMESPACE} ${TOOLS_POD} -- ceph -s 2>/dev/null | head -20 || echo "❌ Cannot get cluster status"
    echo ""
    
    echo "📊 OSD Status:"
    oc exec -n ${NAMESPACE} ${TOOLS_POD} -- ceph osd tree 2>/dev/null || echo "❌ Cannot get OSD status"
    echo ""
    
    echo "📊 Monitor Status:"
    oc exec -n ${NAMESPACE} ${TOOLS_POD} -- ceph mon stat 2>/dev/null || echo "❌ Cannot get monitor status"
    echo ""
    
    echo "📊 Placement Groups:"
    oc exec -n ${NAMESPACE} ${TOOLS_POD} -- ceph pg stat 2>/dev/null || echo "❌ Cannot get PG status"
    echo ""
    
    echo "📊 Storage Usage:"
    oc exec -n ${NAMESPACE} ${TOOLS_POD} -- ceph df 2>/dev/null || echo "❌ Cannot get storage usage"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 Storage Classes"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
oc get storageclass -o custom-columns=NAME:.metadata.name,DEFAULT:.metadata.annotations.'storageclass\.kubernetes\.io/is-default-class',PROVISIONER:.provisioner | grep -E "ceph|rbd|ocs" || oc get storageclass

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 CSI Plugins Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "📊 CSI RBD Plugins:"
RBD_PODS=$(oc get pods -n ${NAMESPACE} -l app=csi-rbdplugin --no-headers 2>/dev/null | wc -l)
if [ "$RBD_PODS" -gt 0 ]; then
    oc get pods -n ${NAMESPACE} -l app=csi-rbdplugin \
      -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,NODE:.spec.nodeName
    ERROR_COUNT=$(oc get pods -n ${NAMESPACE} -l app=csi-rbdplugin --field-selector=status.phase!=Running --no-headers 2>/dev/null | wc -l)
    if [ "$ERROR_COUNT" -gt 0 ]; then
        echo "⚠️  $ERROR_COUNT RBD plugin pod(s) not Running"
    fi
else
    echo "❌ No CSI RBD plugins found"
fi

echo ""
echo "📊 CSI CephFS Plugins:"
CEPHFS_PODS=$(oc get pods -n ${NAMESPACE} -l app=csi-cephfsplugin --no-headers 2>/dev/null | wc -l)
if [ "$CEPHFS_PODS" -gt 0 ]; then
    oc get pods -n ${NAMESPACE} -l app=csi-cephfsplugin \
      -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,NODE:.spec.nodeName
    ERROR_COUNT=$(oc get pods -n ${NAMESPACE} -l app=csi-cephfsplugin --field-selector=status.phase!=Running --no-headers 2>/dev/null | wc -l)
    if [ "$ERROR_COUNT" -gt 0 ]; then
        echo "⚠️  $CEPHFS_PODS CephFS plugin pod(s) not Running"
    fi
else
    echo "❌ No CSI CephFS plugins found"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 Persistent Volumes"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "📊 RBD PVCs:"
oc get pvc --all-namespaces -o json 2>/dev/null | \
  jq -r '.items[] | select(.spec.storageClassName | contains("rbd")) | "\(.metadata.namespace)/\(.metadata.name): \(.status.phase) (\(.spec.resources.requests.storage))"' \
  || echo "No RBD PVCs found"

echo ""
echo "📊 CephFS PVCs:"
oc get pvc --all-namespaces -o json 2>/dev/null | \
  jq -r '.items[] | select(.spec.storageClassName | contains("cephfs")) | "\(.metadata.namespace)/\(.metadata.name): \(.status.phase) (\(.spec.resources.requests.storage))"' \
  || echo "No CephFS PVCs found"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Health status
if [ -n "$TOOLS_POD" ]; then
    HEALTH=$(oc exec -n ${NAMESPACE} ${TOOLS_POD} -- ceph health 2>/dev/null | head -1 || echo "UNKNOWN")
    if echo "$HEALTH" | grep -q "HEALTH_OK"; then
        echo "✅ Ceph Cluster: HEALTH_OK"
    elif echo "$HEALTH" | grep -q "HEALTH_WARN"; then
        echo "⚠️  Ceph Cluster: HEALTH_WARN - Review details above"
    elif echo "$HEALTH" | grep -q "HEALTH_ERR"; then
        echo "❌ Ceph Cluster: HEALTH_ERR - ACTION REQUIRED"
    else
        echo "❓ Ceph Cluster: Status unknown"
    fi
fi

echo ""
echo "✅ Health check complete"
echo ""
echo "📖 For detailed analysis, see: docs/ODF-Health-Analysis-and-Recommendations.md"

