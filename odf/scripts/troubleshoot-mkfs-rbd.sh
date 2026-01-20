#!/bin/bash
# Deep Troubleshooting of mkfs.ext4 on RBD in KVM
#
# This script creates a test PVC and captures detailed logs/metrics
# during the mkfs.ext4 operation to understand why it's slow/hangs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/tmp/mkfs-troubleshooting-$(date +%Y%m%d-%H%M%S)"
TEST_NAMESPACE="mkfs-debug"
TEST_PVC="mkfs-test-pvc"

mkdir -p "$LOG_DIR"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  mkfs.ext4 Troubleshooting on RBD/KVM"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📁 Logs will be saved to: $LOG_DIR"
echo ""

# Step 1: Create test namespace and PVC
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 1: Creating Test PVC"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

oc create namespace $TEST_NAMESPACE 2>/dev/null || echo "Namespace already exists"

cat > "$LOG_DIR/test-pvc.yaml" << 'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mkfs-test-pvc
  namespace: mkfs-debug
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: ocs-storagecluster-ceph-rbd-kvm
---
apiVersion: v1
kind: Pod
metadata:
  name: mkfs-test-pod
  namespace: mkfs-debug
spec:
  containers:
  - name: test
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    command: ["sleep", "3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: mkfs-test-pvc
EOF

echo "Applying test PVC and Pod..."
oc apply -f "$LOG_DIR/test-pvc.yaml"

echo "✅ Test resources created"
echo ""

# Step 2: Wait for PVC to bind and get volume info
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 2: Waiting for PVC to Bind"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

sleep 5
PVC_STATUS=$(oc get pvc $TEST_PVC -n $TEST_NAMESPACE -o jsonpath='{.status.phase}')
echo "PVC Status: $PVC_STATUS"

if [ "$PVC_STATUS" = "Bound" ]; then
    VOLUME_ID=$(oc get pvc $TEST_PVC -n $TEST_NAMESPACE -o jsonpath='{.spec.volumeName}')
    echo "✅ PVC Bound to volume: $VOLUME_ID"
    echo "$VOLUME_ID" > "$LOG_DIR/volume-id.txt"
else
    echo "⏳ PVC not bound yet, continuing anyway..."
fi

# Step 3: Get pod scheduling info
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 3: Getting Pod Scheduling Info"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

sleep 5
NODE_NAME=$(oc get pod mkfs-test-pod -n $TEST_NAMESPACE -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "not-scheduled")
echo "Pod scheduled on: $NODE_NAME"
echo "$NODE_NAME" > "$LOG_DIR/node-name.txt"

if [ "$NODE_NAME" != "not-scheduled" ] && [ -n "$NODE_NAME" ]; then
    # Get CSI plugin pod on that node
    CSI_POD=$(oc get pods -n openshift-storage -l app=csi-rbdplugin --field-selector spec.nodeName=$NODE_NAME -o name | head -1)
    echo "CSI Plugin: $CSI_POD"
    echo "$CSI_POD" > "$LOG_DIR/csi-pod.txt"
fi

# Step 4: Start monitoring in background
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 4: Starting Background Monitors"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Monitor 1: CSI plugin logs
if [ -n "${CSI_POD:-}" ] && [ "$CSI_POD" != "" ]; then
    echo "📊 Capturing CSI plugin logs..."
    oc logs -n openshift-storage $CSI_POD -c csi-rbdplugin -f > "$LOG_DIR/csi-plugin-logs.txt" 2>&1 &
    CSI_LOG_PID=$!
    echo "  PID: $CSI_LOG_PID"
fi

# Monitor 2: Pod events
echo "📊 Capturing pod events..."
(
    while true; do
        oc get events -n $TEST_NAMESPACE --sort-by='.lastTimestamp' | tail -20 >> "$LOG_DIR/pod-events.txt"
        sleep 5
    done
) &
EVENT_PID=$!
echo "  PID: $EVENT_PID"

# Monitor 3: Pod status
echo "📊 Monitoring pod status..."
(
    while true; do
        echo "$(date +%Y-%m-%d\ %H:%M:%S) - $(oc get pod mkfs-test-pod -n $TEST_NAMESPACE --no-headers 2>/dev/null || echo 'Pod not found')" >> "$LOG_DIR/pod-status-timeline.txt"
        sleep 2
    done
) &
STATUS_PID=$!
echo "  PID: $STATUS_PID"

# Step 5: Monitor node-level activity
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 5: Monitoring Node-Level Activity"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ "$NODE_NAME" != "not-scheduled" ] && [ -n "$NODE_NAME" ]; then
    echo "Waiting 30 seconds for mkfs to start..."
    sleep 30
    
    echo "📊 Checking for mkfs process on node..."
    oc debug node/$NODE_NAME --to-namespace=default -- chroot /host bash -c "
        echo '=== mkfs Processes ==='
        ps aux | grep -E '[m]kfs|[r]bd' | head -20
        
        echo ''
        echo '=== Process States ==='
        ps aux | grep -E '[m]kfs' | awk '{print \$8, \$2, \$11}' | head -20
        
        echo ''
        echo '=== RBD Devices ==='
        rbd device list 2>/dev/null || echo 'Could not list RBD devices'
        
        echo ''
        echo '=== RBD Kernel Module Info ==='
        lsmod | grep rbd
        
        echo ''
        echo '=== Device Mapper Status ==='
        dmsetup status 2>/dev/null | head -10 || echo 'No DM devices'
    " 2>&1 | tee "$LOG_DIR/node-process-check.txt"
    
    echo ""
    echo "📊 Checking kernel logs for RBD/block device activity..."
    oc debug node/$NODE_NAME --to-namespace=default -- chroot /host bash -c "
        dmesg | tail -100 | grep -iE 'rbd|block|ext4|mkfs'
    " 2>&1 | tee "$LOG_DIR/kernel-logs.txt"
    
    echo ""
    echo "📊 Checking system load and I/O..."
    oc debug node/$NODE_NAME --to-namespace=default -- chroot /host bash -c "
        echo '=== Load Average ==='
        uptime
        
        echo ''
        echo '=== CPU Info ==='
        top -bn1 | head -5
        
        echo ''
        echo '=== I/O Statistics ==='
        iostat -x 2 3 2>/dev/null || echo 'iostat not available'
    " 2>&1 | tee "$LOG_DIR/system-metrics.txt"
fi

# Step 6: Wait and collect final status
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 6: Waiting for Mount to Complete (or timeout)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "⏳ Monitoring for up to 10 minutes..."
echo "   Press Ctrl+C to stop early"
echo ""

# Wait for pod to be ready or timeout after 10 minutes
START_TIME=$(date +%s)
TIMEOUT=600  # 10 minutes

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    
    if [ $ELAPSED -gt $TIMEOUT ]; then
        echo "⏱️  Timeout reached (10 minutes)"
        break
    fi
    
    POD_READY=$(oc get pod mkfs-test-pod -n $TEST_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    
    if [ "$POD_READY" = "True" ]; then
        echo "✅ Pod is Ready! (after $ELAPSED seconds)"
        break
    fi
    
    # Show progress every 30 seconds
    if [ $((ELAPSED % 30)) -eq 0 ]; then
        POD_STATUS=$(oc get pod mkfs-test-pod -n $TEST_NAMESPACE --no-headers 2>/dev/null || echo "Unknown")
        echo "[$ELAPSED s] Status: $POD_STATUS"
    fi
    
    sleep 5
done

TOTAL_TIME=$(($(date +%s) - START_TIME))
echo ""
echo "Total time elapsed: $TOTAL_TIME seconds"
echo "$TOTAL_TIME" > "$LOG_DIR/total-time.txt"

# Step 7: Collect final state
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 7: Collecting Final State"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Stop background monitors
echo "Stopping background monitors..."
kill $CSI_LOG_PID 2>/dev/null || true
kill $EVENT_PID 2>/dev/null || true
kill $STATUS_PID 2>/dev/null || true
sleep 2

# Get final pod state
echo "📊 Collecting final pod state..."
oc get pod mkfs-test-pod -n $TEST_NAMESPACE -o yaml > "$LOG_DIR/final-pod-state.yaml" 2>&1 || true
oc describe pod mkfs-test-pod -n $TEST_NAMESPACE > "$LOG_DIR/final-pod-describe.txt" 2>&1 || true

# Get PVC state
echo "📊 Collecting PVC state..."
oc get pvc $TEST_PVC -n $TEST_NAMESPACE -o yaml > "$LOG_DIR/final-pvc-state.yaml" 2>&1 || true

# Get volume attachment
echo "📊 Collecting VolumeAttachment state..."
oc get volumeattachment -o yaml > "$LOG_DIR/volumeattachments.yaml" 2>&1 || true

# Final node check
if [ "$NODE_NAME" != "not-scheduled" ] && [ -n "$NODE_NAME" ]; then
    echo "📊 Final node check..."
    oc debug node/$NODE_NAME --to-namespace=default -- chroot /host bash -c "
        echo '=== Final mkfs Check ==='
        ps aux | grep -E '[m]kfs' || echo 'No mkfs processes running'
        
        echo ''
        echo '=== Final RBD Devices ==='
        rbd device list 2>/dev/null || echo 'Could not list RBD devices'
        
        echo ''
        echo '=== Mounted Filesystems ==='
        mount | grep rbd || echo 'No RBD mounts'
    " 2>&1 | tee "$LOG_DIR/final-node-state.txt"
fi

# Step 8: Generate summary report
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 8: Generating Summary Report"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

cat > "$LOG_DIR/SUMMARY.md" << EOFSUM
# mkfs.ext4 Troubleshooting Report

**Date**: $(date)
**Namespace**: $TEST_NAMESPACE
**PVC**: $TEST_PVC
**Node**: $NODE_NAME
**Total Time**: $TOTAL_TIME seconds

## Quick Stats

- PVC Bind Time: ~5 seconds
- Pod Schedule Time: ~5 seconds  
- Mount Time: ~$TOTAL_TIME seconds

## Files Collected

1. \`test-pvc.yaml\` - Test PVC and Pod definition
2. \`csi-plugin-logs.txt\` - Real-time CSI plugin logs during mount
3. \`pod-events.txt\` - Kubernetes events timeline
4. \`pod-status-timeline.txt\` - Pod status changes over time
5. \`node-process-check.txt\` - mkfs and RBD processes on node
6. \`kernel-logs.txt\` - Kernel messages related to RBD/block devices
7. \`system-metrics.txt\` - CPU, load, I/O statistics
8. \`final-pod-state.yaml\` - Final pod state
9. \`final-node-state.txt\` - Final node state

## Analysis Instructions

### Check for mkfs Hang
\`\`\`bash
# Look for mkfs processes in D state
grep "D.*mkfs" node-process-check.txt
\`\`\`

### Check CSI Plugin Errors
\`\`\`bash
# Search for errors in CSI logs
grep -i error csi-plugin-logs.txt
grep -i "slow grpc" csi-plugin-logs.txt
\`\`\`

### Check Kernel Issues
\`\`\`bash
# Look for RBD kernel module issues
grep -iE "rbd.*error|rbd.*timeout|rbd.*hang" kernel-logs.txt
\`\`\`

### Analyze Timing
\`\`\`bash
# See when pod transitioned from ContainerCreating to Running
cat pod-status-timeline.txt | grep -E "ContainerCreating|Running"
\`\`\`

## Next Steps

If mount took > 5 minutes:
1. Check if mkfs.ext4 was in D (uninterruptible) state
2. Review CSI plugin logs for slow GRPC calls
3. Check kernel logs for RBD device mapper issues
4. Consider switching to NFS for KVM environments

EOFSUM

echo "✅ Summary report created: $LOG_DIR/SUMMARY.md"

# Step 9: Cleanup (optional)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Troubleshooting Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📁 All logs saved to: $LOG_DIR"
echo ""
echo "To clean up test resources:"
echo "  oc delete namespace $TEST_NAMESPACE"
echo ""
echo "To analyze logs:"
echo "  cd $LOG_DIR"
echo "  cat SUMMARY.md"
echo ""









