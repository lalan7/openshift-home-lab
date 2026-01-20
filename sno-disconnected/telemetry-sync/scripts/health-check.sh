#!/bin/bash
# =============================================================================
# health-check.sh - System and API Health Check
# =============================================================================
# Part of: SNO Disconnected Telemetry Sync
# Purpose: Validates cluster, API, and system health before operations
# 
# Usage: ./health-check.sh [config-file]
# 
# Exit codes:
#   0 - All checks passed
#   1 - Critical error (cluster unreachable)
#   2 - Warning (API unavailable but cluster OK)
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-${SCRIPT_DIR}/../config/telemetry-sync.env}"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "[ERROR] Configuration file not found: ${CONFIG_FILE}"
    exit 1
fi
source "${CONFIG_FILE}"

# Export KUBECONFIG for oc commands
export KUBECONFIG

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date -u "+%Y-%m-%d %H:%M:%S UTC")
    
    mkdir -p "${LOG_DIR}"
    echo "[${timestamp}] [HEALTH] [${level}] ${message}" >> "${LOG_DIR}/health-check.log"
    echo "[${level}] ${message}"
}

log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_ok()    { log "OK" "$@"; }

# -----------------------------------------------------------------------------
# Health Checks
# -----------------------------------------------------------------------------
WARNINGS=0
ERRORS=0

check_cluster_connectivity() {
    echo "----------------------------------------"
    echo "Checking cluster connectivity..."
    
    if ! command -v oc &>/dev/null; then
        log_error "oc command not found"
        ERRORS=$((ERRORS + 1))
        return
    fi
    
    if ! oc whoami &>/dev/null; then
        log_error "Cannot connect to cluster (KUBECONFIG: ${KUBECONFIG})"
        ERRORS=$((ERRORS + 1))
        return
    fi
    
    local user=$(oc whoami 2>/dev/null || echo "unknown")
    local context=$(oc whoami --show-context 2>/dev/null || echo "unknown")
    log_ok "Connected as: ${user}"
    log_ok "Context: ${context}"
}

check_insights_operator() {
    echo "----------------------------------------"
    echo "Checking Insights Operator..."
    
    # Check if namespace exists
    if ! oc get namespace openshift-insights &>/dev/null; then
        log_warn "openshift-insights namespace not found"
        WARNINGS=$((WARNINGS + 1))
        return
    fi
    
    # Check deployment
    local replicas=$(oc get deployment insights-operator -n openshift-insights -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    
    if [[ "${replicas}" -ge 1 ]]; then
        log_ok "Insights Operator running (${replicas} replica(s))"
    else
        log_warn "Insights Operator not ready (${replicas} replicas)"
        WARNINGS=$((WARNINGS + 1))
    fi
    
    # Check pod status
    local pod_status=$(oc get pods -n openshift-insights -l app=insights-operator -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Unknown")
    log_info "Pod status: ${pod_status}"
}

check_insights_archives() {
    echo "----------------------------------------"
    echo "Checking Insights archives..."
    
    # Get the Insights Operator pod
    local pod=$(oc get pods -n openshift-insights -l app=insights-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "${pod}" ]]; then
        log_warn "Could not find Insights Operator pod"
        WARNINGS=$((WARNINGS + 1))
        return
    fi
    
    # Check for archives in the pod
    local archives=$(oc exec -n openshift-insights "${pod}" -- ls -1t /var/lib/insights-operator/ 2>/dev/null | grep "\.tar\.gz$" || true)
    
    if [[ -n "${archives}" ]]; then
        local latest=$(echo "${archives}" | head -1)
        log_ok "Insights archive available: ${latest}"
    else
        log_warn "No Insights archives found in operator pod"
        log_info "The operator may not have completed a gather cycle yet"
        WARNINGS=$((WARNINGS + 1))
    fi
}

check_redhat_api() {
    echo "----------------------------------------"
    echo "Checking Red Hat API..."
    
    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 10 \
        "${HEALTH_ENDPOINT}" 2>/dev/null) || response="000"
    
    if [[ "${response}" == "200" ]]; then
        log_ok "Red Hat API reachable (HTTP ${response})"
    elif [[ "${response}" == "000" ]]; then
        log_warn "Red Hat API unreachable (network error)"
        WARNINGS=$((WARNINGS + 1))
    else
        log_warn "Red Hat API returned HTTP ${response}"
        WARNINGS=$((WARNINGS + 1))
    fi
}

check_auth_token() {
    echo "----------------------------------------"
    echo "Checking authentication..."
    
    if [[ -z "${CLOUD_TOKEN:-}" ]]; then
        log_warn "CLOUD_TOKEN not configured"
        WARNINGS=$((WARNINGS + 1))
        return
    fi
    
    # Token format check (base64 encoded user:pass)
    if [[ ${#CLOUD_TOKEN} -lt 20 ]]; then
        log_warn "CLOUD_TOKEN appears too short (may be invalid)"
        WARNINGS=$((WARNINGS + 1))
    else
        log_ok "CLOUD_TOKEN configured (length: ${#CLOUD_TOKEN})"
    fi
}

check_cluster_id() {
    echo "----------------------------------------"
    echo "Checking cluster identity..."
    
    if [[ -n "${CLUSTER_ID:-}" ]]; then
        log_ok "CLUSTER_ID configured: ${CLUSTER_ID}"
    else
        # Try to get from cluster
        local id=$(oc get clusterversion version -o jsonpath='{.spec.clusterID}' 2>/dev/null || echo "")
        if [[ -n "${id}" ]]; then
            log_warn "CLUSTER_ID not in config but available from cluster: ${id}"
            log_warn "Add to config: CLUSTER_ID=\"${id}\""
            WARNINGS=$((WARNINGS + 1))
        else
            log_error "CLUSTER_ID not configured and cannot be determined"
            ERRORS=$((ERRORS + 1))
        fi
    fi
}

check_queue_directories() {
    echo "----------------------------------------"
    echo "Checking queue directories..."
    
    for dir in "${PENDING_DIR}" "${UPLOADED_DIR}" "${FAILED_DIR}" "${LOG_DIR}"; do
        if [[ -d "${dir}" ]]; then
            local count=$(find "${dir}" -type f 2>/dev/null | wc -l)
            log_ok "$(basename "${dir}"): ${count} files"
        else
            log_info "Creating: ${dir}"
            mkdir -p "${dir}"
        fi
    done
}

check_disk_space() {
    echo "----------------------------------------"
    echo "Checking disk space..."
    
    local queue_disk=$(df -P "${QUEUE_DIR}" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
    
    if [[ -n "${queue_disk}" ]]; then
        if [[ ${queue_disk} -gt 90 ]]; then
            log_error "Disk usage critical: ${queue_disk}%"
            ERRORS=$((ERRORS + 1))
        elif [[ ${queue_disk} -gt 80 ]]; then
            log_warn "Disk usage high: ${queue_disk}%"
            WARNINGS=$((WARNINGS + 1))
        else
            log_ok "Disk usage: ${queue_disk}%"
        fi
    fi
}

check_pending_queue() {
    echo "----------------------------------------"
    echo "Checking pending queue..."
    
    local pending_count=$(find "${PENDING_DIR}" -name "*.tar.gz" 2>/dev/null | wc -l)
    local failed_count=$(find "${FAILED_DIR}" -name "*.tar.gz" 2>/dev/null | wc -l)
    
    if [[ ${pending_count} -gt 0 ]]; then
        log_warn "${pending_count} archives pending upload"
        WARNINGS=$((WARNINGS + 1))
    else
        log_ok "No pending archives"
    fi
    
    if [[ ${failed_count} -gt 0 ]]; then
        log_warn "${failed_count} archives in failed queue"
        WARNINGS=$((WARNINGS + 1))
    else
        log_ok "No failed archives"
    fi
}

# -----------------------------------------------------------------------------
# Generate Report
# -----------------------------------------------------------------------------
generate_report() {
    echo ""
    echo "========================================"
    echo "HEALTH CHECK SUMMARY"
    echo "========================================"
    echo "Cluster: ${CLUSTER_NAME}"
    echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "----------------------------------------"
    
    if [[ ${ERRORS} -eq 0 && ${WARNINGS} -eq 0 ]]; then
        echo "Status: ✅ HEALTHY"
        echo "All checks passed"
        return 0
    elif [[ ${ERRORS} -eq 0 ]]; then
        echo "Status: ⚠️  WARNINGS"
        echo "Warnings: ${WARNINGS}"
        return 2
    else
        echo "Status: ❌ UNHEALTHY"
        echo "Errors: ${ERRORS}"
        echo "Warnings: ${WARNINGS}"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    echo "========================================"
    echo "TELEMETRY SYNC - HEALTH CHECK"
    echo "========================================"
    echo ""
    
    check_cluster_connectivity
    check_insights_operator
    check_insights_archives
    check_redhat_api
    check_auth_token
    check_cluster_id
    check_queue_directories
    check_disk_space
    check_pending_queue
    
    generate_report
}

main "$@"

