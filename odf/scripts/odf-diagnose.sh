#!/bin/bash
# ODF Complete Diagnostic Tool
# Usage: ./odf-diagnose.sh [options]
# Options:
#   --node <node-name>     Check specific node
#   --namespace <ns>       ODF namespace (default: openshift-storage)
#   --full                 Run full diagnostics (includes slow operations)
#   --output <file>        Save output to file
#   --kvm                  Include KVM-specific checks

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
ODF_NAMESPACE="${ODF_NAMESPACE:-openshift-storage}"
FULL_DIAGNOSTICS=false
OUTPUT_FILE=""
KVM_MODE=false
TARGET_NODE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --node)
            TARGET_NODE="$2"
            shift 2
            ;;
        --namespace)
            ODF_NAMESPACE="$2"
            shift 2
            ;;
        --full)
            FULL_DIAGNOSTICS=true
            shift
            ;;
        --output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --kvm)
            KVM_MODE=true
            shift
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --node <name>       Check specific node"
            echo "  --namespace <ns>    ODF namespace (default: openshift-storage)"
            echo "  --full              Run full diagnostics"
            echo "  --output <file>     Save output to file"
            echo "  --kvm               Include KVM-specific checks"
            echo "  --help              Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Redirect output if requested
if [[ -n "$OUTPUT_FILE" ]]; then
    exec > >(tee "$OUTPUT_FILE")
    exec 2>&1
fi

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                  ODF Complete Diagnostics                                ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Date: $(date)"
echo "Namespace: $ODF_NAMESPACE"
echo "KVM Mode: $KVM_MODE"
echo "Full Diagnostics: $FULL_DIAGNOSTICS"
echo ""

# Check if logged in
if ! oc whoami &>/dev/null; then
    echo -e "${RED}❌ Not logged into OpenShift${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Logged in as: $(oc whoami)${NC}"
echo ""

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}1. Ceph Cluster Health${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

TOOLS_POD=$(oc get pods -n "$ODF_NAMESPACE" -l app=rook-ceph-tools -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [[ -n "$TOOLS_POD" ]]; then
    echo "Using tools pod: $TOOLS_POD"
    echo ""
    
    oc exec -n "$ODF_NAMESPACE" "$TOOLS_POD" -- ceph status
    
    echo ""
    echo "OSD Status:"
    oc exec -n "$ODF_NAMESPACE" "$TOOLS_POD" -- ceph osd stat
    
    echo ""
    echo "Monitor Status:"
    oc exec -n "$ODF_NAMESPACE" "$TOOLS_POD" -- ceph mon stat
    
    if [[ "$FULL_DIAGNOSTICS" == "true" ]]; then
        echo ""
        echo "PG Status:"
        oc exec -n "$ODF_NAMESPACE" "$TOOLS_POD" -- ceph pg stat
    fi
else
    echo -e "${YELLOW}⚠️  No rook-ceph-tools pod found${NC}"
fi

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}2. Storage Classes${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

oc get storageclass | grep -E "NAME|ceph|ocs"

if [[ "$KVM_MODE" == "true" ]]; then
    echo ""
    echo "Checking for KVM-optimized storage class..."
    if oc get storageclass ocs-storagecluster-ceph-rbd-kvm &>/dev/null; then
        echo -e "${GREEN}✅ KVM-optimized storage class exists${NC}"
        oc get storageclass ocs-storagecluster-ceph-rbd-kvm -o jsonpath='{.parameters.imageFeatures}' | xargs -I {} echo "Image Features: {}"
    else
        echo -e "${YELLOW}⚠️  KVM-optimized storage class not found${NC}"
        echo "   Run: ./odf/scripts/disable-rbd-exclusive-lock.sh"
    fi
fi

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}3. CSI Plugins${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo "RBD CSI Plugins:"
oc get pods -n "$ODF_NAMESPACE" -l app=csi-rbdplugin -o wide

echo ""
echo "CephFS CSI Plugins:"
oc get pods -n "$ODF_NAMESPACE" -l app=csi-cephfsplugin -o wide

# Check for problematic pods
echo ""
NON_RUNNING=$(oc get pods -n "$ODF_NAMESPACE" -l app=csi-rbdplugin --field-selector=status.phase!=Running --no-headers 2>/dev/null | wc -l)
if [[ $NON_RUNNING -gt 0 ]]; then
    echo -e "${RED}⚠️  Found $NON_RUNNING non-running RBD CSI plugin(s)${NC}"
    oc get pods -n "$ODF_NAMESPACE" -l app=csi-rbdplugin --field-selector=status.phase!=Running
else
    echo -e "${GREEN}✅ All RBD CSI plugins running${NC}"
fi

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}4. PVCs Status${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo "All PVCs:"
oc get pvc --all-namespaces -o custom-columns=\
NAMESPACE:.metadata.namespace,\
NAME:.metadata.name,\
STATUS:.status.phase,\
VOLUME:.spec.volumeName,\
CAPACITY:.status.capacity.storage,\
STORAGECLASS:.spec.storageClassName,\
AGE:.metadata.creationTimestamp

PENDING_PVCS=$(oc get pvc --all-namespaces --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
if [[ $PENDING_PVCS -gt 0 ]]; then
    echo ""
    echo -e "${YELLOW}⚠️  Found $PENDING_PVCS pending PVC(s)${NC}"
fi

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [[ -n "$TARGET_NODE" ]] || [[ "$FULL_DIAGNOSTICS" == "true" ]]; then
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}5. Node-Level Diagnostics${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Determine nodes to check
    if [[ -n "$TARGET_NODE" ]]; then
        NODES="$TARGET_NODE"
    else
        NODES=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}')
    fi
    
    for NODE in $NODES; do
        echo ""
        echo "Node: $NODE"
        echo "─────────────────────────────────────────"
        
        echo "  Checking RBD processes..."
        RBD_COUNT=$(oc debug node/$NODE --to-namespace=default -- chroot /host ps aux 2>/dev/null | grep -c "[r]bd" || echo "0")
        echo "    RBD processes: $RBD_COUNT"
        
        echo "  Checking mapped RBD devices..."
        RBD_MAPPED=$(oc debug node/$NODE --to-namespace=default -- chroot /host rbd showmapped 2>/dev/null | tail -n +2 | wc -l || echo "0")
        echo "    Mapped devices: $RBD_MAPPED"
        
        if [[ "$KVM_MODE" == "true" ]]; then
            echo "  Checking kernel hung tasks..."
            HUNG_TASKS=$(oc debug node/$NODE --to-namespace=default -- chroot /host dmesg 2>/dev/null | grep -c "task.*blocked" || echo "0")
            if [[ $HUNG_TASKS -gt 0 ]]; then
                echo -e "    ${RED}⚠️  Found $HUNG_TASKS hung task warnings${NC}"
            else
                echo -e "    ${GREEN}✅ No hung tasks${NC}"
            fi
        fi
        
        if [[ "$FULL_DIAGNOSTICS" == "true" ]]; then
            echo "  CSI socket status..."
            oc debug node/$NODE --to-namespace=default -- chroot /host \
                ls -lh /var/lib/kubelet/plugins/openshift-storage.rbd.csi.ceph.com/ 2>/dev/null | grep sock || echo "    No socket found"
        fi
    done
fi

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [[ "$KVM_MODE" == "true" ]]; then
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}6. KVM-Specific Checks${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    if [[ -n "$TARGET_NODE" ]]; then
        NODE="$TARGET_NODE"
    else
        NODE=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}')
    fi
    
    echo "Checking node: $NODE"
    echo ""
    
    echo "Virtual disk type:"
    oc debug node/$NODE --to-namespace=default -- chroot /host lsblk -o NAME,TYPE 2>/dev/null | head -10
    
    echo ""
    echo "Virtio modules loaded:"
    oc debug node/$NODE --to-namespace=default -- chroot /host lsmod 2>/dev/null | grep virtio
    
    echo ""
    echo "I/O scheduler:"
    oc debug node/$NODE --to-namespace=default -- chroot /host bash -c \
        'for disk in /sys/block/vd*; do [ -d "$disk" ] && echo "$(basename $disk): $(cat $disk/queue/scheduler 2>/dev/null)"; done' 2>/dev/null
fi

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}7. Summary & Recommendations${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Ceph health summary
if [[ -n "$TOOLS_POD" ]]; then
    CEPH_HEALTH=$(oc exec -n "$ODF_NAMESPACE" "$TOOLS_POD" -- ceph health 2>/dev/null | awk '{print $1}')
    if [[ "$CEPH_HEALTH" == "HEALTH_OK" ]]; then
        echo -e "${GREEN}✅ Ceph Cluster: HEALTH_OK${NC}"
    elif [[ "$CEPH_HEALTH" == "HEALTH_WARN" ]]; then
        echo -e "${YELLOW}⚠️  Ceph Cluster: HEALTH_WARN${NC}"
    else
        echo -e "${RED}❌ Ceph Cluster: $CEPH_HEALTH${NC}"
    fi
fi

# CSI plugin summary
TOTAL_RBD=$(oc get pods -n "$ODF_NAMESPACE" -l app=csi-rbdplugin --no-headers 2>/dev/null | wc -l)
RUNNING_RBD=$(oc get pods -n "$ODF_NAMESPACE" -l app=csi-rbdplugin --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
if [[ $TOTAL_RBD -eq $RUNNING_RBD ]]; then
    echo -e "${GREEN}✅ CSI RBD Plugins: $RUNNING_RBD/$TOTAL_RBD running${NC}"
else
    echo -e "${YELLOW}⚠️  CSI RBD Plugins: $RUNNING_RBD/$TOTAL_RBD running${NC}"
fi

# PVC summary  
TOTAL_PVCS=$(oc get pvc --all-namespaces --no-headers 2>/dev/null | wc -l)
BOUND_PVCS=$(oc get pvc --all-namespaces --field-selector=status.phase=Bound --no-headers 2>/dev/null | wc -l)
if [[ $TOTAL_PVCS -eq $BOUND_PVCS ]]; then
    echo -e "${GREEN}✅ PVCs: $BOUND_PVCS/$TOTAL_PVCS bound${NC}"
else
    echo -e "${YELLOW}⚠️  PVCs: $BOUND_PVCS/$TOTAL_PVCS bound${NC}"
fi

# KVM warning
if [[ "$KVM_MODE" == "true" ]]; then
    echo ""
    echo -e "${YELLOW}⚠️  KVM Environment Detected${NC}"
    echo "   Recommendation: Use CephFS or NFS for databases"
    echo "   RBD has known issues in KVM virtual machines"
    echo "   See: odf/docs/KVM-RBD-FINAL-VERDICT.md"
fi

echo ""
echo "─────────────────────────────────────────────────────────────────────────"
echo "Diagnostic complete: $(date)"

if [[ -n "$OUTPUT_FILE" ]]; then
    echo "Output saved to: $OUTPUT_FILE"
fi

echo ""
echo "For more information:"
echo "  • ODF Health: ./odf/scripts/odf-health-check.sh"
echo "  • Fix RBD issues: ./odf/scripts/fix-rbd-kernel-stuck.sh <node>"
echo "  • Network diagnostics: ./odf/scripts/network-diagnostics.sh"
echo "  • Documentation: odf/docs/"


