#!/bin/bash
# Verify HCP Backup Integrity
#
# Usage:
#   ./verify-backup.sh [backup-name]
#
# If no backup name provided, lists all backups with status.
#
set -euo pipefail

BACKUP_NAME="${1:-}"

echo "=== HCP Backup Verification ==="
echo ""

# Verify OADP is ready
echo "[Checking OADP Status]"
DPA_STATUS=$(oc get dpa -n openshift-adp -o jsonpath='{.items[0].status.conditions[?(@.type=="Reconciled")].status}' 2>/dev/null || true)
if [[ "${DPA_STATUS}" == "True" ]]; then
    echo "  ✓ DataProtectionApplication is ready"
else
    echo "  ✗ DataProtectionApplication is NOT ready"
fi

# Check BackupStorageLocation
BSL_PHASE=$(oc get backupstoragelocation -n openshift-adp -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
if [[ "${BSL_PHASE}" == "Available" ]]; then
    echo "  ✓ BackupStorageLocation is available"
else
    echo "  ✗ BackupStorageLocation status: ${BSL_PHASE:-Unknown}"
fi

echo ""

if [[ -z "${BACKUP_NAME}" ]]; then
    # List all backups
    echo "[All Backups]"
    echo ""
    oc get backup -n openshift-adp -o custom-columns=\
'NAME:.metadata.name,STATUS:.status.phase,STARTED:.status.startTimestamp,COMPLETED:.status.completionTimestamp,ERRORS:.status.errors,WARNINGS:.status.warnings'
    echo ""
    echo "To verify a specific backup, run:"
    echo "  $0 <backup-name>"
else
    # Verify specific backup
    echo "[Backup: ${BACKUP_NAME}]"
    echo ""
    
    # Check if backup exists
    if ! oc get backup "${BACKUP_NAME}" -n openshift-adp &>/dev/null; then
        echo "ERROR: Backup '${BACKUP_NAME}' not found"
        exit 1
    fi
    
    # Get backup details
    PHASE=$(oc get backup "${BACKUP_NAME}" -n openshift-adp -o jsonpath='{.status.phase}')
    STARTED=$(oc get backup "${BACKUP_NAME}" -n openshift-adp -o jsonpath='{.status.startTimestamp}')
    COMPLETED=$(oc get backup "${BACKUP_NAME}" -n openshift-adp -o jsonpath='{.status.completionTimestamp}')
    ERRORS=$(oc get backup "${BACKUP_NAME}" -n openshift-adp -o jsonpath='{.status.errors}')
    WARNINGS=$(oc get backup "${BACKUP_NAME}" -n openshift-adp -o jsonpath='{.status.warnings}')
    NAMESPACES=$(oc get backup "${BACKUP_NAME}" -n openshift-adp -o jsonpath='{.spec.includedNamespaces[*]}')
    
    echo "  Status:     ${PHASE}"
    echo "  Started:    ${STARTED}"
    echo "  Completed:  ${COMPLETED}"
    echo "  Errors:     ${ERRORS:-0}"
    echo "  Warnings:   ${WARNINGS:-0}"
    echo "  Namespaces: ${NAMESPACES}"
    echo ""
    
    # Check backup contents
    echo "[Backup Contents]"
    ITEMS=$(oc get backup "${BACKUP_NAME}" -n openshift-adp -o jsonpath='{.status.progress.itemsBackedUp}')
    TOTAL=$(oc get backup "${BACKUP_NAME}" -n openshift-adp -o jsonpath='{.status.progress.totalItems}')
    echo "  Items backed up: ${ITEMS:-0}/${TOTAL:-0}"
    echo ""
    
    # Volume snapshots (legacy)
    echo "[Volume Snapshots]"
    VOLUMES=$(oc get backup "${BACKUP_NAME}" -n openshift-adp -o jsonpath='{.status.volumeSnapshotsAttempted}')
    VOLUMES_COMPLETED=$(oc get backup "${BACKUP_NAME}" -n openshift-adp -o jsonpath='{.status.volumeSnapshotsCompleted}')
    echo "  Volume snapshots: ${VOLUMES_COMPLETED:-0}/${VOLUMES:-0}"
    echo ""
    
    # CSI Data Mover (DataUploads)
    echo "[CSI Data Mover]"
    DATAUPLOADS=$(oc get dataupload -n openshift-adp -l velero.io/backup-name="${BACKUP_NAME}" --no-headers 2>/dev/null | wc -l || echo "0")
    if [[ "${DATAUPLOADS}" -gt 0 ]]; then
        oc get dataupload -n openshift-adp -l velero.io/backup-name="${BACKUP_NAME}" \
            -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,BYTES:.status.progress.bytesDone' 2>/dev/null
        DATAUPLOADS_COMPLETED=$(oc get dataupload -n openshift-adp -l velero.io/backup-name="${BACKUP_NAME}" \
            -o jsonpath='{.items[?(@.status.phase=="Completed")].metadata.name}' 2>/dev/null | wc -w || echo "0")
        echo "  DataUploads completed: ${DATAUPLOADS_COMPLETED}/${DATAUPLOADS}"
    else
        echo "  No CSI data mover uploads (using legacy snapshots or no PVCs)"
    fi
    echo ""
    
    # Validation result
    if [[ "${PHASE}" == "Completed" ]] && [[ "${ERRORS:-0}" == "0" ]]; then
        echo "✓ Backup is valid and can be used for restore"
    elif [[ "${PHASE}" == "Completed" ]]; then
        echo "⚠ Backup completed with ${ERRORS} errors - review before restore"
    else
        echo "✗ Backup is not complete (status: ${PHASE})"
    fi
fi

echo ""
