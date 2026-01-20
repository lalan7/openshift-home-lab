#!/bin/bash
# Fix stuck RBD kernel operations
# Usage: ./odf/scripts/fix-rbd-kernel-stuck.sh <node-name>

NODE="${1}"

if [[ -z "$NODE" ]]; then
    echo "❌ Error: Node name required"
    echo "Usage: $0 <node-name>"
    echo "Example: $0 management-worker-1.hypershift.lab"
    exit 1
fi

echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║        Fix Stuck RBD Kernel Operations                                  ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Node: $NODE"
echo ""
echo "⚠️  WARNING: This will forcefully clean RBD state on the node"
echo "⚠️  Active workloads using RBD may be affected"
echo ""
read -p "Continue? (yes/no): " confirm

if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1: Check current state"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

oc debug node/$NODE --to-namespace=default -- chroot /host /bin/bash -c '

echo "Stuck rbd processes:"
ps aux | grep "[r]bd" | head -20 || echo "None"
echo ""

echo "Mapped RBD devices:"
rbd showmapped 2>/dev/null || echo "None"
echo ""

echo "Device mapper RBD entries:"
dmsetup ls 2>/dev/null | grep rbd || echo "None"
echo ""

'

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2: Kill stuck rbd processes"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

oc debug node/$NODE --to-namespace=default -- chroot /host /bin/bash -c '

RBD_PIDS=$(ps aux | grep "[r]bd" | awk "{print \$2}")

if [[ -n "$RBD_PIDS" ]]; then
    echo "Killing rbd processes: $RBD_PIDS"
    for pid in $RBD_PIDS; do
        kill -9 $pid 2>/dev/null && echo "  ✓ Killed PID $pid" || echo "  ✗ Failed to kill PID $pid"
    done
else
    echo "No rbd processes to kill"
fi

echo ""
sleep 2

echo "Remaining rbd processes:"
ps aux | grep "[r]bd" || echo "None (good!)"

'

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 3: Force unmap all RBD devices"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

oc debug node/$NODE --to-namespace=default -- chroot /host /bin/bash -c '

MAPPED_DEVICES=$(rbd showmapped 2>/dev/null | tail -n +2 | awk "{print \$1}")

if [[ -n "$MAPPED_DEVICES" ]]; then
    echo "Unmapping RBD devices:"
    for dev in $MAPPED_DEVICES; do
        echo "  Unmapping /dev/rbd$dev..."
        rbd unmap /dev/rbd$dev --force 2>&1 && echo "    ✓ Unmapped" || echo "    ⚠ Failed (may require reboot)"
    done
else
    echo "No RBD devices to unmap"
fi

echo ""
sleep 2

echo "Remaining mapped devices:"
rbd showmapped 2>/dev/null || echo "None (good!)"

'

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 4: Clean device mapper"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

oc debug node/$NODE --to-namespace=default -- chroot /host /bin/bash -c '

DM_RBD=$(dmsetup ls 2>/dev/null | grep rbd | awk "{print \$1}")

if [[ -n "$DM_RBD" ]]; then
    echo "Removing device mapper RBD entries:"
    for dm in $DM_RBD; do
        echo "  Removing $dm..."
        dmsetup remove --force $dm 2>&1 && echo "    ✓ Removed" || echo "    ⚠ Failed"
    done
else
    echo "No device mapper RBD entries to remove"
fi

echo ""
sleep 2

echo "Remaining device mapper RBD entries:"
dmsetup ls 2>/dev/null | grep rbd || echo "None (good!)"

'

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 5: Reload RBD kernel module"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

oc debug node/$NODE --to-namespace=default -- chroot /host /bin/bash -c '

echo "Unloading RBD kernel module..."
modprobe -r rbd 2>&1 && echo "  ✓ Module unloaded" || echo "  ⚠ Failed to unload (may be in use)"

echo ""
sleep 3

echo "Loading RBD kernel module..."
modprobe rbd 2>&1 && echo "  ✓ Module loaded" || echo "  ✗ Failed to load"

echo ""

echo "RBD module status:"
lsmod | grep rbd || echo "RBD module not loaded"

'

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 6: Check kernel logs for errors"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

oc debug node/$NODE --to-namespace=default -- chroot /host /bin/bash -c '

echo "Recent RBD-related kernel messages:"
dmesg | grep -i rbd | tail -20 || echo "No RBD messages in dmesg"

'

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 7: Restart CSI RBD plugin on node"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

CSI_POD=$(oc get pods -n openshift-storage -l app=csi-rbdplugin -o wide | grep $NODE | awk '{print $1}' | head -1)

if [[ -n "$CSI_POD" ]]; then
    echo "Found CSI RBD plugin pod: $CSI_POD"
    echo "Deleting pod to restart and clear internal locks..."
    oc delete pod -n openshift-storage $CSI_POD --grace-period=0 --force
    
    echo ""
    echo "Waiting for new pod to start..."
    sleep 10
    
    echo ""
    echo "New CSI RBD plugin status:"
    oc get pods -n openshift-storage -l app=csi-rbdplugin -o wide | grep $NODE
else
    echo "⚠ No CSI RBD plugin pod found on node $NODE"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Fix Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Next steps:"
echo "  1. Wait 1-2 minutes for CSI plugin to fully initialize"
echo "  2. Test RBD PVC creation"
echo "  3. Monitor CSI plugin logs for any errors"
echo ""
echo "Test command:"
echo "  oc create -f odf/templates/pod-rbd-test.yaml.template"
echo ""


