#!/bin/bash
# configure-htpasswd.sh - Configure HTPasswd Identity Provider for SNO Disconnected
#
# This script configures HTPasswd authentication for the sno-disconnected cluster.
#
# Usage:
#   ./configure-htpasswd.sh [OPTIONS]
#
# Options:
#   --admin-only      Only create admin user (no developer)
#   --users FILE      Read users from file (format: username:password per line)
#   -h, --help        Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests"
NAMESPACE="openshift-config"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check oc is available
    if ! command -v oc &> /dev/null; then
        log_error "oc CLI not found. Please install OpenShift CLI."
        exit 1
    fi
    
    # Check htpasswd is available
    if ! command -v htpasswd &> /dev/null; then
        log_error "htpasswd not found. Install with: dnf install httpd-tools"
        exit 1
    fi
    
    # Check cluster connection
    if ! oc whoami &> /dev/null; then
        log_error "Not logged into OpenShift cluster. Run 'oc login' first."
        exit 1
    fi
    
    # Verify we're on the right cluster
    local CURRENT_CONTEXT
    CURRENT_CONTEXT=$(oc whoami --show-context 2>/dev/null || echo "unknown")
    local API_URL
    API_URL=$(oc whoami --show-server 2>/dev/null || echo "unknown")
    
    echo ""
    log_warn "Current cluster context: ${CURRENT_CONTEXT}"
    log_warn "API Server: ${API_URL}"
    echo ""
    echo "Is this the correct SNO disconnected cluster? (y/N)"
    read -r response
    if [[ ! "${response}" =~ ^[Yy]$ ]]; then
        log_error "Aborted. Please login to the correct cluster."
        exit 1
    fi
    
    log_info "All prerequisites passed."
}

# Create HTPasswd secret
create_htpasswd_secret() {
    local ADMIN_ONLY="${1:-false}"
    local USERS_FILE="${2:-}"
    
    log_info "Creating HTPasswd secret..."
    
    # Check if secret already exists
    if oc get secret htpasswd-secret -n "${NAMESPACE}" &> /dev/null; then
        log_warn "htpasswd-secret already exists. Do you want to replace it? (y/N)"
        read -r response
        if [[ ! "${response}" =~ ^[Yy]$ ]]; then
            log_info "Keeping existing htpasswd-secret."
            return 0
        fi
        oc delete secret htpasswd-secret -n "${NAMESPACE}"
    fi
    
    # Create htpasswd file
    HTPASSWD_FILE=$(mktemp)
    
    if [[ -n "${USERS_FILE}" && -f "${USERS_FILE}" ]]; then
        # Read users from file
        log_info "Reading users from ${USERS_FILE}..."
        local FIRST_USER=true
        while IFS=':' read -r username password || [[ -n "$username" ]]; do
            # Skip empty lines and comments
            [[ -z "${username}" || "${username}" =~ ^# ]] && continue
            
            if [[ "${FIRST_USER}" == "true" ]]; then
                htpasswd -cbB "${HTPASSWD_FILE}" "${username}" "${password}"
                FIRST_USER=false
            else
                htpasswd -bB "${HTPASSWD_FILE}" "${username}" "${password}"
            fi
            log_info "  Added user: ${username}"
        done < "${USERS_FILE}"
    else
        # Prompt for passwords interactively
        echo ""
        echo "Enter password for 'admin' user:"
        read -rs ADMIN_PASSWORD
        echo ""
        
        htpasswd -cbB "${HTPASSWD_FILE}" admin "${ADMIN_PASSWORD}"
        log_info "  Added user: admin"
        
        if [[ "${ADMIN_ONLY}" != "true" ]]; then
            echo "Enter password for 'developer' user:"
            read -rs DEV_PASSWORD
            echo ""
            htpasswd -bB "${HTPASSWD_FILE}" developer "${DEV_PASSWORD}"
            log_info "  Added user: developer"
        fi
    fi
    
    # Create secret
    oc create secret generic htpasswd-secret \
        --from-file=htpasswd="${HTPASSWD_FILE}" \
        -n "${NAMESPACE}"
    
    # Cleanup
    rm -f "${HTPASSWD_FILE}"
    
    log_info "HTPasswd secret created successfully."
}

# Configure OAuth with HTPasswd identity provider
configure_oauth() {
    log_info "Configuring OAuth identity provider..."
    
    # Backup current OAuth config
    local BACKUP_FILE="/tmp/oauth-backup-$(date +%Y%m%d-%H%M%S).yaml"
    oc get oauth cluster -o yaml > "${BACKUP_FILE}"
    log_info "Current OAuth config backed up to: ${BACKUP_FILE}"
    
    # Apply OAuth configuration
    cat <<'EOF' | oc apply -f -
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
    - name: htpasswd
      type: HTPasswd
      mappingMethod: claim
      htpasswd:
        fileData:
          name: htpasswd-secret
EOF
    
    log_info "OAuth configured with HTPasswd identity provider."
}

# Wait for OAuth pods to restart
wait_for_oauth() {
    log_info "Waiting for OAuth pods to restart..."
    
    local TIMEOUT=180
    local INTERVAL=10
    local ELAPSED=0
    
    # Wait for oauth-openshift pods to be ready
    while [[ ${ELAPSED} -lt ${TIMEOUT} ]]; do
        local READY_PODS
        READY_PODS=$(oc get pods -n openshift-authentication -l app=oauth-openshift \
            -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -c "True" || echo "0")
        
        if [[ "${READY_PODS}" -ge 1 ]]; then
            log_info "OAuth pods are ready (${READY_PODS} running)."
            break
        fi
        
        log_info "Waiting for OAuth pods... (${ELAPSED}s/${TIMEOUT}s)"
        sleep ${INTERVAL}
        ELAPSED=$((ELAPSED + INTERVAL))
    done
    
    if [[ ${ELAPSED} -ge ${TIMEOUT} ]]; then
        log_warn "Timeout waiting for OAuth pods. Check manually with:"
        log_warn "  oc get pods -n openshift-authentication"
    fi
}

# Grant RBAC to admin user
grant_rbac() {
    log_info "Granting cluster-admin role to admin user..."
    
    oc adm policy add-cluster-role-to-user cluster-admin admin
    
    log_info "cluster-admin role granted to admin user."
    log_info "Note: 'developer' user has no special permissions by default."
}

# Verify configuration
verify_config() {
    log_info "Verifying OAuth configuration..."
    
    echo ""
    log_info "OAuth resource:"
    oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}' 2>/dev/null || log_warn "Could not read OAuth config"
    echo ""
    
    echo ""
    log_info "HTPasswd secret:"
    oc get secret htpasswd-secret -n "${NAMESPACE}" -o name 2>/dev/null || log_warn "htpasswd-secret not found"
    
    echo ""
    log_info "OAuth pods:"
    oc get pods -n openshift-authentication -l app=oauth-openshift
    
    echo ""
    log_info "Identity providers configured:"
    oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}{.name}{" ("}{.type}{")\n"}{end}'
}

# Show usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --admin-only      Only create admin user (no developer)"
    echo "  --users FILE      Read users from file (format: username:password per line)"
    echo "  -h, --help        Show this help"
    echo ""
    echo "Examples:"
    echo "  $0                     # Interactive: prompts for admin and developer passwords"
    echo "  $0 --admin-only        # Interactive: only admin user"
    echo "  $0 --users users.txt   # Read users from file"
    echo ""
    echo "Users file format (one per line):"
    echo "  admin:secretpassword"
    echo "  developer:devpass123"
    echo "  # Comments start with #"
}

# Main
main() {
    local ADMIN_ONLY=false
    local USERS_FILE=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --admin-only)
                ADMIN_ONLY=true
                shift
                ;;
            --users)
                USERS_FILE="${2:-}"
                if [[ -z "${USERS_FILE}" ]]; then
                    log_error "--users requires a file path"
                    exit 1
                fi
                if [[ ! -f "${USERS_FILE}" ]]; then
                    log_error "Users file not found: ${USERS_FILE}"
                    exit 1
                fi
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    echo "============================================"
    echo "SNO Disconnected - HTPasswd Configuration"
    echo "============================================"
    echo ""
    
    check_prerequisites
    
    echo ""
    create_htpasswd_secret "${ADMIN_ONLY}" "${USERS_FILE}"
    
    echo ""
    configure_oauth
    
    echo ""
    wait_for_oauth
    
    echo ""
    grant_rbac
    
    echo ""
    verify_config
    
    echo ""
    echo "============================================"
    log_info "HTPasswd configuration complete!"
    echo "============================================"
    echo ""
    echo "Login with:"
    echo "  oc login -u admin -p <password>"
    echo ""
    echo "Or via console:"
    echo "  https://console-openshift-console.apps.sno-disconnected.sno.local"
    echo "  Select: htpasswd"
    echo "  Username: admin"
    echo ""
}

main "$@"
