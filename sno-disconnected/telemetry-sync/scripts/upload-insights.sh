#!/bin/bash
# =============================================================================
# upload-insights.sh - Upload Insights Archive to Red Hat with Retry Logic
# =============================================================================
# Part of: SNO Disconnected Telemetry Sync
# Purpose: Uploads archive to console.redhat.com with exponential backoff
# 
# Usage: ./upload-insights.sh [archive-path] [config-file]
#        ./upload-insights.sh                     # Process all pending
#        ./upload-insights.sh /path/to/archive    # Upload specific file
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${2:-${SCRIPT_DIR}/../config/telemetry-sync.env}"

# Source configuration
if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "[ERROR] Configuration file not found: ${CONFIG_FILE}"
    exit 1
fi
source "${CONFIG_FILE}"

# Convert retry delays string to array
IFS=' ' read -ra RETRY_DELAYS_ARRAY <<< "${RETRY_DELAYS}"

# -----------------------------------------------------------------------------
# Logging Functions
# -----------------------------------------------------------------------------
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date -u "+%Y-%m-%d %H:%M:%S UTC")
    
    mkdir -p "${LOG_DIR}"
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_DIR}/upload.log"
    
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
# Validation
# -----------------------------------------------------------------------------
validate_config() {
    log_debug "Validating configuration..."
    
    if [[ -z "${CLOUD_TOKEN:-}" ]]; then
        log_error "CLOUD_TOKEN is not set. Extract from pull-secret."
        log_error "Run: oc extract secret/pull-secret -n openshift-config --to=- | jq -r '.auths[\"cloud.openshift.com\"].auth'"
        exit 1
    fi
    
    if [[ -z "${CLUSTER_ID:-}" ]]; then
        log_error "CLUSTER_ID is not set. Run: oc get clusterversion -o jsonpath='{.items[].spec.clusterID}'"
        exit 1
    fi
    
    mkdir -p "${PENDING_DIR}" "${UPLOADED_DIR}" "${FAILED_DIR}" "${LOG_DIR}"
    
    log_debug "Configuration validated"
}

# -----------------------------------------------------------------------------
# Check Red Hat API Health
# -----------------------------------------------------------------------------
check_api_health() {
    log_debug "Checking Red Hat API health..."
    
    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 10 \
        "${HEALTH_ENDPOINT}" 2>/dev/null) || true
    
    if [[ "${response}" == "200" ]]; then
        log_debug "Red Hat API is healthy"
        return 0
    else
        log_warn "Red Hat API health check failed (HTTP ${response})"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Update Metadata File
# -----------------------------------------------------------------------------
update_metadata() {
    local meta_file="$1"
    local field="$2"
    local value="$3"
    
    if [[ ! -f "${meta_file}" ]]; then
        log_warn "Metadata file not found: ${meta_file}"
        return
    fi
    
    # Use jq if available, otherwise sed
    if command -v jq &>/dev/null; then
        local tmp=$(mktemp)
        jq ".${field} = ${value}" "${meta_file}" > "${tmp}" && mv "${tmp}" "${meta_file}"
    else
        # Basic sed replacement for simple values
        sed -i.bak "s/\"${field}\":.*/\"${field}\": ${value},/" "${meta_file}"
        rm -f "${meta_file}.bak"
    fi
}

# -----------------------------------------------------------------------------
# Send Slack Notification (Future - Placeholder)
# -----------------------------------------------------------------------------
send_notification() {
    local level="$1"
    local message="$2"
    
    # Skip if Slack is not enabled
    if [[ "${SLACK_ENABLED}" != "true" ]]; then
        return
    fi
    
    if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
        log_warn "Slack enabled but SLACK_WEBHOOK_URL not set"
        return
    fi
    
    local emoji="📊"
    case "${level}" in
        success) emoji="✅" ;;
        warning) emoji="⚠️" ;;
        error)   emoji="❌" ;;
    esac
    
    local payload=$(cat <<EOF
{
    "text": "${emoji} *Telemetry Sync - ${CLUSTER_NAME}*\n${message}",
    "channel": "${SLACK_CHANNEL:-}"
}
EOF
)
    
    curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${SLACK_WEBHOOK_URL}" &>/dev/null || true
}

# -----------------------------------------------------------------------------
# Upload Single Archive
# -----------------------------------------------------------------------------
upload_archive() {
    local archive="$1"
    local meta_file="${archive}.meta"
    
    if [[ ! -f "${archive}" ]]; then
        log_error "Archive not found: ${archive}"
        return 1
    fi
    
    local filename=$(basename "${archive}")
    log_info "Uploading archive: ${filename}"
    
    # Get current retry count
    local retry_count=0
    if [[ -f "${meta_file}" ]] && command -v jq &>/dev/null; then
        retry_count=$(jq -r '.retry_count // 0' "${meta_file}")
    fi
    
    # Build upload command
    local response_file=$(mktemp)
    local http_code
    
    # Use multipart form upload as required by Red Hat Insights API
    http_code=$(curl -s -w "%{http_code}" -o "${response_file}" \
        --max-time "${UPLOAD_TIMEOUT}" \
        -H "Authorization: Bearer ${CLOUD_TOKEN}" \
        -H "User-Agent: ${USER_AGENT}" \
        -F "upload=@${archive};type=application/vnd.redhat.openshift.periodic+tar" \
        "${UPLOAD_ENDPOINT}" 2>/dev/null) || http_code="000"
    
    local response_body=$(cat "${response_file}" 2>/dev/null || echo "")
    rm -f "${response_file}"
    
    log_debug "Upload response: HTTP ${http_code}"
    
    case "${http_code}" in
        200|201|202)
            # Success
            log_info "Upload successful: ${filename} (HTTP ${http_code})"
            
            # Update metadata
            if [[ -f "${meta_file}" ]]; then
                update_metadata "${meta_file}" "status" "\"uploaded\""
                update_metadata "${meta_file}" "uploaded_at" "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
            fi
            
            # Move to uploaded directory
            mv "${archive}" "${UPLOADED_DIR}/"
            [[ -f "${meta_file}" ]] && mv "${meta_file}" "${UPLOADED_DIR}/"
            
            send_notification "success" "Archive uploaded successfully: ${filename}"
            return 0
            ;;
        401|403)
            # Auth error - don't retry
            log_error "Authentication failed (HTTP ${http_code}). Check CLOUD_TOKEN."
            log_error "Response: ${response_body}"
            
            update_metadata "${meta_file}" "status" "\"auth_failed\""
            update_metadata "${meta_file}" "last_error" "\"HTTP ${http_code}: Authentication failed\""
            
            mv "${archive}" "${FAILED_DIR}/"
            [[ -f "${meta_file}" ]] && mv "${meta_file}" "${FAILED_DIR}/"
            
            send_notification "error" "Upload failed: Authentication error (HTTP ${http_code})"
            return 1
            ;;
        4*)
            # Client error - likely won't succeed on retry
            log_error "Client error (HTTP ${http_code}): ${response_body}"
            
            update_metadata "${meta_file}" "status" "\"client_error\""
            update_metadata "${meta_file}" "last_error" "\"HTTP ${http_code}\""
            
            mv "${archive}" "${FAILED_DIR}/"
            [[ -f "${meta_file}" ]] && mv "${meta_file}" "${FAILED_DIR}/"
            
            send_notification "error" "Upload failed: Client error (HTTP ${http_code})"
            return 1
            ;;
        5*|000)
            # Server error or network issue - retry
            log_warn "Server/network error (HTTP ${http_code}). Will retry."
            
            ((retry_count++))
            update_metadata "${meta_file}" "retry_count" "${retry_count}"
            update_metadata "${meta_file}" "last_attempt" "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
            update_metadata "${meta_file}" "last_error" "\"HTTP ${http_code}\""
            
            if [[ ${retry_count} -ge ${MAX_RETRIES} ]]; then
                log_error "Max retries (${MAX_RETRIES}) exceeded for: ${filename}"
                update_metadata "${meta_file}" "status" "\"max_retries_exceeded\""
                
                mv "${archive}" "${FAILED_DIR}/"
                [[ -f "${meta_file}" ]] && mv "${meta_file}" "${FAILED_DIR}/"
                
                send_notification "error" "Upload failed after ${MAX_RETRIES} retries: ${filename}"
                return 1
            fi
            
            # Calculate delay for exponential backoff
            local delay_index=$((retry_count - 1))
            if [[ ${delay_index} -ge ${#RETRY_DELAYS_ARRAY[@]} ]]; then
                delay_index=$((${#RETRY_DELAYS_ARRAY[@]} - 1))
            fi
            local delay=${RETRY_DELAYS_ARRAY[${delay_index}]}
            
            log_info "Retry ${retry_count}/${MAX_RETRIES} scheduled in ${delay}s"
            update_metadata "${meta_file}" "next_retry_after" "\"$(date -u -d "+${delay} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+${delay}S +%Y-%m-%dT%H:%M:%SZ)\""
            
            # Return special code to indicate retry needed
            return 2
            ;;
        *)
            log_warn "Unexpected response (HTTP ${http_code}): ${response_body}"
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Process Pending Queue
# -----------------------------------------------------------------------------
process_queue() {
    log_info "Processing pending queue: ${PENDING_DIR}"
    
    # Get list of archives (handle no matches gracefully)
    shopt -s nullglob
    local archives=("${PENDING_DIR}"/*.tar.gz)
    shopt -u nullglob
    
    # Check if any files exist
    if [[ ${#archives[@]} -eq 0 ]]; then
        log_info "No pending archives to upload"
        return 0
    fi
    
    local total=${#archives[@]}
    local success=0
    local failed=0
    local retry=0
    
    log_info "Found ${total} pending archive(s)"
    
    for archive in "${archives[@]}"; do
        [[ -f "${archive}" ]] || continue
        
        local result=0
        upload_archive "${archive}" || result=$?
        
        case ${result} in
            0) ((success++)) ;;
            2) ((retry++)) ;;
            *) ((failed++)) ;;
        esac
    done
    
    log_info "Queue processing complete: ${success} uploaded, ${retry} pending retry, ${failed} failed"
    
    if [[ ${failed} -gt 0 ]]; then
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Retry Failed Uploads with Backoff
# -----------------------------------------------------------------------------
retry_with_backoff() {
    local archive="$1"
    local meta_file="${archive}.meta"
    
    # Check if it's time to retry
    if [[ -f "${meta_file}" ]] && command -v jq &>/dev/null; then
        local next_retry=$(jq -r '.next_retry_after // ""' "${meta_file}")
        
        if [[ -n "${next_retry}" && "${next_retry}" != "null" ]]; then
            local next_epoch=$(date -d "${next_retry}" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "${next_retry}" +%s 2>/dev/null || echo 0)
            local now_epoch=$(date +%s)
            
            if [[ ${now_epoch} -lt ${next_epoch} ]]; then
                log_debug "Skipping ${archive}: retry scheduled for ${next_retry}"
                return 0
            fi
        fi
    fi
    
    upload_archive "${archive}"
}

# -----------------------------------------------------------------------------
# Cleanup Old Archives
# -----------------------------------------------------------------------------
cleanup_old_archives() {
    log_info "Cleaning up old archives..."
    
    # Clean uploaded archives older than RETENTION_DAYS
    find "${UPLOADED_DIR}" -type f -mtime +${RETENTION_DAYS} -delete 2>/dev/null || true
    
    # Clean failed archives older than FAILED_RETENTION_DAYS
    find "${FAILED_DIR}" -type f -mtime +${FAILED_RETENTION_DAYS} -delete 2>/dev/null || true
    
    log_debug "Cleanup complete"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    log_info "=========================================="
    log_info "Starting Telemetry Upload"
    log_info "Cluster: ${CLUSTER_NAME}"
    log_info "=========================================="
    
    validate_config
    
    # Check API health first
    if ! check_api_health; then
        log_warn "Red Hat API may be unavailable. Proceeding anyway..."
    fi
    
    # If specific archive provided, upload it
    if [[ -n "${1:-}" && -f "${1}" ]]; then
        upload_archive "$1"
        exit $?
    fi
    
    # Otherwise, process the queue
    process_queue
    local result=$?
    
    # Cleanup old archives
    cleanup_old_archives
    
    log_info "=========================================="
    log_info "Telemetry Upload Complete"
    log_info "=========================================="
    
    exit ${result}
}

main "$@"

