#!/bin/bash
# Network Diagnostics for ODF/CSI Issues
# Usage: ./odf/scripts/network-diagnostics.sh

set -e

NAMESPACE="openshift-storage"

echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║            Network Diagnostics for ODF/CSI                             ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""

# Check if logged in
if ! oc whoami &>/dev/null; then
    echo "❌ Not logged into OpenShift"
    exit 1
fi

echo "✅ Logged in as: $(oc whoami)"
echo ""

# Get Ceph monitor IPs
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Ceph Monitor Endpoints"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

MON_ENDPOINTS=$(oc get configmap -n ${NAMESPACE} rook-ceph-mon-endpoints -o jsonpath='{.data.data}' 2>/dev/null)
echo "$MON_ENDPOINTS"
echo ""

# Extract monitor IPs
MON_IPS=$(echo "$MON_ENDPOINTS" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u)
echo "Monitor IPs:"
echo "$MON_IPS"
echo ""

# Get worker nodes
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Worker Nodes"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
oc get nodes -o custom-columns=NAME:.metadata.name,IP:.status.addresses[0].address,ROLE:.metadata.labels.'node-role\.kubernetes\.io/worker' | grep worker

echo ""

# Test network latency from CSI plugins to monitors
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Network Latency Test (CSI Plugin → Ceph Monitors)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Get one CSI plugin pod per node
CSI_PODS=$(oc get pods -n ${NAMESPACE} -l app=csi-rbdplugin -o json | jq -r '.items[] | select(.status.phase=="Running") | "\(.metadata.name)|\(.spec.nodeName)"' | head -3)

for pod_info in $CSI_PODS; do
    POD_NAME=$(echo $pod_info | cut -d'|' -f1)
    NODE_NAME=$(echo $pod_info | cut -d'|' -f2)
    
    echo ""
    echo "📍 Node: $NODE_NAME"
    echo "   Pod: $POD_NAME"
    echo ""
    
    for MON_IP in $MON_IPS; do
        echo "   Testing → Monitor $MON_IP:3300"
        
        # Test TCP connectivity
        CONN_TEST=$(oc exec -n ${NAMESPACE} ${POD_NAME} -c csi-rbdplugin -- timeout 5 sh -c "echo -n '' | nc -v -w 2 $MON_IP 3300" 2>&1 | grep -i "succeeded\|open\|connected" || echo "FAILED")
        
        if echo "$CONN_TEST" | grep -qi "succeeded\|open\|connected"; then
            echo "      ✅ TCP connection: OK"
        else
            echo "      ❌ TCP connection: FAILED"
        fi
        
        # Test ping (if available)
        PING_TEST=$(oc exec -n ${NAMESPACE} ${POD_NAME} -c csi-rbdplugin -- timeout 3 ping -c 3 -W 1 $MON_IP 2>&1 | grep "avg" || echo "N/A")
        if [ "$PING_TEST" != "N/A" ]; then
            AVG_TIME=$(echo "$PING_TEST" | grep -oE 'avg = [0-9.]+' || echo "$PING_TEST")
            echo "      📊 Ping: $AVG_TIME"
        fi
    done
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 CSI Plugin Network Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check one CSI plugin network config
FIRST_POD=$(echo "$CSI_PODS" | head -1 | cut -d'|' -f1)

echo ""
echo "📍 Network interfaces on CSI plugin:"
oc exec -n ${NAMESPACE} ${FIRST_POD} -c csi-rbdplugin -- ip addr show 2>/dev/null | grep -E "^[0-9]+:|inet " || echo "Cannot get network info"

echo ""
echo "📍 Routing table:"
oc exec -n ${NAMESPACE} ${FIRST_POD} -c csi-rbdplugin -- ip route show 2>/dev/null | head -10 || echo "Cannot get routing info"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 GRPC Performance Test"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "Checking recent GRPC slow calls in CSI plugins:"
for pod_info in $CSI_PODS; do
    POD_NAME=$(echo $pod_info | cut -d'|' -f1)
    NODE_NAME=$(echo $pod_info | cut -d'|' -f2)
    
    echo ""
    echo "📍 $NODE_NAME ($POD_NAME):"
    SLOW_CALLS=$(oc logs -n ${NAMESPACE} ${POD_NAME} -c csi-rbdplugin --tail=200 2>&1 | grep "Slow GRPC" | tail -3)
    
    if [ -n "$SLOW_CALLS" ]; then
        echo "$SLOW_CALLS" | while read line; do
            echo "   ⚠️  $line"
        done
    else
        echo "   ✅ No slow GRPC calls found"
    fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Summary & Recommendations"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "✅ Network diagnostics complete"
echo ""
echo "📖 For node-level investigation:"
echo "   1. SSH to nodes for deeper diagnostics"
echo "   2. Check bridge network configuration"
echo "   3. Test RBD kernel module: lsmod | grep rbd"
echo "   4. Check device mapper: dmsetup ls"
echo ""
echo "📝 Document findings in: odf/docs/Network-Root-Cause-Analysis.md"
echo ""


