#!/bin/bash
# update-imageset-versions.sh
# 
# Reads current imageset-config.yaml, queries upstream for latest versions,
# and generates an updated config with correct minVersion/maxVersion.
#
# Usage:
#   ./update-imageset-versions.sh                           # Update all operators from current config
#   ./update-imageset-versions.sh --add openshift-gitops    # Add a new operator
#   ./update-imageset-versions.sh --check                   # Just compare versions, don't update
#   ./update-imageset-versions.sh --list                    # List operators in current config
#
# Requirements:
#   - Run from servermind (needs internet access)
#   - export REGISTRY_AUTH_FILE=./pull-secret.json
#   - oc-mirror tool installed

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/oc-mirror-workspace}"
CONFIG_FILE="${WORKSPACE_DIR}/imageset-config.yaml"
CATALOG="registry.redhat.io/redhat/redhat-operator-index:v4.18"
PULL_SECRET="${REGISTRY_AUTH_FILE:-${WORKSPACE_DIR}/pull-secret.json}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================
log() { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $*" >&2; }

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Update operator versions in imageset-config.yaml by querying upstream catalog.

OPTIONS:
  --check             Compare current vs upstream versions (no changes)
  --update            Update imageset-config.yaml with latest versions
  --add <operator>    Add a new operator to the config
  --list              List operators in current config
  --help              Show this help

EXAMPLES:
  $(basename "$0") --check                    # Check for new versions
  $(basename "$0") --update                   # Update config with latest
  $(basename "$0") --add openshift-gitops     # Add new operator
  $(basename "$0") --add "rhacs-operator:stable"  # Add with specific channel

ENVIRONMENT:
  WORKSPACE_DIR       Directory with imageset-config.yaml (default: ~/oc-mirror-workspace)
  REGISTRY_AUTH_FILE  Path to pull secret (default: \$WORKSPACE_DIR/pull-secret.json)

EOF
    exit 0
}

check_requirements() {
    if [[ ! -f "$PULL_SECRET" ]]; then
        error "Pull secret not found: $PULL_SECRET"
        error "Set REGISTRY_AUTH_FILE or place pull-secret.json in workspace"
        exit 1
    fi
    
    if ! command -v oc-mirror &>/dev/null; then
        error "oc-mirror not found. Install it first."
        exit 1
    fi
    
    export REGISTRY_AUTH_FILE="$PULL_SECRET"
}

# Get latest version of an operator from upstream catalog
get_upstream_version() {
    local package=$1
    local channel=$2
    
    # When --channel is specified, output format is:
    #   VERSIONS
    #   4.9.0
    #   5.0.3
    #   ...
    # Output order is NON-DETERMINISTIC, so we must sort to find latest
    
    # Extract version lines, sort semantically, take highest
    oc-mirror list operators \
        --catalog="$CATALOG" \
        --package="$package" \
        --channel="$channel" 2>/dev/null | \
        grep -E '^[0-9]+\.[0-9]+' | \
        sort -V | \
        tail -1
}

# Get default channel for an operator
get_default_channel() {
    local package=$1
    local output
    
    # Query operator info - capture both stdout and check for errors
    output=$(oc-mirror list operators \
        --catalog="$CATALOG" \
        --package="$package" 2>&1) || true
    
    # Check if package was found
    if echo "$output" | grep -q "not found"; then
        echo ""
        return 1
    fi
    
    # Output format:
    #   NAME                       DISPLAY NAME  DEFAULT CHANNEL
    #   openshift-gitops-operator                latest
    # Extract DEFAULT CHANNEL (3rd column after the header)
    echo "$output" | grep -A1 "DEFAULT CHANNEL" | tail -1 | awk '{print $NF}'
}

# Parse operators from current imageset-config.yaml
parse_current_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "Config file not found: $CONFIG_FILE"
        exit 1
    fi
    
    # Extract operator name and channel pairs
    # Format: operator:channel:currentVersion
    local in_packages=false
    local current_name=""
    local current_channel=""
    local current_version=""
    
    while IFS= read -r line; do
        # Detect packages section
        if [[ "$line" =~ "- name:" ]] && [[ ! "$line" =~ "channels:" ]]; then
            # Save previous operator if exists
            if [[ -n "$current_name" ]]; then
                echo "${current_name}:${current_channel}:${current_version}"
            fi
            current_name=$(echo "$line" | sed "s/.*- name: //" | tr -d "'" | tr -d '"')
            current_channel=""
            current_version=""
        fi
        
        # Get channel name
        if [[ "$line" =~ "- name:" ]] && [[ "$current_name" != "" ]] && [[ -z "$current_channel" ]]; then
            # This is a channel name line (inside channels:)
            if [[ "$line" =~ "channels:" ]]; then
                continue
            fi
            # Skip if this line has "- name:" at the start (it's an operator name)
            if [[ ! "$line" =~ ^[[:space:]]*-\ name: ]]; then
                continue
            fi
            # Only capture if we're in the channels section
            if [[ "$line" =~ ^[[:space:]]{12,}-\ name: ]]; then
                current_channel=$(echo "$line" | sed "s/.*- name: //" | tr -d "'" | tr -d '"')
            fi
        fi
        
        # Get minVersion or maxVersion
        if [[ "$line" =~ "minVersion:" ]] || [[ "$line" =~ "maxVersion:" ]]; then
            current_version=$(echo "$line" | sed "s/.*Version: //" | tr -d "'" | tr -d '"')
        fi
    done < "$CONFIG_FILE"
    
    # Don't forget last operator
    if [[ -n "$current_name" ]]; then
        echo "${current_name}:${current_channel}:${current_version}"
    fi
}

# Parse operators from config - operators are at 8-space indent, channels at 14-space
parse_operators_simple() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "Config file not found: $CONFIG_FILE"
        exit 1
    fi
    
    # Use awk to find operator names (8-space indent "- name:")
    # Channel names are at deeper indent (12+ spaces)
    awk '
        /^        - name:/ && !/^            / {
            gsub(/.*- name: /, "")
            gsub(/'\''/, "")
            gsub(/"/, "")
            print
        }
    ' "$CONFIG_FILE"
}

# ============================================================================
# MAIN COMMANDS
# ============================================================================

cmd_list() {
    log "Operators in current config: $CONFIG_FILE"
    echo ""
    
    local -a operators=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && operators+=("$line")
    done < <(parse_operators_simple)
    
    for op in "${operators[@]}"; do
        echo "  - $op"
    done
}

cmd_check() {
    log "Comparing current vs upstream versions..."
    log "Catalog: $CATALOG"
    echo ""
    
    printf "%-35s %-15s %-15s %-10s\n" "OPERATOR" "MIRRORED" "UPSTREAM" "STATUS"
    printf "%-35s %-15s %-15s %-10s\n" "--------" "--------" "--------" "------"
    
    # Read operators into array to avoid subshell issues
    local -a operators=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && operators+=("$line")
    done < <(parse_operators_simple)
    
    for op in "${operators[@]}"; do
        # Get current channel from config (channel lines have 12+ spaces, operator lines have 8)
        local channel
        channel=$(grep -A5 "name: ${op}$" "$CONFIG_FILE" 2>/dev/null | grep -E "^[[:space:]]{12,}- name:" | head -1 | sed 's/.*- name: //' | tr -d "'" | tr -d '"')
        
        if [[ -z "$channel" ]]; then
            channel=$(get_default_channel "$op") || channel="unknown"
        fi
        
        local current_version
        current_version=$(grep -A10 "name: ${op}$" "$CONFIG_FILE" 2>/dev/null | grep -E "minVersion:|maxVersion:" | head -1 | sed 's/.*Version: //' | tr -d "'" | tr -d '"')
        
        local upstream_version
        upstream_version=$(get_upstream_version "$op" "$channel") || upstream_version="error"
        
        local status
        if [[ "$current_version" == "$upstream_version" ]]; then
            status="${GREEN}✓ Same${NC}"
        elif [[ -z "$current_version" ]]; then
            status="${YELLOW}No version set${NC}"
        elif [[ "$upstream_version" == "error" ]] || [[ -z "$upstream_version" ]]; then
            status="${RED}✗ Query failed${NC}"
        else
            status="${YELLOW}↑ Update${NC}"
        fi
        
        printf "%-35s %-15s %-15s " "$op" "${current_version:-all}" "${upstream_version:-unknown}"
        echo -e "$status"
    done
    
    echo ""
    success "Version check complete."
}

cmd_update() {
    log "Updating imageset-config.yaml with latest versions..."
    log "Catalog: $CATALOG"
    echo ""
    
    local operators
    operators=$(parse_operators_simple)
    
    # Read OCP settings from current config
    local ocp_channel ocp_min ocp_max
    ocp_channel=$(grep -E "^\s+- name: stable-4" "$CONFIG_FILE" | head -1 | sed 's/.*- name: //' | tr -d "'" | tr -d '"')
    ocp_min=$(grep -E "minVersion:" "$CONFIG_FILE" | head -1 | sed 's/.*minVersion: //' | tr -d "'" | tr -d '"')
    ocp_max=$(grep -E "maxVersion:" "$CONFIG_FILE" | head -1 | sed 's/.*maxVersion: //' | tr -d "'" | tr -d '"')
    
    # Backup current config
    cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
    log "Backup created: ${CONFIG_FILE}.backup.*"
    
    # Generate new config
    cat > "$CONFIG_FILE" << EOF
# ImageSetConfiguration - Updated with Latest Versions
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Script: update-imageset-versions.sh
#
apiVersion: mirror.openshift.io/v2alpha1
kind: ImageSetConfiguration
mirror:
  platform:
    architectures:
      - amd64
    channels:
      - name: ${ocp_channel:-stable-4.18}
        minVersion: '${ocp_min:-4.18.14}'
        maxVersion: '${ocp_max:-4.18.16}'
    graph: true
  
  operators:
    - catalog: ${CATALOG}
      packages:
EOF

    for op in $operators; do
        # Get channel from backup config (channel lines have 12+ spaces, operator lines have 8)
        local channel
        channel=$(grep -A5 "name: $op$" "${CONFIG_FILE}.backup."* 2>/dev/null | grep -E "^[[:space:]]{12,}- name:" | head -1 | sed 's/.*- name: //' | tr -d "'" | tr -d '"')
        
        if [[ -z "$channel" ]]; then
            channel=$(get_default_channel "$op") || channel=""
        fi
        
        log "Querying $op ($channel)..."
        local version
        version=$(get_upstream_version "$op" "$channel")
        
        if [[ -n "$version" ]]; then
            success "  -> $version"
            cat >> "$CONFIG_FILE" << EOF
        # $op - latest: $version
        - name: $op
          channels:
            - name: $channel
              minVersion: '$version'
              maxVersion: '$version'
EOF
        else
            warn "  -> Could not determine version, using channel only"
            cat >> "$CONFIG_FILE" << EOF
        # $op - all versions in channel
        - name: $op
          channels:
            - name: $channel
EOF
        fi
    done
    
    echo ""
    success "Updated: $CONFIG_FILE"
    echo ""
    log "Next: Run oc-mirror to sync the updated versions"
}

cmd_add() {
    local input=$1
    local package channel
    
    # Parse input (operator or operator:channel)
    if [[ "$input" == *":"* ]]; then
        package="${input%%:*}"
        channel="${input#*:}"
    else
        package="$input"
        log "Looking up default channel for $package..."
        channel=$(get_default_channel "$package" || true)
        if [[ -z "$channel" ]]; then
            error "Could not find operator: $package"
            error "Verify the package name with: oc-mirror list operators --catalog=$CATALOG 2>&1 | grep -i <name>"
            exit 1
        fi
    fi
    
    log "Adding operator: $package (channel: $channel)"
    
    # Get latest version
    local version
    version=$(get_upstream_version "$package" "$channel")
    
    if [[ -z "$version" ]]; then
        error "Could not determine version for $package in channel $channel"
        exit 1
    fi
    
    success "Found latest version: $version"
    
    # Check if operator already exists
    if grep -q "name: $package$" "$CONFIG_FILE" 2>/dev/null; then
        warn "Operator $package already in config. Use --update to refresh versions."
        exit 0
    fi
    
    # Append to config (before the last line if needed)
    # First, backup
    cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
    
    # Append operator entry
    cat >> "$CONFIG_FILE" << EOF
        # $package - latest: $version (added $(date +%Y-%m-%d))
        - name: $package
          channels:
            - name: $channel
              minVersion: '$version'
              maxVersion: '$version'
EOF
    
    success "Added $package to $CONFIG_FILE"
    echo ""
    log "Next: Run oc-mirror to sync the new operator"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    # Handle help first (before checking requirements)
    if [[ $# -eq 0 ]] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
        usage
    fi
    
    check_requirements
    
    case "$1" in
        --list|-l)
            cmd_list
            ;;
        --check|-c)
            cmd_check
            ;;
        --update|-u)
            cmd_update
            ;;
        --add|-a)
            if [[ $# -lt 2 ]]; then
                error "Missing operator name. Usage: $0 --add <operator-name>"
                exit 1
            fi
            cmd_add "$2"
            ;;
        --help|-h)
            usage
            ;;
        *)
            error "Unknown option: $1"
            usage
            ;;
    esac
}

main "$@"

