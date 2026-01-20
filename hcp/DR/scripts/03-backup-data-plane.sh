#!/bin/bash
# Backup Data Plane Workloads (Optional)
#
# This script backs up application workloads running on the hosted cluster.
# Requires OADP to be installed on the hosted cluster itself.
#
# Usage:
#   ./03-backup-data-plane.sh <namespace> [kubeconfig]
#
# Example:
#   ./03-backup-data-plane.sh my-app /path/to/hosted-cluster-kubeconfig
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/../manifests"

# Arguments
APP_NAMESPACE="${1:-}"
HOSTED_KUBECONFIG="${2:-}"

if [[ -z "${APP_NAMESPACE}" ]]; then
    echo "Usage: $0 <namespace> [kubeconfig]"
    echo ""
    echo "Arguments:"
    echo "  namespace     Application namespace to backup"
    echo "  kubeconfig    Path to hosted cluster kubeconfig (optional)"
    echo ""
    echo "Note: This backs up workloads on the HOSTED cluster, not management cluster."
    echo "      OADP must be installed on the hosted cluster."
    exit 1
fi

# Set kubeconfig if provided
if [[ -n "${HOSTED_KUBECONFIG}" ]]; then
    export KUBECONFIG="${HOSTED_KUBECONFIG}"
    echo "Using kubeconfig: ${KUBECONFIG}"
fi

# Generate backup name
BACKUP_NAME="data-plane-${APP_NAMESPACE}-$(date +%Y%m%d-%H%M%S)"

echo "=== Backing up Data Plane Workload ==="
echo ""
echo "  Namespace:   ${APP_NAMESPACE}"
echo "  Backup Name: ${BACKUP_NAME}"
echo ""

# Verify namespace exists
echo "[1/3] Verifying namespace exists..."
if ! oc get namespace "${APP_NAMESPACE}" &>/dev/null; then
    echo "ERROR: Namespace '${APP_NAMESPACE}' not found"
    exit 1
fi
echo "  Namespace found"

# Verify OADP is ready on hosted cluster
echo "[2/3] Verifying OADP is ready on hosted cluster..."
DPA_STATUS=$(oc get dpa -n openshift-adp -o jsonpath='{.items[0].status.conditions[?(@.type=="Reconciled")].status}' 2>/dev/null || true)
if [[ "${DPA_STATUS}" != "True" ]]; then
    echo "ERROR: DataProtectionApplication not ready on hosted cluster"
    echo "  OADP must be installed on the hosted cluster to backup data plane workloads."
    exit 1
fi
echo "  OADP is ready"

# Create backup
echo "[3/3] Creating backup..."
export BACKUP_NAME
export APP_NAMESPACE

envsubst < "${MANIFEST_DIR}/backup-data-plane.yaml.template" | oc apply -f -

echo ""
echo "=== Backup initiated ==="
echo ""
echo "Monitor backup progress:"
echo "  oc get backup ${BACKUP_NAME} -n openshift-adp -w"
echo ""
