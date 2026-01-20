#!/bin/bash
#
# prune-mirror-registry.sh
# Prune old OCP versions from the mirror registry using oc-mirror v2 delete
#
# Usage: ./prune-mirror-registry.sh [OPTIONS]
#
# This script uses the OFFICIAL oc-mirror v2 delete workflow as documented at:
# https://docs.openshift.com/container-platform/4.20/installing/disconnected_install/
#   installing-mirroring-disconnected-v2.html#oc-mirror-updating-cluster-manifests
#

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-detect workspace
if [[ -f "${SCRIPT_DIR}/imageset-config.yaml" ]]; then
    WORKSPACE_DIR="${SCRIPT_DIR}"
elif [[ -f "${SCRIPT_DIR}/../imageset-config.yaml" ]]; then
    WORKSPACE_DIR="${SCRIPT_DIR}/.."
else
    WORKSPACE_DIR="$(pwd)"
fi

CONFIG_FILE="${WORKSPACE_DIR}/imageset-config.yaml"
MIRROR_REGISTRY="mirror-registry.sno.local:8443"
MIRROR_NAMESPACE="ocp4"
PULL_SECRET="${WORKSPACE_DIR}/pull-secret.json"
# IMPORTANT: Use the ORIGINAL mirror workspace (contains cached metadata)
# The delete config file goes in a separate directory
MIRROR_WORKSPACE="${WORKSPACE_DIR}/workspace"
DELETE_CONFIG_DIR="${WORKSPACE_DIR}/delete-config"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# Helper Functions
# =============================================================================

log() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Prune old OCP versions from the mirror registry using oc-mirror v2 delete.

This script implements the OFFICIAL oc-mirror v2 delete workflow from Red Hat docs.

OPTIONS:
    --help, -h          Show this help message
    --info              Explain oc-mirror v2 delete workflow and shared layers
    --check             Check current disk usage on mirror registry
    --create-config     Create a DeleteImageSetConfiguration file interactively
    --generate          Generate delete manifest (Step 1 of delete workflow)
    --execute           Execute the delete operation (Step 2 of delete workflow)
    --gc                Run garbage collection on mirror registry (Step 3)
    --full              Full cleanup: generate + execute + gc
    --list-versions     List OCP versions currently in mirror registry
    --config FILE       Path to DeleteImageSetConfiguration (default: auto-detect)
    --registry URL      Mirror registry URL (default: ${MIRROR_REGISTRY})

OFFICIAL OC-MIRROR V2 DELETE WORKFLOW:
    
    Step 1: Create DeleteImageSetConfiguration specifying what to DELETE
            $(basename "$0") --create-config
            
    Step 2: Generate delete manifest
            $(basename "$0") --generate
            
    Step 3: Execute deletion (deletes manifests only)
            $(basename "$0") --execute
            
    Step 4: Run garbage collection to reclaim disk space
            $(basename "$0") --gc

IMPORTANT NOTES:
    
    - oc-mirror v2 does NOT auto-prune like v1
    - DeleteImageSetConfiguration specifies what to DELETE (not keep!)
    - Deletion only removes manifests, not blobs
    - Registry GC is required to actually free disk space
    - Shared image layers: 80-90% of images are shared between OCP versions

EXAMPLES:
    # Check disk space and list versions
    $(basename "$0") --check
    $(basename "$0") --list-versions

    # Create delete config for 4.18 content
    $(basename "$0") --create-config

    # Generate and review delete manifest
    $(basename "$0") --generate
    cat workspace/working-dir/delete/delete-images.yaml

    # Execute deletion
    $(basename "$0") --execute

    # Run garbage collection
    $(basename "$0") --gc

DOCUMENTATION:
    https://docs.openshift.com/container-platform/4.20/installing/disconnected_install/
    installing-mirroring-disconnected-v2.html#oc-mirror-deleting-images

EOF
    exit 0
}

check_requirements() {
    local missing=0
    
    if ! command -v oc-mirror &> /dev/null; then
        error "oc-mirror not found. Required for delete operations."
        missing=1
    fi
    
    if ! command -v jq &> /dev/null; then
        error "jq not found. Install with: sudo dnf install jq"
        missing=1
    fi
    
    if [[ ! -f "$PULL_SECRET" ]]; then
        error "Pull secret not found: $PULL_SECRET"
        missing=1
    fi
    
    if [[ $missing -eq 1 ]]; then
        exit 1
    fi
    
    success "All requirements met"
}

# =============================================================================
# Commands
# =============================================================================

cmd_info() {
    cat << 'EOF'
================================================================================
              OC-MIRROR V2 DELETE WORKFLOW (OFFICIAL METHOD)
================================================================================

IMPORTANT: oc-mirror v2 does NOT automatically prune unlike v1!

To delete images, you must use the DeleteImageSetConfiguration workflow.

WORKFLOW OVERVIEW
-----------------

1. CREATE DeleteImageSetConfiguration
   This file specifies what you want to DELETE (not keep!)

   apiVersion: mirror.openshift.io/v2alpha1
   kind: DeleteImageSetConfiguration
   delete:
     platform:
       channels:
         - name: stable-4.18
           minVersion: '4.18.14'
           maxVersion: '4.18.30'
     operators:
       - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.18
         full: true

2. GENERATE DELETE MANIFEST
   $ oc mirror delete \
       --config=delete-config.yaml \
       --generate \
       --workspace file://./workspace \
       docker://mirror-registry:8443/ocp4 \
       --v2

3. EXECUTE DELETION
   $ oc mirror delete \
       --delete-yaml-file ./workspace/working-dir/delete/delete-images.yaml \
       docker://mirror-registry:8443/ocp4 \
       --v2

4. RUN GARBAGE COLLECTION
   The delete only removes manifests. Blobs remain until GC runs.
   Quay-based registries run GC automatically over 24-48 hours.

WHAT GETS DELETED
-----------------

- oc-mirror v2 deletes MANIFESTS only
- Does NOT immediately reduce storage
- Registry must run garbage collection to delete orphaned blobs
- Quay runs GC automatically (24-48 hour delay)

SHARED IMAGE LAYERS
-------------------

OpenShift versions share 80-90% of container images:

    4.18.x ──┐
    4.19.x ──┼──> Same etcd, kube-apiserver, coredns blobs
    4.20.x ──┘

Deleting 4.18 tags while keeping 4.19 frees ~5-10% space only!

================================================================================
EOF
}

cmd_check() {
    log "Checking disk usage on mirror-registry..."
    echo ""
    
    local df_output
    df_output=$(kcli ssh mirror-registry "df -h /" 2>/dev/null) || {
        error "Could not connect to mirror-registry VM"
        exit 1
    }
    
    local total used avail use_percent
    total=$(echo "$df_output" | awk 'NR==2 {print $2}')
    used=$(echo "$df_output" | awk 'NR==2 {print $3}')
    avail=$(echo "$df_output" | awk 'NR==2 {print $4}')
    use_percent=$(echo "$df_output" | awk 'NR==2 {print $5}')
    
    echo "=== Mirror Registry Disk Space ==="
    echo ""
    echo "Total:     $total"
    echo "Used:      $used ($use_percent)"
    
    local pct_num="${use_percent%\%}"
    if [[ "$pct_num" -gt 80 ]]; then
        echo -e "Available: ${RED}$avail${NC} ❌ (CRITICAL - >80% used)"
    elif [[ "$pct_num" -gt 60 ]]; then
        echo -e "Available: ${YELLOW}$avail${NC} ⚠️  (Consider cleanup)"
    else
        echo -e "Available: ${GREEN}$avail${NC} ✅"
    fi
    
    echo ""
    
    local storage_size
    storage_size=$(kcli ssh mirror-registry "sudo du -sh /var/lib/containers 2>/dev/null" | awk '{print $1}') || storage_size="N/A"
    echo "Registry data (/var/lib/containers): $storage_size"
    
    echo ""
    success "Disk check complete"
}

cmd_list_versions() {
    log "Listing OCP versions in mirror registry..."
    echo ""
    
    check_requirements
    
    if command -v skopeo &> /dev/null; then
        log "Release images:"
        skopeo list-tags --authfile "$PULL_SECRET" \
            "docker://${MIRROR_REGISTRY}/${MIRROR_NAMESPACE}/openshift/release-images" 2>/dev/null | \
            jq -r '.Tags[]?' 2>/dev/null | sort -V || warn "Could not list tags"
    else
        warn "skopeo not found, using curl..."
        local registry_auth
        registry_auth=$(jq -r ".auths[\"${MIRROR_REGISTRY}\"].auth // empty" "$PULL_SECRET" 2>/dev/null)
        
        if [[ -n "$registry_auth" ]]; then
            curl -sk -H "Authorization: Basic ${registry_auth}" \
                "https://${MIRROR_REGISTRY}/v2/${MIRROR_NAMESPACE}/openshift/release-images/tags/list" | \
                jq -r '.tags[]?' 2>/dev/null | sort -V || warn "Could not list tags"
        fi
    fi
    
    echo ""
    log "Operator catalogs:"
    curl -sk "https://${MIRROR_REGISTRY}/v2/_catalog" 2>/dev/null | \
        jq -r '.repositories[]?' 2>/dev/null | grep -i "operator-index" || warn "Could not list catalogs"
}

cmd_create_config() {
    log "Creating DeleteImageSetConfiguration..."
    echo ""
    
    mkdir -p "$DELETE_CONFIG_DIR"
    local delete_config="${DELETE_CONFIG_DIR}/delete-imageset-config.yaml"
    
    echo "What do you want to DELETE from the mirror registry?"
    echo ""
    echo "1. Delete specific OCP version range (e.g., 4.18.x)"
    echo "2. Delete old operator catalog (e.g., v4.18, v4.19)"
    echo "3. Create custom config manually"
    echo ""
    read -p "Select option (1-3): " option
    
    case $option in
        1)
            echo ""
            read -p "Enter channel name to delete (e.g., stable-4.18): " channel_name
            read -p "Enter minimum version (e.g., 4.18.14): " min_version
            read -p "Enter maximum version (e.g., 4.18.30): " max_version
            
            cat > "$delete_config" << EOF
apiVersion: mirror.openshift.io/v2alpha1
kind: DeleteImageSetConfiguration
delete:
  platform:
    channels:
      - name: ${channel_name}
        minVersion: '${min_version}'
        maxVersion: '${max_version}'
EOF
            ;;
        2)
            echo ""
            read -p "Enter operator catalog to delete (e.g., registry.redhat.io/redhat/redhat-operator-index:v4.18): " catalog
            
            cat > "$delete_config" << EOF
apiVersion: mirror.openshift.io/v2alpha1
kind: DeleteImageSetConfiguration
delete:
  operators:
    - catalog: ${catalog}
      full: true
EOF
            ;;
        3)
            cat > "$delete_config" << 'EOF'
# DeleteImageSetConfiguration - Edit this file to specify what to DELETE
# Reference: https://docs.openshift.com/container-platform/4.20/installing/disconnected_install/
#            installing-mirroring-disconnected-v2.html#oc-mirror-imageset-config-params-v2_installing-mirroring-disconnected-v2

apiVersion: mirror.openshift.io/v2alpha1
kind: DeleteImageSetConfiguration
delete:
  # Delete OCP release images
  platform:
    channels:
      - name: stable-4.18
        minVersion: '4.18.14'
        maxVersion: '4.18.30'
  
  # Delete operator catalog images
  operators:
    - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.18
      full: true    # Delete entire catalog
  
  # Delete additional images
  # additionalImages:
  #   - name: registry.redhat.io/ubi8/ubi:latest
EOF
            echo ""
            log "Created template: $delete_config"
            log "Edit this file manually, then run: $(basename "$0") --generate"
            exit 0
            ;;
        *)
            error "Invalid option"
            exit 1
            ;;
    esac
    
    echo ""
    success "Created: $delete_config"
    echo ""
    log "Contents:"
    cat "$delete_config"
    echo ""
    log "Next step: $(basename "$0") --generate"
}

cmd_generate() {
    log "Generating delete manifest using oc-mirror v2..."
    echo ""
    
    check_requirements
    
    local delete_config="${DELETE_CONFIG_DIR}/delete-imageset-config.yaml"
    
    if [[ ! -f "$delete_config" ]]; then
        error "Delete config not found: $delete_config"
        error "Run --create-config first to create it"
        exit 1
    fi
    
    if [[ ! -d "$MIRROR_WORKSPACE" ]]; then
        error "Mirror workspace not found: $MIRROR_WORKSPACE"
        error "The original oc-mirror workspace with cached metadata is required"
        exit 1
    fi
    
    log "Using delete config: $delete_config"
    cat "$delete_config"
    echo ""
    log "Using mirror workspace: $MIRROR_WORKSPACE"
    echo ""
    
    # Ensure REGISTRY_AUTH_FILE is not set (oc-mirror v2 bug)
    unset REGISTRY_AUTH_FILE
    
    log "Running oc mirror delete --generate..."
    echo ""
    
    # IMPORTANT: Use the ORIGINAL mirror workspace (not a new one)
    # This is required because oc-mirror needs the cached metadata
    oc mirror delete \
        --config="$delete_config" \
        --generate \
        --workspace "file://${MIRROR_WORKSPACE}" \
        --authfile "$PULL_SECRET" \
        "docker://${MIRROR_REGISTRY}/${MIRROR_NAMESPACE}" \
        --v2
    
    local delete_yaml="${MIRROR_WORKSPACE}/working-dir/delete/delete-images.yaml"
    
    if [[ -f "$delete_yaml" ]]; then
        echo ""
        success "Delete manifest generated: $delete_yaml"
        echo ""
        log "Contents preview:"
        head -50 "$delete_yaml"
        echo ""
        log "Next step: Review the manifest, then run: $(basename "$0") --execute"
    else
        warn "Delete manifest not generated - check oc-mirror output above"
    fi
}

cmd_execute() {
    log "Executing oc-mirror v2 delete..."
    echo ""
    
    check_requirements
    
    local delete_yaml="${MIRROR_WORKSPACE}/working-dir/delete/delete-images.yaml"
    
    if [[ ! -f "$delete_yaml" ]]; then
        error "Delete manifest not found: $delete_yaml"
        error "Run --generate first to create it"
        exit 1
    fi
    
    log "Delete manifest: $delete_yaml"
    echo ""
    
    # Count images to delete
    local count
    count=$(grep -c "image:" "$delete_yaml" 2>/dev/null || echo "0")
    
    echo -e "${YELLOW}=== WARNING ===${NC}"
    echo "This will delete manifests for approximately $count images"
    echo "from: ${MIRROR_REGISTRY}/${MIRROR_NAMESPACE}"
    echo ""
    echo "Note: This deletes MANIFESTS only. Blobs remain until garbage collection."
    echo ""
    read -p "Type 'DELETE' to confirm: " confirm
    
    if [[ "$confirm" != "DELETE" ]]; then
        log "Aborted by user"
        exit 0
    fi
    
    echo ""
    
    # Ensure REGISTRY_AUTH_FILE is not set
    unset REGISTRY_AUTH_FILE
    
    log "Running oc mirror delete..."
    
    oc mirror delete \
        --delete-yaml-file "$delete_yaml" \
        --authfile "$PULL_SECRET" \
        "docker://${MIRROR_REGISTRY}/${MIRROR_NAMESPACE}" \
        --v2
    
    echo ""
    success "Delete operation completed"
    echo ""
    log "Manifests have been deleted from the registry."
    log "Run garbage collection to reclaim disk space: $(basename "$0") --gc"
}

cmd_gc() {
    log "Running garbage collection on mirror-registry..."
    echo ""
    
    echo "=== GARBAGE COLLECTION INFO ==="
    echo ""
    echo "Quay-based mirror-registry handles garbage collection automatically."
    echo "However, you can manually trigger it or check its status."
    echo ""
    echo "Options:"
    echo "1. Check Quay GC status (recommended)"
    echo "2. Restart Quay to force GC cycle"
    echo "3. Skip (Quay handles GC automatically in 24-48 hours)"
    echo ""
    read -p "Select option (1-3): " option
    
    case $option in
        1)
            log "Checking Quay garbage collection status..."
            kcli ssh mirror-registry "sudo podman logs quay-app 2>&1 | grep -i garbage | tail -20" || \
                warn "Could not retrieve GC logs"
            echo ""
            log "Quay runs GC automatically. Check logs for 'GC' or 'garbage' entries."
            ;;
        2)
            warn "Restarting Quay containers to trigger GC..."
            echo ""
            read -p "This will briefly interrupt registry access. Continue? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                kcli ssh mirror-registry "sudo podman restart quay-app quay-postgres quay-redis"
                echo ""
                log "Waiting for Quay to start..."
                sleep 60
                
                if curl -sk "https://${MIRROR_REGISTRY}/v2/" > /dev/null 2>&1; then
                    success "Mirror registry is back online"
                else
                    warn "Registry may still be starting - wait a minute"
                fi
            else
                log "Skipped"
            fi
            ;;
        3)
            log "Skipping manual GC - Quay will handle it automatically"
            ;;
        *)
            warn "Invalid option, skipping GC"
            ;;
    esac
    
    echo ""
    cmd_check
}

cmd_full() {
    log "Full cleanup: generate + execute + garbage collection"
    echo ""
    
    check_requirements
    
    local delete_config="${DELETE_CONFIG_DIR}/delete-imageset-config.yaml"
    
    if [[ ! -f "$delete_config" ]]; then
        error "Delete config not found: $delete_config"
        error "Run --create-config first to create it"
        exit 1
    fi
    
    if [[ ! -d "$MIRROR_WORKSPACE" ]]; then
        error "Mirror workspace not found: $MIRROR_WORKSPACE"
        error "The original oc-mirror workspace with cached metadata is required"
        exit 1
    fi
    
    echo -e "${RED}=== FULL CLEANUP WARNING ===${NC}"
    echo ""
    echo "This will:"
    echo "  1. Generate delete manifest from: $delete_config"
    echo "  2. Execute deletion (remove manifests)"
    echo "  3. Restart Quay to trigger garbage collection"
    echo ""
    cat "$delete_config"
    echo ""
    read -p "Type 'FULL-CLEANUP' to confirm: " confirm
    
    if [[ "$confirm" != "FULL-CLEANUP" ]]; then
        log "Aborted by user"
        exit 0
    fi
    
    echo ""
    echo "=========================================="
    log "Step 1: Generating delete manifest..."
    echo "=========================================="
    
    unset REGISTRY_AUTH_FILE
    
    oc mirror delete \
        --config="$delete_config" \
        --generate \
        --workspace "file://${MIRROR_WORKSPACE}" \
        --authfile "$PULL_SECRET" \
        "docker://${MIRROR_REGISTRY}/${MIRROR_NAMESPACE}" \
        --v2 || {
        error "Generate failed"
        exit 1
    }
    
    local delete_yaml="${MIRROR_WORKSPACE}/working-dir/delete/delete-images.yaml"
    
    if [[ ! -f "$delete_yaml" ]]; then
        warn "No delete manifest generated - nothing to delete"
        exit 0
    fi
    
    echo ""
    echo "=========================================="
    log "Step 2: Executing deletion..."
    echo "=========================================="
    
    oc mirror delete \
        --delete-yaml-file "$delete_yaml" \
        --authfile "$PULL_SECRET" \
        "docker://${MIRROR_REGISTRY}/${MIRROR_NAMESPACE}" \
        --v2 || {
        warn "Some deletions may have failed"
    }
    
    echo ""
    echo "=========================================="
    log "Step 3: Triggering garbage collection..."
    echo "=========================================="
    
    kcli ssh mirror-registry "sudo podman restart quay-app" 2>/dev/null || true
    sleep 30
    
    echo ""
    success "Full cleanup completed!"
    echo ""
    log "Note: Quay GC runs in background. Space may take 24-48 hours to fully reclaim."
    echo ""
    cmd_check
}

# =============================================================================
# Main
# =============================================================================

main() {
    for arg in "$@"; do
        if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
            usage
        fi
    done
    
    local command=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --info)
                command="info"
                shift
                ;;
            --check)
                command="check"
                shift
                ;;
            --list-versions)
                command="list-versions"
                shift
                ;;
            --create-config)
                command="create-config"
                shift
                ;;
            --generate)
                command="generate"
                shift
                ;;
            --execute)
                command="execute"
                shift
                ;;
            --gc)
                command="gc"
                shift
                ;;
            --full)
                command="full"
                shift
                ;;
            --config)
                DELETE_CONFIG_DIR="$(dirname "$2")"
                shift 2
                ;;
            --registry)
                MIRROR_REGISTRY="$2"
                shift 2
                ;;
            # Legacy compatibility
            --dry-run)
                warn "DEPRECATED: --dry-run is replaced by --generate in oc-mirror v2"
                command="generate"
                shift
                ;;
            *)
                error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
    
    if [[ -z "$command" ]]; then
        usage
    fi
    
    case $command in
        info)
            cmd_info
            ;;
        check)
            cmd_check
            ;;
        list-versions)
            cmd_list_versions
            ;;
        create-config)
            cmd_create_config
            ;;
        generate)
            cmd_generate
            ;;
        execute)
            cmd_execute
            ;;
        gc)
            cmd_gc
            ;;
        full)
            cmd_full
            ;;
    esac
}

main "$@"
