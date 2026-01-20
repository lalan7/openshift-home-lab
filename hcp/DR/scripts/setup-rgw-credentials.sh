#!/bin/bash
# Setup OADP Credentials from ODF RGW ObjectBucketClaim
#
# This script extracts credentials from the OBC and creates
# the cloud-credentials secret required by OADP/Velero.
#
# Prerequisites:
#   - ObjectBucketClaim 'oadp-hcp-bucket' created in openshift-adp namespace
#   - oc CLI logged in as cluster-admin
#
# Usage:
#   ./setup-rgw-credentials.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/../manifests"
OBC_NAME="oadp-hcp-bucket"
NAMESPACE="openshift-adp"

echo "=== Setting up OADP Credentials from ODF RGW ==="

# Verify cluster access
echo "[1/5] Verifying cluster access..."
if ! oc whoami &>/dev/null; then
    echo "ERROR: Not logged into OpenShift cluster"
    exit 1
fi

# Check if OBC exists and is bound
echo "[2/5] Checking ObjectBucketClaim status..."
OBC_STATUS=$(oc get obc "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)

if [[ -z "${OBC_STATUS}" ]]; then
    echo "ObjectBucketClaim '${OBC_NAME}' not found. Creating it..."
    oc apply -f "${MANIFEST_DIR}/oadp-rgw-bucket.yaml"
    
    echo "Waiting for OBC to be bound (timeout: 120s)..."
    for i in {1..24}; do
        OBC_STATUS=$(oc get obc "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [[ "${OBC_STATUS}" == "Bound" ]]; then
            break
        fi
        echo "  Waiting... (${i}/24) - Status: ${OBC_STATUS:-Pending}"
        sleep 5
    done
fi

if [[ "${OBC_STATUS}" != "Bound" ]]; then
    echo "ERROR: OBC is not bound (status: ${OBC_STATUS})"
    echo "Check RGW status: oc get pods -n openshift-storage | grep rgw"
    exit 1
fi
echo "  OBC is bound"

# Extract credentials from OBC secret
echo "[3/5] Extracting credentials from OBC..."
ACCESS_KEY=$(oc get secret "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
SECRET_KEY=$(oc get secret "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)

if [[ -z "${ACCESS_KEY}" ]] || [[ -z "${SECRET_KEY}" ]]; then
    echo "ERROR: Failed to extract credentials from OBC secret"
    exit 1
fi
echo "  Credentials extracted"

# Get bucket name
echo "[4/5] Getting bucket name..."
BUCKET_NAME=$(oc get configmap "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.BUCKET_NAME}')
echo "  Bucket: ${BUCKET_NAME}"

# Create cloud-credentials secret for OADP
echo "[5/5] Creating cloud-credentials secret..."

# Delete existing secret if present
oc delete secret cloud-credentials -n "${NAMESPACE}" --ignore-not-found

# Create new secret with Velero format
oc create secret generic cloud-credentials -n "${NAMESPACE}" \
    --from-literal=cloud="[default]
aws_access_key_id=${ACCESS_KEY}
aws_secret_access_key=${SECRET_KEY}"

echo ""
echo "=== Credentials Setup Complete ==="
echo ""
echo "Bucket Name: ${BUCKET_NAME}"
echo "S3 Endpoint: https://rook-ceph-rgw-ocs-storagecluster-cephobjectstore.openshift-storage.svc:443"
echo ""
echo "Next step - Deploy DataProtectionApplication:"
echo "  export BUCKET_NAME=\"${BUCKET_NAME}\""
echo "  envsubst < ${MANIFEST_DIR}/05-dpa-rgw.yaml.template | oc apply -f -"
echo ""
echo "Or use the combined script:"
echo "  ./deploy-dpa-rgw.sh"
echo ""
