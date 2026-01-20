#!/bin/bash
# =============================================================================
# process-queue.sh - Main Orchestrator for Telemetry Sync
# =============================================================================
# Part of: SNO Disconnected Telemetry Sync
# Purpose: Coordinates gather and upload operations, runs as daily job
# 
# Usage: ./process-queue.sh [config-file]
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
    echo "[ERROR] Copy telemetry-sync.env.template to telemetry-sync.env"
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
    
    mkdir -p "${LOG_DIR}"
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_DIR}/telemetry-sync.log"
    
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
# Lock Management (prevent concurrent runs)
# -----------------------------------------------------------------------------
LOCK_FILE="${QUEUE_DIR}/.telemetry-sync.lock"

acquire_lock() {
    mkdir -p "${QUEUE_DIR}"
    
    # Check for stale lock (older than 1 hour)
    if [[ -f "${LOCK_FILE}" ]]; then
        local lock_age=$(( $(date +%s) - $(stat -c %Y "${LOCK_FILE}" 2>/dev/null || stat -f %m "${LOCK_FILE}" 2>/dev/null || echo 0) ))
        if [[ ${lock_age} -gt 3600 ]]; then
            log_warn "Removing stale lock file (age: ${lock_age}s)"
            rm -f "${LOCK_FILE}"
        else
            log_error "Another instance is running (lock file exists: ${LOCK_FILE})"
            exit 1
        fi
    fi
    
    echo $$ > "${LOCK_FILE}"
    log_debug "Lock acquired: ${LOCK_FILE}"
}

release_lock() {
    rm -f "${LOCK_FILE}"
    log_debug "Lock released"
}

trap release_lock EXIT

# -----------------------------------------------------------------------------
# Send Slack Notification
# -----------------------------------------------------------------------------
send_notification() {
    local level="$1"
    local message="$2"
    
    if [[ "${SLACK_ENABLED}" != "true" ]]; then
        return
    fi
    
    if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
        return
    fi
    
    local emoji="📊"
    local color="#36a64f"
    case "${level}" in
        success) emoji="✅"; color="#36a64f" ;;
        warning) emoji="⚠️"; color="#daa038" ;;
        error)   emoji="❌"; color="#dc3545" ;;
        info)    emoji="ℹ️"; color="#17a2b8" ;;
    esac
    
    local payload=$(cat <<EOF
{
    "attachments": [{
        "color": "${color}",
        "title": "${emoji} Telemetry Sync - ${CLUSTER_NAME}",
        "text": "${message}",
        "footer": "SNO Disconnected Telemetry Sync",
        "ts": $(date +%s)
    }]
}
EOF
)
    
    curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${SLACK_WEBHOOK_URL}" &>/dev/null || true
}

# -----------------------------------------------------------------------------
# Queue Status Check
# -----------------------------------------------------------------------------
check_queue_status() {
    local pending_count=$(find "${PENDING_DIR}" -name "*.tar.gz" 2>/dev/null | wc -l)
    local failed_count=$(find "${FAILED_DIR}" -name "*.tar.gz" 2>/dev/null | wc -l)
    
    log_info "Queue status: ${pending_count} pending, ${failed_count} failed"
    
    # Alert if too many pending
    if [[ ${pending_count} -ge ${ALERT_QUEUE_THRESHOLD:-3} ]]; then
        log_warn "Queue threshold exceeded: ${pending_count} pending archives"
        send_notification "warning" "Queue threshold exceeded: ${pending_count} pending archives waiting for upload"
    fi
    
    echo "${pending_count}"
}

# -----------------------------------------------------------------------------
# Run Gather Operation
# -----------------------------------------------------------------------------
run_gather() {
    log_info "Starting gather operation..."
    
    local gather_script="${SCRIPT_DIR}/gather-insights.sh"
    
    if [[ ! -x "${gather_script}" ]]; then
        log_error "Gather script not found or not executable: ${gather_script}"
        return 1
    fi
    
    local output
    local exit_code=0
    
    output=$("${gather_script}" "${CONFIG_FILE}" 2>&1) || exit_code=$?
    
    if [[ ${exit_code} -ne 0 ]]; then
        log_error "Gather operation failed (exit: ${exit_code})"
        log_error "Output: ${output}"
        send_notification "error" "Gather operation failed: ${output}"
        return 1
    fi
    
    log_info "Gather operation completed successfully"
    return 0
}

# -----------------------------------------------------------------------------
# Run Upload Operation
# -----------------------------------------------------------------------------
run_upload() {
    log_info "Starting upload operation..."
    
    local upload_script="${SCRIPT_DIR}/upload-insights.sh"
    
    if [[ ! -x "${upload_script}" ]]; then
        log_error "Upload script not found or not executable: ${upload_script}"
        return 1
    fi
    
    local output
    local exit_code=0
    
    output=$("${upload_script}" "" "${CONFIG_FILE}" 2>&1) || exit_code=$?
    
    if [[ ${exit_code} -ne 0 ]]; then
        log_warn "Upload operation completed with errors (exit: ${exit_code})"
        # Don't fail entirely - retries will handle pending items
        return 0
    fi
    
    log_info "Upload operation completed successfully"
    return 0
}

# -----------------------------------------------------------------------------
# Health Check
# -----------------------------------------------------------------------------
run_health_check() {
    local health_script="${SCRIPT_DIR}/health-check.sh"
    
    if [[ -x "${health_script}" ]]; then
        "${health_script}" "${CONFIG_FILE}" 2>&1 || true
    fi
}

# -----------------------------------------------------------------------------
# Generate Status Report
# -----------------------------------------------------------------------------
generate_report() {
    local pending_count=$(find "${PENDING_DIR}" -name "*.tar.gz" 2>/dev/null | wc -l)
    local uploaded_count=$(find "${UPLOADED_DIR}" -name "*.tar.gz" 2>/dev/null | wc -l)
    local failed_count=$(find "${FAILED_DIR}" -name "*.tar.gz" 2>/dev/null | wc -l)
    
    log_info "=========================================="
    log_info "TELEMETRY SYNC REPORT"
    log_info "=========================================="
    log_info "Cluster: ${CLUSTER_NAME}"
    log_info "Cluster ID: ${CLUSTER_ID:-unknown}"
    log_info "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    log_info "------------------------------------------"
    log_info "Queue Status:"
    log_info "  Pending:  ${pending_count}"
    log_info "  Uploaded: ${uploaded_count} (last ${RETENTION_DAYS} days)"
    log_info "  Failed:   ${failed_count}"
    log_info "=========================================="
    
    # Send summary notification on success
    if [[ ${failed_count} -eq 0 && ${pending_count} -eq 0 ]]; then
        send_notification "success" "Daily sync completed successfully. ${uploaded_count} archives uploaded in last ${RETENTION_DAYS} days."
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    log_info "=========================================="
    log_info "TELEMETRY SYNC - DAILY PROCESS"
    log_info "Cluster: ${CLUSTER_NAME}"
    log_info "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    log_info "=========================================="
    
    # Acquire lock
    acquire_lock
    
    # Create directories
    mkdir -p "${PENDING_DIR}" "${UPLOADED_DIR}" "${FAILED_DIR}" "${LOG_DIR}"
    
    # Check initial queue status
    check_queue_status
    
    # Run health check
    run_health_check
    
    # Step 1: Gather new data
    run_gather || true
    
    # Step 2: Upload pending archives
    run_upload
    
    # Generate final report
    generate_report
    
    log_info "Telemetry sync completed"
}

main "$@"

