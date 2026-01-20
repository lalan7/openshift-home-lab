#!/bin/bash
# manage-images.sh - Mirror and manage container images in disconnected registry
#
# Usage:
#   ./manage-images.sh mirror <image>           # Mirror single image
#   ./manage-images.sh mirror -f <file>         # Mirror images from file
#   ./manage-images.sh delete <image>           # Delete image from registry
#   ./manage-images.sh list [filter]            # List images in registry
#   ./manage-images.sh tags <image>             # List tags for an image
#
# Environment:
#   REGISTRY_HOST     - Registry hostname (default: mirror-registry.sno.local)
#   REGISTRY_PORT     - Registry port (default: 8443)
#   REGISTRY_USER     - Registry username (default: init)
#   REGISTRY_PASSWORD - Registry password (required)

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration from environment
REGISTRY_HOST="${REGISTRY_HOST:-mirror-registry.sno.local}"
REGISTRY_PORT="${REGISTRY_PORT:-8443}"
REGISTRY_USER="${REGISTRY_USER:-init}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-}"
REGISTRY_URL="${REGISTRY_HOST}:${REGISTRY_PORT}"
REGISTRY_TLS_VERIFY="${REGISTRY_TLS_VERIFY:-false}"

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  mirror <image>         Mirror image to local registry
  mirror -f <file>       Mirror images listed in file (one per line)
  delete <repo>          Delete repository from registry
  list [filter]          List repositories (optional filter)
  tags <repo>            List tags for a repository

Examples:
  $(basename "$0") mirror docker.io/library/nginx:latest
  $(basename "$0") mirror quay.io/argoproj/argocd:v2.9.0
  $(basename "$0") mirror -f images.txt
  $(basename "$0") list nginx
  $(basename "$0") tags library/nginx
  $(basename "$0") delete library/nginx

Environment Variables:
  REGISTRY_HOST      Registry hostname (default: mirror-registry.sno.local)
  REGISTRY_PORT      Registry port (default: 8443)
  REGISTRY_USER      Registry username (default: init)
  REGISTRY_PASSWORD  Registry password (required for write operations)
EOF
    exit 1
}

check_dependencies() {
    local missing=()
    for cmd in skopeo curl jq; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi
}

check_password() {
    if [[ -z "$REGISTRY_PASSWORD" ]]; then
        log_error "REGISTRY_PASSWORD is required"
        echo "  Export it: export REGISTRY_PASSWORD='your-password'"
        exit 1
    fi
}

# Convert source image to destination path
# docker.io/library/nginx:latest -> library/nginx:latest
# quay.io/argoproj/argocd:v2.9.0 -> argoproj/argocd:v2.9.0
normalize_image_path() {
    local image="$1"
    # Remove common registry prefixes to get the repository path
    echo "$image" | sed -E 's#^(docker\.io|quay\.io|gcr\.io|ghcr\.io|registry\.k8s\.io)/##'
}

# Mirror a single image
# Note: Requires prior 'podman login' to the registry for push access
mirror_image() {
    local source_image="$1"
    local dest_path
    dest_path=$(normalize_image_path "$source_image")
    
    # Add docker.io prefix if no registry specified
    if [[ ! "$source_image" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]+/ ]]; then
        if [[ "$source_image" =~ ^[^/]+$ ]] || [[ "$source_image" =~ ^library/ ]]; then
            source_image="docker.io/library/${source_image#library/}"
        else
            source_image="docker.io/${source_image}"
        fi
    fi
    
    log_info "Mirroring: $source_image"
    log_info "       To: ${REGISTRY_URL}/${dest_path}"
    
    local tls_flag=""
    [[ "$REGISTRY_TLS_VERIFY" == "false" ]] && tls_flag="--dest-tls-verify=false"
    
    if skopeo copy \
        "docker://${source_image}" \
        "docker://${REGISTRY_URL}/${dest_path}" \
        --dest-creds "${REGISTRY_USER}:${REGISTRY_PASSWORD}" \
        $tls_flag; then
        log_ok "Mirrored successfully"
        echo "  Use: image: ${REGISTRY_URL}/${dest_path}"
        return 0
    else
        log_error "Failed to mirror $source_image"
        return 1
    fi
}

# Mirror images from file
mirror_from_file() {
    local file="$1"
    local success=0
    local failed=0
    
    if [[ ! -f "$file" ]]; then
        log_error "File not found: $file"
        exit 1
    fi
    
    log_info "Mirroring images from: $file"
    
    while IFS= read -r image || [[ -n "$image" ]]; do
        # Skip empty lines and comments
        [[ -z "$image" || "$image" =~ ^# ]] && continue
        
        if mirror_image "$image"; then
            ((success++))
        else
            ((failed++))
        fi
        echo
    done < "$file"
    
    log_info "Complete: $success succeeded, $failed failed"
    [[ $failed -eq 0 ]] || exit 1
}

# List repositories in registry
list_repos() {
    local filter="${1:-}"
    local tls_flag=""
    [[ "$REGISTRY_TLS_VERIFY" == "false" ]] && tls_flag="-k"
    
    log_info "Listing repositories in ${REGISTRY_URL}"
    
    # Quay mirror-registry requires auth for catalog API
    local auth_flag=""
    if [[ -n "$REGISTRY_PASSWORD" ]]; then
        auth_flag="-u ${REGISTRY_USER}:${REGISTRY_PASSWORD}"
    fi
    
    local response
    response=$(curl -s $tls_flag $auth_flag "https://${REGISTRY_URL}/v2/_catalog" 2>/dev/null)
    
    # Check for auth errors
    if echo "$response" | grep -q '"UNAUTHORIZED"'; then
        log_warn "Authentication required. Run: podman login ${REGISTRY_URL} --tls-verify=false"
        return 1
    fi
    
    local repos
    repos=$(echo "$response" | jq -r '.repositories[]' 2>/dev/null)
    
    if [[ -z "$repos" ]]; then
        log_warn "No repositories found or unable to connect"
        log_info "Tip: Use 'skopeo inspect docker://${REGISTRY_URL}/<image>:<tag>' to verify specific images"
        return 1
    fi
    
    if [[ -n "$filter" ]]; then
        repos=$(echo "$repos" | grep -i "$filter" || true)
    fi
    
    if [[ -z "$repos" ]]; then
        log_warn "No repositories match filter: $filter"
        return 1
    fi
    
    echo "$repos" | while read -r repo; do
        echo "  ${REGISTRY_URL}/${repo}"
    done
}

# List tags for a repository
list_tags() {
    local repo="$1"
    local tls_flag=""
    [[ "$REGISTRY_TLS_VERIFY" == "false" ]] && tls_flag="-k"
    
    log_info "Tags for ${repo}:"
    
    # Quay mirror-registry requires auth for tags API
    local auth_flag=""
    if [[ -n "$REGISTRY_PASSWORD" ]]; then
        auth_flag="-u ${REGISTRY_USER}:${REGISTRY_PASSWORD}"
    fi
    
    local response
    response=$(curl -s $tls_flag $auth_flag "https://${REGISTRY_URL}/v2/${repo}/tags/list" 2>/dev/null)
    
    # Check for auth errors
    if echo "$response" | grep -q '"UNAUTHORIZED"'; then
        log_warn "Authentication required. Trying skopeo..."
        # Fall back to skopeo which uses stored auth
        if skopeo inspect --tls-verify=false "docker://${REGISTRY_URL}/${repo}" >/dev/null 2>&1; then
            skopeo inspect --tls-verify=false "docker://${REGISTRY_URL}/${repo}" | jq -r '.RepoTags[]' 2>/dev/null | while read -r tag; do
                echo "  ${REGISTRY_URL}/${repo}:${tag}"
            done
            return 0
        else
            log_error "Image not found or unable to inspect: ${repo}"
            return 1
        fi
    fi
    
    local tags
    tags=$(echo "$response" | jq -r '.tags[]' 2>/dev/null)
    
    if [[ -z "$tags" ]]; then
        log_warn "No tags found for: $repo"
        return 1
    fi
    
    echo "$tags" | while read -r tag; do
        echo "  ${REGISTRY_URL}/${repo}:${tag}"
    done
}

# Delete a repository (all tags)
delete_repo() {
    local repo="$1"
    local tls_flag=""
    [[ "$REGISTRY_TLS_VERIFY" == "false" ]] && tls_flag="-k"
    
    log_warn "Deleting repository: $repo"
    
    # Get all tags
    local tags
    tags=$(curl -s $tls_flag -u "${REGISTRY_USER}:${REGISTRY_PASSWORD}" \
        "https://${REGISTRY_URL}/v2/${repo}/tags/list" | jq -r '.tags[]' 2>/dev/null)
    
    if [[ -z "$tags" ]]; then
        log_error "Repository not found or no tags: $repo"
        return 1
    fi
    
    # Delete each tag's manifest
    echo "$tags" | while read -r tag; do
        log_info "Deleting ${repo}:${tag}"
        
        # Get manifest digest
        local digest
        digest=$(curl -s $tls_flag -I -u "${REGISTRY_USER}:${REGISTRY_PASSWORD}" \
            -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
            "https://${REGISTRY_URL}/v2/${repo}/manifests/${tag}" \
            | grep -i docker-content-digest | awk '{print $2}' | tr -d '\r')
        
        if [[ -n "$digest" ]]; then
            curl -s $tls_flag -X DELETE -u "${REGISTRY_USER}:${REGISTRY_PASSWORD}" \
                "https://${REGISTRY_URL}/v2/${repo}/manifests/${digest}"
            log_ok "Deleted ${repo}:${tag}"
        else
            log_warn "Could not get digest for ${repo}:${tag}"
        fi
    done
    
    log_info "Note: Run garbage collection on registry to reclaim space"
}

# Main
check_dependencies

[[ $# -lt 1 ]] && usage

command="$1"
shift

case "$command" in
    mirror)
        check_password
        if [[ "${1:-}" == "-f" ]]; then
            [[ $# -lt 2 ]] && usage
            mirror_from_file "$2"
        else
            [[ $# -lt 1 ]] && usage
            mirror_image "$1"
        fi
        ;;
    list)
        list_repos "${1:-}"
        ;;
    tags)
        [[ $# -lt 1 ]] && usage
        list_tags "$1"
        ;;
    delete)
        check_password
        [[ $# -lt 1 ]] && usage
        read -p "Are you sure you want to delete '$1'? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy] ]] && delete_repo "$1" || log_info "Cancelled"
        ;;
    *)
        usage
        ;;
esac

