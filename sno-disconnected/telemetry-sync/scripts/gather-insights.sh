#!/bin/bash
# =============================================================================
# gather-insights.sh - Gather Insights Operator Archive from Disconnected SNO
# =============================================================================
# Part of: SNO Disconnected Telemetry Sync
# Purpose: Copies the latest Insights archive from the operator pod to local queue
# 
# Usage: ./gather-insights.sh [config-file]
#
# Note: The Insights Operator automatically gathers data periodically.
#       This script copies the latest archive for upload to Red Hat.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-${SCRIPT_DIR}/../config/telemetry-sync.env}"

# Source configuration
if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "[ERROR] Configuration file not found: ${CONFIG_FILE}"
    echo "[ERROR] Copy telemetry-sync.env.template to telemetry-sync.env and fill in values"
    exit 1
fi
source "${CONFIG_FILE}"

# Export KUBECONFIG for oc commands
export KUBECONFIG

# -----------------------------------------------------------------------------
# Logging Functions
# -----------------------------------------------------------------------------
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date -u "+%Y-%m-%d %H:%M:%S UTC")
    
    # Create log directory if needed
    mkdir -p "${LOG_DIR}"
    
    # Log to file
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_DIR}/gather.log"
    
    # Log to stderr based on level (stderr so function return values work)
    case "${LOG_LEVEL}" in
        DEBUG) echo "[${level}] ${message}" >&2 ;;
        INFO)  [[ "${level}" != "DEBUG" ]] && echo "[${level}] ${message}" >&2 || true ;;
        WARN)  [[ "${level}" =~ ^(WARN|ERROR)$ ]] && echo "[${level}] ${message}" >&2 || true ;;
        ERROR) [[ "${level}" == "ERROR" ]] && echo "[${level}] ${message}" >&2 || true ;;
    esac
}

log_debug() { log "DEBUG" "$@"; }
log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# -----------------------------------------------------------------------------
# Cleanup Function
# -----------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    log_debug "Cleanup triggered with exit code: ${exit_code}"
    
    # Clean up temp files
    if [[ -d "${TMP_DIR}" ]]; then
        rm -rf "${TMP_DIR}"/* 2>/dev/null || true
    fi
    
    exit ${exit_code}
}

trap cleanup EXIT

# -----------------------------------------------------------------------------
# Validation Functions
# -----------------------------------------------------------------------------
validate_prerequisites() {
    log_info "Validating prerequisites..."
    
    # Check oc command
    if ! command -v oc &>/dev/null; then
        log_error "oc command not found. Install OpenShift CLI."
        exit 1
    fi
    
    # Check cluster connectivity
    if ! oc whoami &>/dev/null; then
        log_error "Cannot connect to cluster. Check KUBECONFIG: ${KUBECONFIG}"
        exit 1
    fi
    
    # Verify we're talking to the right cluster
    local current_context=$(oc whoami --show-context 2>/dev/null || echo "unknown")
    log_info "Connected to context: ${current_context}"
    
    # Check Insights Operator is running
    if ! oc get deployment insights-operator -n openshift-insights &>/dev/null; then
        log_error "Insights Operator not found in openshift-insights namespace"
        exit 1
    fi
    
    # Create directories
    mkdir -p "${PENDING_DIR}" "${UPLOADED_DIR}" "${FAILED_DIR}" "${TMP_DIR}" "${LOG_DIR}"
    
    log_info "Prerequisites validated successfully"
}

# -----------------------------------------------------------------------------
# Get Cluster ID
# -----------------------------------------------------------------------------
get_cluster_id() {
    if [[ -n "${CLUSTER_ID}" ]]; then
        echo "${CLUSTER_ID}"
        return
    fi
    
    local id=$(oc get clusterversion version -o jsonpath='{.spec.clusterID}' 2>/dev/null)
    if [[ -z "${id}" ]]; then
        log_error "Could not determine cluster ID"
        exit 1
    fi
    echo "${id}"
}

# -----------------------------------------------------------------------------
# Get Insights Operator Pod
# -----------------------------------------------------------------------------
get_insights_pod() {
    local pod=$(oc get pods -n openshift-insights -l app=insights-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [[ -z "${pod}" ]]; then
        log_error "Could not find Insights Operator pod"
        exit 1
    fi
    
    echo "${pod}"
}

# -----------------------------------------------------------------------------
# Copy Archive from Insights Operator Pod
# -----------------------------------------------------------------------------
copy_archive() {
    log_info "Copying archive from Insights Operator pod..."
    
    local pod=$(get_insights_pod)
    log_debug "Insights Operator pod: ${pod}"
    
    # List available archives
    local archives=$(oc exec -n openshift-insights "${pod}" -- ls -1t /var/lib/insights-operator/ 2>/dev/null | grep "\.tar\.gz$" || true)
    
    if [[ -z "${archives}" ]]; then
        log_error "No archive found in Insights Operator pod"
        log_info "The Insights Operator may not have completed a gather cycle yet."
        log_info "Wait a few minutes and try again, or check operator logs:"
        log_info "  oc logs -n openshift-insights deployment/insights-operator"
        exit 1
    fi
    
    # Get the latest archive
    local latest_archive=$(echo "${archives}" | head -1)
    local remote_path="/var/lib/insights-operator/${latest_archive}"
    
    log_info "Found archive: ${latest_archive}"
    
    # Check if we already have this archive in pending or uploaded
    local cluster_id=$(get_cluster_id)
    if find "${PENDING_DIR}" "${UPLOADED_DIR}" -name "*${latest_archive}*" 2>/dev/null | grep -q .; then
        log_warn "Archive ${latest_archive} already exists in queue"
        log_warn "Skipping to avoid duplicates"
        exit 0
    fi
    
    # Generate local filename with cluster ID prefix
    local timestamp=$(date -u "+%Y%m%d-%H%M%S")
    local local_filename="${cluster_id}-${latest_archive}"
    local local_archive="${TMP_DIR}/${local_filename}"
    
    # Copy archive from pod (suppress tar messages which go to stdout/stderr)
    log_info "Copying from pod to local..."
    oc cp -n openshift-insights "${pod}:${remote_path}" "${local_archive}" >/dev/null 2>&1
    
    if [[ ! -f "${local_archive}" ]]; then
        log_error "Failed to copy archive from pod"
        exit 1
    fi
    
    local size=$(du -h "${local_archive}" | cut -f1)
    log_info "Archive copied successfully: ${local_filename} (${size})"
    
    echo "${local_archive}"
}

# -----------------------------------------------------------------------------
# Move Archive to Pending Queue
# -----------------------------------------------------------------------------
queue_archive() {
    local archive="$1"
    local filename=$(basename "${archive}")
    local dest="${PENDING_DIR}/${filename}"
    
    log_info "Moving archive to pending queue: ${dest}"
    
    mv "${archive}" "${dest}"
    
    # Create metadata file for tracking
    local meta_file="${dest}.meta"
    local cluster_id=$(get_cluster_id)
    cat > "${meta_file}" <<EOF
{
    "cluster_id": "${cluster_id}",
    "cluster_name": "${CLUSTER_NAME}",
    "gathered_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "archive_file": "${filename}",
    "retry_count": 0,
    "last_attempt": null,
    "status": "pending"
}
EOF
    
    log_info "Archive queued successfully"
    echo "${dest}"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    log_info "=========================================="
    log_info "Starting Insights Gather Operation"
    log_info "Cluster: ${CLUSTER_NAME}"
    log_info "=========================================="
    
    validate_prerequisites
    
    local cluster_id=$(get_cluster_id)
    log_info "Cluster ID: ${cluster_id}"
    
    local archive=$(copy_archive)
    
    # If copy_archive exited with 0 but no archive (duplicate), exit gracefully
    if [[ -z "${archive}" ]]; then
        log_info "No new archive to queue"
        exit 0
    fi
    
    local queued=$(queue_archive "${archive}")
    
    log_info "=========================================="
    log_info "Gather operation completed successfully"
    log_info "Archive queued: ${queued}"
    log_info "=========================================="
    
    # Output path for chaining with upload script
    echo "${queued}"
}

main "$@"
