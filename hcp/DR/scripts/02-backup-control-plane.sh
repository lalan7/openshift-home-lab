#!/bin/bash
# Backup HCP Control Plane
#
# Usage:
#   ./02-backup-control-plane.sh <hosted-cluster-name> [namespace]
#
# Example:
#   ./02-backup-control-plane.sh my-hcp clusters
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/../manifests"

# Arguments
HOSTED_CLUSTER_NAME="${1:-}"
HOSTED_CLUSTER_NAMESPACE="${2:-clusters}"

if [[ -z "${HOSTED_CLUSTER_NAME}" ]]; then
    echo "Usage: $0 <hosted-cluster-name> [namespace]"
    echo ""
    echo "Arguments:"
    echo "  hosted-cluster-name   Name of the HostedCluster resource"
    echo "  namespace             Namespace of HostedCluster (default: clusters)"
    exit 1
fi

# Derive control plane namespace
HOSTED_CONTROL_PLANE_NAMESPACE="${HOSTED_CLUSTER_NAMESPACE}-${HOSTED_CLUSTER_NAME}"

# Generate backup name with timestamp
BACKUP_NAME="hcp-${HOSTED_CLUSTER_NAME}-$(date +%Y%m%d-%H%M%S)"

echo "=== Backing up HCP Control Plane ==="
echo ""
echo "  Hosted Cluster:    ${HOSTED_CLUSTER_NAME}"
echo "  Cluster Namespace: ${HOSTED_CLUSTER_NAMESPACE}"
echo "  CP Namespace:      ${HOSTED_CONTROL_PLANE_NAMESPACE}"
echo "  Backup Name:       ${BACKUP_NAME}"
echo ""

# Verify HostedCluster exists
echo "[1/5] Verifying HostedCluster exists..."
if ! oc get hostedcluster "${HOSTED_CLUSTER_NAME}" -n "${HOSTED_CLUSTER_NAMESPACE}" &>/dev/null; then
    echo "ERROR: HostedCluster '${HOSTED_CLUSTER_NAME}' not found in namespace '${HOSTED_CLUSTER_NAMESPACE}'"
    exit 1
fi
echo "  HostedCluster found"

# Verify control plane namespace exists
echo "[2/5] Verifying control plane namespace..."
if ! oc get namespace "${HOSTED_CONTROL_PLANE_NAMESPACE}" &>/dev/null; then
    echo "ERROR: Control plane namespace '${HOSTED_CONTROL_PLANE_NAMESPACE}' not found"
    exit 1
fi
echo "  Control plane namespace found"

# Verify OADP is ready
echo "[3/5] Verifying OADP is ready..."
DPA_STATUS=$(oc get dpa -n openshift-adp -o jsonpath='{.items[0].status.conditions[?(@.type=="Reconciled")].status}' 2>/dev/null || true)
if [[ "${DPA_STATUS}" != "True" ]]; then
    echo "ERROR: DataProtectionApplication not ready"
    echo "  Run: oc get dpa -n openshift-adp -o yaml"
    exit 1
fi
echo "  OADP is ready"

# Pause HostedCluster reconciliation
echo "[4/5] Pausing HostedCluster reconciliation..."
oc patch hostedcluster "${HOSTED_CLUSTER_NAME}" -n "${HOSTED_CLUSTER_NAMESPACE}" \
    --type=merge -p '{"spec":{"pausedUntil":"true"}}'

# Pause NodePool reconciliation
NODEPOOLS=$(oc get nodepool -n "${HOSTED_CLUSTER_NAMESPACE}" -l hypershift.openshift.io/cluster="${HOSTED_CLUSTER_NAME}" -o name)
for np in ${NODEPOOLS}; do
    echo "  Pausing ${np}..."
    oc patch "${np}" -n "${HOSTED_CLUSTER_NAMESPACE}" \
        --type=merge -p '{"spec":{"pausedUntil":"true"}}'
done

# Create backup
echo "[5/5] Creating backup..."
export BACKUP_NAME
export HOSTED_CLUSTER_NAMESPACE
export HOSTED_CONTROL_PLANE_NAMESPACE

envsubst < "${MANIFEST_DIR}/backup-control-plane.yaml.template" | oc apply -f -

echo ""
echo "=== Backup initiated ==="
echo ""
echo "Monitor backup progress:"
echo "  oc get backup ${BACKUP_NAME} -n openshift-adp -w"
echo ""
echo "Or with velero CLI:"
echo "  velero backup describe ${BACKUP_NAME} --details"
echo ""
echo "When backup completes, resume reconciliation:"
echo "  oc patch hostedcluster ${HOSTED_CLUSTER_NAME} -n ${HOSTED_CLUSTER_NAMESPACE} --type=merge -p '{\"spec\":{\"pausedUntil\":null}}'"
echo ""
