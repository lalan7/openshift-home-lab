#!/bin/bash
# Install OADP Operator on Management Cluster
#
# Prerequisites:
#   - oc CLI logged in as cluster-admin
#   - Access to Red Hat Operators catalog
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/../manifests"

echo "=== Installing OADP Operator for HCP Disaster Recovery ==="

# Verify cluster access
echo "[1/5] Verifying cluster access..."
if ! oc whoami &>/dev/null; then
    echo "ERROR: Not logged into OpenShift cluster"
    exit 1
fi

CONTEXT=$(oc whoami --show-context)
echo "  Current context: ${CONTEXT}"

# Create namespace
echo "[2/5] Creating openshift-adp namespace..."
oc apply -f "${MANIFEST_DIR}/01-oadp-namespace.yaml"

# Wait for namespace
oc wait --for=jsonpath='{.status.phase}'=Active namespace/openshift-adp --timeout=30s

# Create OperatorGroup
echo "[3/5] Creating OperatorGroup..."
oc apply -f "${MANIFEST_DIR}/02-oadp-operatorgroup.yaml"

# Create Subscription
echo "[4/5] Creating OADP Subscription..."
oc apply -f "${MANIFEST_DIR}/03-oadp-subscription.yaml"

# Wait for operator to be ready
echo "[5/5] Waiting for OADP Operator to be ready..."
echo "  This may take a few minutes..."

# Wait for CSV to be created
for i in {1..30}; do
    CSV=$(oc get csv -n openshift-adp -o name 2>/dev/null | grep oadp || true)
    if [[ -n "${CSV}" ]]; then
        break
    fi
    echo "  Waiting for CSV to be created... (${i}/30)"
    sleep 10
done

if [[ -z "${CSV}" ]]; then
    echo "ERROR: OADP CSV not created after 5 minutes"
    exit 1
fi

# Wait for CSV to succeed
oc wait --for=jsonpath='{.status.phase}'=Succeeded "${CSV}" -n openshift-adp --timeout=300s

echo ""
echo "=== OADP Operator installed successfully ==="
echo ""
echo "Next steps:"
echo "  1. Configure S3 credentials:"
echo "     cp ${MANIFEST_DIR}/04-credentials-secret.yaml.template ${MANIFEST_DIR}/04-credentials-secret.yaml"
echo "     # Edit with your S3 credentials"
echo "     oc apply -f ${MANIFEST_DIR}/04-credentials-secret.yaml"
echo ""
echo "  2. Deploy DataProtectionApplication:"
echo "     export S3_BUCKET=hcp-backups"
echo "     export S3_ENDPOINT=https://s3.example.com"
echo "     export S3_REGION=us-east-1"
echo "     envsubst < ${MANIFEST_DIR}/05-dpa.yaml.template | oc apply -f -"
echo ""
