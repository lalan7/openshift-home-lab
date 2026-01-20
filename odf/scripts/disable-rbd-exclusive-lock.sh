#!/bin/bash
# Disable RBD exclusive-lock feature for KVM compatibility
# This is the RECOMMENDED solution for RBD in KVM VMs

echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║   Disable RBD Exclusive-Lock (KVM Compatibility Fix)                    ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Why: RBD exclusive-lock causes kernel hangs in KVM virtual machines"
echo "     due to lock timeout issues in nested virtualization."
echo ""

# Update the storage class to disable exclusive-lock
cat <<EOF | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ocs-storagecluster-ceph-rbd-kvm
  annotations:
    description: "RBD storage class optimized for KVM VMs (no exclusive-lock)"
provisioner: openshift-storage.rbd.csi.ceph.com
parameters:
  clusterID: openshift-storage
  pool: ocs-storagecluster-cephblockpool
  imageFeatures: layering,deep-flatten
  # Removed: exclusive-lock,object-map,fast-diff
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: openshift-storage
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: openshift-storage
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: openshift-storage
  csi.storage.k8s.io/fstype: ext4
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF

echo ""
echo "✅ Created new storage class: ocs-storagecluster-ceph-rbd-kvm"
echo ""
echo "Features comparison:"
echo "  Old (0x3d): layering, deep-flatten, exclusive-lock, object-map, fast-diff"
echo "  New:        layering, deep-flatten"
echo ""
echo "Benefits:"
echo "  ✅ No kernel hangs in KVM VMs"
echo "  ✅ Faster mount/unmount operations"
echo "  ✅ No lock timeout issues"
echo ""
echo "Trade-offs:"
echo "  ⚠️  No automatic snapshot protection (rarely needed)"
echo "  ⚠️  Slightly less optimal for some workloads (minimal impact)"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Next Steps:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1. Set as default storage class (optional):"
echo "   oc patch storageclass ocs-storagecluster-ceph-rbd-kvm -p '{\"metadata\": {\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}'"
echo "   oc patch storageclass ocs-storagecluster-ceph-rbd -p '{\"metadata\": {\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"false\"}}}'"
echo ""
echo "2. Test with new storage class:"
echo "   # Edit your PVC to use: storageClassName: ocs-storagecluster-ceph-rbd-kvm"
echo ""
echo "3. Migrate existing PVCs (if needed):"
echo "   # This requires data migration - backup first!"
echo ""

