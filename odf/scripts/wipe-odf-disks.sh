#!/bin/bash
# ODF Disk Wipe Script for ODF 4.18
# This script wipes Ceph metadata at all strategic locations
# Based on: https://github.com/ElCoyote27/krynn-tools/blob/master/wipe_disks.sh

# Usage: Run this script to wipe /dev/vdb on all ODF nodes
# This removes Ceph metadata at: 0, 1GB, 10GB, 100GB, and end-of-disk

set -e

# Auto-discover ODF nodes using the cluster.ocs.openshift.io/openshift-storage label
echo "Discovering ODF nodes..."
NODES=$(oc get nodes -l cluster.ocs.openshift.io/openshift-storage="" -o jsonpath='{.items[*].metadata.name}')

if [ -z "$NODES" ]; then
  echo "ERROR: No nodes found with label cluster.ocs.openshift.io/openshift-storage"
  echo "Please ensure your ODF nodes are labeled correctly:"
  echo "  oc label node <node-name> cluster.ocs.openshift.io/openshift-storage="
  exit 1
fi

echo "Found ODF nodes: $NODES"
echo ""

for node in $NODES; do
  echo "=== Comprehensive Ceph metadata wipe on $node ==="
  oc debug node/$node -- chroot /host bash -c '
    DISK=/dev/vdb
    
    # Step 1: Wipe partition table and filesystem signatures
    echo "Step 1: Wiping partition table and filesystem signatures..."
    sgdisk -Z $DISK 2>/dev/null
    wipefs -fa $DISK
    
    # Step 2: Get disk size
    echo "Step 2: Getting disk size..."
    SECTORS=$(blockdev --getsz $DISK)
    DISK_GB=$((SECTORS * 512 / 1024 / 1024 / 1024))
    echo "  Disk size: ${DISK_GB}GB, ${SECTORS} sectors"
    
    # Step 3: Wipe Ceph metadata at strategic locations (200KB at each)
    echo "Step 3: Wiping Ceph metadata at strategic locations..."
    
    # 0GB offset
    echo "  Wiping at 0GB..."
    dd if=/dev/zero of=$DISK bs=4K count=50 seek=0 oflag=direct,dsync 2>/dev/null
    
    # 1GB offset (262144 blocks of 4K)
    echo "  Wiping at 1GB..."
    dd if=/dev/zero of=$DISK bs=4K count=50 seek=262144 oflag=direct,dsync 2>/dev/null
    
    # 10GB offset (2621440 blocks of 4K)
    echo "  Wiping at 10GB..."
    dd if=/dev/zero of=$DISK bs=4K count=50 seek=2621440 oflag=direct,dsync 2>/dev/null
    
    # 100GB offset (26214400 blocks of 4K)
    if [ $DISK_GB -ge 100 ]; then
      echo "  Wiping at 100GB..."
      dd if=/dev/zero of=$DISK bs=4K count=50 seek=26214400 oflag=direct,dsync 2>/dev/null
    fi
    
    # End of disk (last 200KB)
    echo "  Wiping at end of disk..."
    END_SEEK=$((SECTORS / 8 - 50))
    dd if=/dev/zero of=$DISK bs=4K count=50 seek=$END_SEEK oflag=direct,dsync 2>/dev/null
    
    # Step 4: Block discard
    echo "Step 4: Block discard..."
    blkdiscard $DISK 2>/dev/null && echo "  Block discard successful" || echo "  Block discard not supported"
    
    sync
    echo "Comprehensive wipe completed"
  ' 2>&1 | grep -v 'Starting pod\|To use host\|Removing debug' &
done

wait
echo ""
echo "All nodes wiped successfully!"
echo ""
echo "Next steps:"
echo "1. If needed, wipe /var/lib/rook: oc debug node/<node> -- chroot /host rm -rf /var/lib/rook/*"
echo "2. Deploy ODF: oc apply -f odf/manifests/odf-minimal-4.18.yaml"

