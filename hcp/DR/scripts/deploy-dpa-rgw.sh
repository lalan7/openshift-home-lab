#!/bin/bash
# Deploy DataProtectionApplication with ODF RGW
#
# This script:
#   1. Verifies OBC is ready
#   2. Extracts bucket name
#   3. Deploys the DPA
#   4. Waits for DPA to be ready
#
# Prerequisites:
#   - OADP operator installed
#   - cloud-credentials secret created (run setup-rgw-credentials.sh first)
#
# Usage:
#   ./deploy-dpa-rgw.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/../manifests"
OBC_NAME="oadp-hcp-bucket"
NAMESPACE="openshift-adp"

echo "=== Deploying DataProtectionApplication with ODF RGW ==="

# Verify prerequisites
echo "[1/4] Verifying prerequisites..."

# Check OADP operator
if ! oc get csv -n "${NAMESPACE}" 2>/dev/null | grep -q oadp; then
    echo "ERROR: OADP operator not installed"
    echo "Run: ./01-install-oadp.sh"
    exit 1
fi
echo "  OADP operator: OK"

# Check cloud-credentials secret
if ! oc get secret cloud-credentials -n "${NAMESPACE}" &>/dev/null; then
    echo "ERROR: cloud-credentials secret not found"
    echo "Run: ./setup-rgw-credentials.sh"
    exit 1
fi
echo "  cloud-credentials: OK"

# Get bucket name from OBC
echo "[2/4] Getting bucket name from OBC..."
BUCKET_NAME=$(oc get configmap "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.BUCKET_NAME}' 2>/dev/null || true)

if [[ -z "${BUCKET_NAME}" ]]; then
    echo "ERROR: Could not get bucket name from OBC ConfigMap"
    echo "Ensure OBC is created: oc get obc ${OBC_NAME} -n ${NAMESPACE}"
    exit 1
fi
echo "  Bucket: ${BUCKET_NAME}"

# Deploy DPA
echo "[3/4] Deploying DataProtectionApplication..."
export BUCKET_NAME
envsubst < "${MANIFEST_DIR}/05-dpa-rgw.yaml.template" | oc apply -f -

# Wait for DPA to be ready
echo "[4/4] Waiting for DPA to be ready..."
for i in {1..30}; do
    DPA_STATUS=$(oc get dpa hcp-dpa -n "${NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Reconciled")].status}' 2>/dev/null || true)
    if [[ "${DPA_STATUS}" == "True" ]]; then
        break
    fi
    echo "  Waiting for DPA reconciliation... (${i}/30)"
    sleep 10
done

# Check BackupStorageLocation
BSL_PHASE=$(oc get backupstoragelocation -n "${NAMESPACE}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)

echo ""
echo "=== DPA Deployment Complete ==="
echo ""
echo "DPA Status:"
oc get dpa -n "${NAMESPACE}"
echo ""
echo "BackupStorageLocation:"
oc get backupstoragelocation -n "${NAMESPACE}"
echo ""

if [[ "${BSL_PHASE}" == "Available" ]]; then
    echo "✓ OADP is ready for backups!"
    echo ""
    echo "To backup the HCP cluster:"
    echo "  ./02-backup-control-plane.sh sno-hcp clusters"
else
    echo "⚠ BackupStorageLocation status: ${BSL_PHASE:-Unknown}"
    echo "Check velero pod logs: oc logs -n openshift-adp -l app.kubernetes.io/name=velero"
fi
echo ""
