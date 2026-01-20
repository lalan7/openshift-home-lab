#!/bin/bash
# Storage Class Testing Script
# Tests all ODF storage classes on Server 1 nodes (worker0, 1, 2)

set -e

echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                    ODF Storage Class Testing Suite                          ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
echo ""

# Apply test manifests
echo "📦 Creating test namespace and resources..."
oc apply -f /Users/elalance/Documents/code/MYHOMELAB/odf/manifests/test-all-storage-classes.yaml
echo ""

# Wait for PVCs to bind
echo "⏳ Waiting for PVCs to bind (60 seconds)..."
sleep 60
echo ""

# Check PVC status
echo "📊 PVC Status:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
oc get pvc -n odf-storage-test
echo ""

# Wait for pods to start
echo "⏳ Waiting for pods to start (60 seconds)..."
sleep 60
echo ""

# Check pod status
echo "📊 Pod Status:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
oc get pods -n odf-storage-test -o wide
echo ""

# Check for any pods not running
PENDING=$(oc get pods -n odf-storage-test --field-selector=status.phase!=Running --no-headers 2>/dev/null | wc -l)
if [ "$PENDING" -gt 0 ]; then
    echo "⚠️  Warning: $PENDING pod(s) not in Running state"
    echo ""
    echo "Pod Details:"
    oc get pods -n odf-storage-test --field-selector=status.phase!=Running
    echo ""
fi

# Show logs from each test pod
echo "📋 Test Results:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

for pod in test-rbd-worker0 test-rbd-worker1 test-rbd-worker2 test-cephfs-worker0 test-cephfs-worker1 test-cephfs-worker2; do
    echo "┌─────────────────────────────────────────────────────────────────────────────┐"
    echo "│ $pod"
    echo "└─────────────────────────────────────────────────────────────────────────────┘"
    
    # Check if pod is running
    POD_STATUS=$(oc get pod -n odf-storage-test $pod -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    
    if [ "$POD_STATUS" = "Running" ]; then
        oc logs -n odf-storage-test $pod 2>/dev/null || echo "⚠️  Logs not available yet"
    else
        echo "⚠️  Pod status: $POD_STATUS"
        if [ "$POD_STATUS" != "NotFound" ]; then
            oc describe pod -n odf-storage-test $pod | tail -20
        fi
    fi
    echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Summary
echo "📊 Test Summary:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL_PODS=6
RUNNING_PODS=$(oc get pods -n odf-storage-test --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
echo "Running pods: $RUNNING_PODS / $TOTAL_PODS"
echo ""

TOTAL_PVCS=6
BOUND_PVCS=$(oc get pvc -n odf-storage-test --no-headers 2>/dev/null | grep Bound | wc -l)
echo "Bound PVCs: $BOUND_PVCS / $TOTAL_PVCS"
echo ""

if [ "$RUNNING_PODS" -eq "$TOTAL_PODS" ] && [ "$BOUND_PVCS" -eq "$TOTAL_PVCS" ]; then
    echo "✅ All tests passed!"
else
    echo "⚠️  Some tests failed or are still starting"
fi
echo ""

echo "💡 Commands:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Watch pods:      oc get pods -n odf-storage-test -w"
echo "  View logs:       oc logs -n odf-storage-test <pod-name>"
echo "  Cleanup:         oc delete namespace odf-storage-test"
echo ""

