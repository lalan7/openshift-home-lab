#!/bin/bash
# Restore HCP to Same Management Cluster
#
# Use this when:
#   - Control plane data was corrupted
#   - Need to rollback to previous state
#   - Management cluster is still operational
#
# Usage:
#   ./04-restore-same-cluster.sh <backup-name>
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

echo "=== Restoring HCP from Backup ==="
echo ""
echo "  Backup Name:  ${BACKUP_NAME}"
echo "  Restore Name: ${RESTORE_NAME}"
echo ""

# Verify backup exists and is completed
echo "[1/4] Verifying backup exists..."
BACKUP_PHASE=$(oc get backup "${BACKUP_NAME}" -n openshift-adp -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [[ -z "${BACKUP_PHASE}" ]]; then
    echo "ERROR: Backup '${BACKUP_NAME}' not found"
    echo ""
    echo "Available backups:"
    oc get backup -n openshift-adp
    exit 1
fi

if [[ "${BACKUP_PHASE}" != "Completed" ]]; then
    echo "ERROR: Backup '${BACKUP_NAME}' is not completed (phase: ${BACKUP_PHASE})"
    exit 1
fi
echo "  Backup verified (phase: ${BACKUP_PHASE})"

# Get namespaces from backup
echo "[2/4] Getting backup details..."
BACKUP_NAMESPACES=$(oc get backup "${BACKUP_NAME}" -n openshift-adp -o jsonpath='{.spec.includedNamespaces[*]}')
echo "  Namespaces in backup: ${BACKUP_NAMESPACES}"

# Confirm restore
echo ""
echo "WARNING: This will restore resources from backup '${BACKUP_NAME}'"
echo "         Existing resources may be overwritten."
echo ""
read -p "Continue with restore? (yes/no): " CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
    echo "Restore cancelled"
    exit 0
fi

# Create restore
echo "[3/4] Creating restore..."
export RESTORE_NAME
export BACKUP_NAME

envsubst < "${MANIFEST_DIR}/restore.yaml.template" | oc apply -f -

# Wait for restore
echo "[4/4] Waiting for restore to complete..."
echo "  This may take several minutes..."

for i in {1..60}; do
    RESTORE_PHASE=$(oc get restore "${RESTORE_NAME}" -n openshift-adp -o jsonpath='{.status.phase}' 2>/dev/null || true)
    
    if [[ "${RESTORE_PHASE}" == "Completed" ]]; then
        echo ""
        echo "=== Restore completed successfully ==="
        break
    elif [[ "${RESTORE_PHASE}" == "Failed" ]] || [[ "${RESTORE_PHASE}" == "PartiallyFailed" ]]; then
        echo ""
        echo "ERROR: Restore failed (phase: ${RESTORE_PHASE})"
        echo "Check restore details:"
        echo "  oc describe restore ${RESTORE_NAME} -n openshift-adp"
        exit 1
    fi
    
    echo "  Restore in progress... (phase: ${RESTORE_PHASE:-Pending}, ${i}/60)"
    sleep 10
done

echo ""
echo "Post-restore steps:"
echo "  1. Resume HostedCluster reconciliation:"
echo "     oc patch hostedcluster <name> -n <namespace> --type=merge -p '{\"spec\":{\"pausedUntil\":null}}'"
echo ""
echo "  2. Resume NodePool reconciliation:"
echo "     oc patch nodepool <name> -n <namespace> --type=merge -p '{\"spec\":{\"pausedUntil\":null}}'"
echo ""
echo "  3. Verify cluster health:"
echo "     oc get hostedcluster -A"
echo "     oc get nodepool -A"
echo ""
