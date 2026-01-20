#!/bin/bash
# Fix Stuck RBD Device on CSI Plugin Node
# Usage: ./odf/scripts/fix-csi-rbd-plugin.sh <pod-name> [node-name]

set -e

POD_NAME="${1}"
NODE_NAME="${2}"
NAMESPACE="openshift-storage"

if [ -z "$POD_NAME" ]; then
    echo "Usage: $0 <csi-rbdplugin-pod-name> [node-name]"
    echo ""
    echo "Example:"
    echo "  $0 csi-rbdplugin-bx55r management-worker-1.hypershift.lab"
    echo ""
    echo "Available CSI RBD plugins:"
    oc get pods -n ${NAMESPACE} -l app=csi-rbdplugin -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase
    exit 1
fi

echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║          Fix Stuck RBD Device on CSI Plugin Node                      ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""

# Check if logged in
if ! oc whoami &>/dev/null; then
    echo "❌ Not logged into OpenShift"
    exit 1
fi

echo "✅ Logged in as: $(oc whoami)"
echo ""

# Get node name if not provided
if [ -z "$NODE_NAME" ]; then
    NODE_NAME=$(oc get pod -n ${NAMESPACE} ${POD_NAME} -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
    if [ -z "$NODE_NAME" ]; then
        echo "❌ Cannot get node name for pod ${POD_NAME}"
        exit 1
    fi
fi

echo "📊 Pod: ${POD_NAME}"
echo "📊 Node: ${NODE_NAME}"
echo ""

# Check if MCP update is in progress
MCP_UPDATING=$(oc get machineconfigpool worker -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}' 2>/dev/null || echo "False")
if [ "$MCP_UPDATING" = "True" ]; then
    echo "⚠️  MCP Update in Progress!"
    echo ""
    echo "⚠️  IMPORTANT: Do not fix CSI plugins during MCP updates"
    echo "   - Wait for update to complete"
    echo "   - Issues may resolve automatically after update"
    echo ""
    exit 0
fi

# Check pod status
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 Current Pod Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
oc get pod -n ${NAMESPACE} ${POD_NAME} -o wide

echo ""
echo "📊 Checking for stuck RBD devices..."
echo ""

# Check logs for stuck device errors
STUCK_ERRORS=$(oc logs -n ${NAMESPACE} ${POD_NAME} -c csi-rbdplugin --tail=200 2>&1 | grep -i "device or resource busy\|apparently in use" | wc -l || echo "0")

if [ "$STUCK_ERRORS" -gt 0 ]; then
    echo "⚠️  Found stuck device errors in logs"
    echo ""
    echo "📋 Recent errors:"
    oc logs -n ${NAMESPACE} ${POD_NAME} -c csi-rbdplugin --tail=50 2>&1 | grep -i "error\|device\|busy" | tail -5
    echo ""
fi

# Check if we can access the node via debug pod
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 Checking Node-Level RBD Mappings"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Create a debug pod on the same node
DEBUG_POD_NAME="rbd-debug-$(date +%s)"
echo "Creating debug pod on node ${NODE_NAME}..."

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${DEBUG_POD_NAME}
  namespace: ${NAMESPACE}
spec:
  nodeName: ${NODE_NAME}
  hostPID: true
  hostNetwork: true
  containers:
  - name: debug
    image: quay.io/ceph/ceph:v18
    command: ["sleep", "300"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: host-dev
      mountPath: /dev
    - name: host-sys
      mountPath: /sys
    - name: host-run
      mountPath: /run
  volumes:
  - name: host-dev
    hostPath:
      path: /dev
  - name: host-sys
    hostPath:
      path: /sys
  - name: host-run
    hostPath:
      path: /run
EOF

echo "Waiting for debug pod to be ready..."
sleep 5
oc wait --for=condition=ready pod/${DEBUG_POD_NAME} -n ${NAMESPACE} --timeout=60s || echo "Pod may still be starting"

echo ""
echo "📊 Current RBD mappings on node:"
oc exec -n ${NAMESPACE} ${DEBUG_POD_NAME} -- rbd showmapped 2>/dev/null || echo "Cannot check RBD mappings"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔧 Fix Options"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Option 1: Restart CSI Plugin Pod (Recommended)"
echo "  This will force cleanup of stuck operations"
echo ""
echo "Option 2: Unmap Stuck RBD Device (If restart doesn't work)"
echo "  Requires manual RBD unmap command"
echo ""

read -p "Restart CSI plugin pod ${POD_NAME}? (yes/no): " CONFIRM

if [ "$CONFIRM" = "yes" ]; then
    echo ""
    echo "🔄 Restarting CSI plugin pod..."
    oc delete pod -n ${NAMESPACE} ${POD_NAME}
    
    echo "   Waiting for pod to restart..."
    sleep 10
    
    # Wait for new pod (DaemonSet will recreate)
    NEW_POD=$(oc get pods -n ${NAMESPACE} -l app=csi-rbdplugin --field-selector spec.nodeName=${NODE_NAME} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$NEW_POD" ]; then
        echo "   New pod: ${NEW_POD}"
        echo "   Waiting for readiness..."
        oc wait --for=condition=ready pod/${NEW_POD} -n ${NAMESPACE} --timeout=120s || echo "Pod may still be starting"
        
        echo ""
        echo "✅ Pod restarted"
        echo ""
        echo "📊 New pod status:"
        oc get pod -n ${NAMESPACE} ${NEW_POD} -o wide
        
        echo ""
        echo "📋 Checking for errors (wait 30 seconds for startup)..."
        sleep 30
        oc logs -n ${NAMESPACE} ${NEW_POD} -c csi-rbdplugin --tail=20 2>&1 | grep -i "error\|warn" | tail -5 || echo "No errors found"
    else
        echo "⚠️  Cannot find new pod on node ${NODE_NAME}"
        echo "   Listing all CSI RBD plugins:"
        oc get pods -n ${NAMESPACE} -l app=csi-rbdplugin
    fi
else
    echo "Skipping pod restart"
fi

# Cleanup debug pod
echo ""
echo "🧹 Cleaning up debug pod..."
oc delete pod ${DEBUG_POD_NAME} -n ${NAMESPACE} --ignore-not-found=true

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "✅ Fix attempt completed"
echo ""
echo "📊 Verify fix:"
echo "   oc get pods -n ${NAMESPACE} -l app=csi-rbdplugin | grep ${NODE_NAME}"
echo "   oc logs -n ${NAMESPACE} <new-pod-name> -c csi-rbdplugin --tail=50"
echo ""
echo "📊 If issues persist:"
echo "   1. Check node-level RBD mappings (requires SSH access)"
echo "   2. Manually unmap stuck devices: rbd unmap /dev/rbd0"
echo "   3. Check for kernel module issues: lsmod | grep rbd"
echo ""



