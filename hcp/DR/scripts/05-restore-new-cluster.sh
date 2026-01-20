#!/bin/bash
# Restore HCP to New Management Cluster
#
# Use this when:
#   - Original management cluster is unrecoverable
#   - Migrating hosted clusters to new management cluster
#   - Management cluster upgrade failed
#
# Prerequisites:
#   - New management cluster with HyperShift Operator installed
#   - OADP installed and configured with same S3 storage
#   - External DNS configured (required for seamless failover)
#
# Usage:
#   ./05-restore-new-cluster.sh <backup-name>
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/../manifests"

BACKUP_NAME="${1:-}"

if [[ -z "${BACKUP_NAME}" ]]; then
    echo "Usage: $0 <backup-name>"
    echo ""
    echo "List available backups:"
    echo "  oc get backup -n openshift-adp"
    exit 1
fi

RESTORE_NAME="restore-${BACKUP_NAME}-$(date +%Y%m%d-%H%M%S)"

echo "=== Restoring HCP to New Management Cluster ==="
echo ""
echo "  Backup Name:  ${BACKUP_NAME}"
echo "  Restore Name: ${RESTORE_NAME}"
echo ""

# Verify we're on the new management cluster
echo "[1/6] Verifying cluster context..."
CONTEXT=$(oc whoami --show-context)
echo "  Current context: ${CONTEXT}"
echo ""
read -p "Is this the NEW management cluster? (yes/no): " CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
    echo "Please switch to the new management cluster first."
    exit 0
fi

# Verify HyperShift Operator is installed
echo "[2/6] Verifying HyperShift Operator..."
if ! oc get deployment operator -n hypershift &>/dev/null; then
    echo "ERROR: HyperShift Operator not found on this cluster"
    echo "  Install the HyperShift Operator first"
    exit 1
fi
echo "  HyperShift Operator found"

# Verify OADP is ready
echo "[3/6] Verifying OADP is ready..."
DPA_STATUS=$(oc get dpa -n openshift-adp -o jsonpath='{.items[0].status.conditions[?(@.type=="Reconciled")].status}' 2>/dev/null || true)
if [[ "${DPA_STATUS}" != "True" ]]; then
    echo "ERROR: DataProtectionApplication not ready"
    echo "  Ensure OADP is configured with the same S3 storage as source cluster"
    exit 1
fi
echo "  OADP is ready"

# Verify backup exists
echo "[4/6] Verifying backup exists..."
BACKUP_PHASE=$(oc get backup "${BACKUP_NAME}" -n openshift-adp -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [[ -z "${BACKUP_PHASE}" ]]; then
    echo "ERROR: Backup '${BACKUP_NAME}' not found"
    echo ""
    echo "If the backup was created on another cluster, ensure:"
    echo "  1. OADP BackupStorageLocation points to same S3 bucket"
    echo "  2. Run: velero backup get --show-labels"
    exit 1
fi

if [[ "${BACKUP_PHASE}" != "Completed" ]]; then
    echo "ERROR: Backup '${BACKUP_NAME}' is not completed (phase: ${BACKUP_PHASE})"
    exit 1
fi
echo "  Backup verified (phase: ${BACKUP_PHASE})"

# Get namespaces from backup
BACKUP_NAMESPACES=$(oc get backup "${BACKUP_NAME}" -n openshift-adp -o jsonpath='{.spec.includedNamespaces[*]}')
echo "  Namespaces in backup: ${BACKUP_NAMESPACES}"

# Create required namespaces
echo "[5/6] Creating namespaces..."
for ns in ${BACKUP_NAMESPACES}; do
    if ! oc get namespace "${ns}" &>/dev/null; then
        echo "  Creating namespace: ${ns}"
        oc create namespace "${ns}" || true
    fi
done

# Create restore
echo "[6/6] Creating restore..."
export RESTORE_NAME
export BACKUP_NAME

envsubst < "${MANIFEST_DIR}/restore.yaml.template" | oc apply -f -

echo ""
echo "=== Restore initiated ==="
echo ""
echo "Monitor restore progress:"
echo "  oc get restore ${RESTORE_NAME} -n openshift-adp -w"
echo ""
echo "After restore completes:"
echo ""
echo "  1. Start HostedCluster reconciliation:"
echo "     oc patch hostedcluster <name> -n <namespace> --type=merge -p '{\"spec\":{\"pausedUntil\":null}}'"
echo ""
echo "  2. Start NodePool reconciliation:"
echo "     oc patch nodepool <name> -n <namespace> --type=merge -p '{\"spec\":{\"pausedUntil\":null}}'"
echo ""
echo "  3. Verify hosted cluster is available:"
echo "     oc get hostedcluster -A"
echo ""
echo "  4. Delete resources from OLD management cluster (if accessible):"
echo "     oc delete hostedcluster <name> -n <namespace>"
echo ""
echo "IMPORTANT: Only one management cluster can control a hosted cluster at a time."
echo "           Ensure the old cluster resources are deleted after restore succeeds."
echo ""
