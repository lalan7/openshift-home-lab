#!/bin/bash
# discover-operator.sh
# Discover operator channels and versions from Red Hat catalog
#
# Two modes:
#   1. UPSTREAM MODE (default): Query Red Hat registry directly (needs internet + pull-secret)
#   2. CLUSTER MODE (--cluster): Query from connected cluster (needs KUBECONFIG)
#
# Usage:
#   ./discover-operator.sh --all                    # List all operators from Red Hat catalog
#   ./discover-operator.sh cluster-logging          # Show details for specific operator
#   ./discover-operator.sh --cluster --all          # Query from connected cluster instead
#
# Requirements (upstream mode):
#   - oc-mirror tool installed
#   - REGISTRY_AUTH_FILE set or pull-secret.json in workspace
#   - Internet access to registry.redhat.io

set -euo pipefail

# Configuration
OCP_VERSION="${OCP_VERSION:-4.18}"
CATALOG="registry.redhat.io/redhat/redhat-operator-index:v${OCP_VERSION}"
PULL_SECRET="${REGISTRY_AUTH_FILE:-./pull-secret.json}"
USE_CLUSTER=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] <operator-name|--all>

Discover operator channels and versions from Red Hat catalog.

OPTIONS:
  --all, -a           List all available operators
  --cluster, -c       Query from connected cluster (needs KUBECONFIG)
  --version <ver>     OCP version for catalog (default: 4.18)
  --help, -h          Show this help

EXAMPLES:
  $(basename "$0") --all                      # List all operators from Red Hat catalog
  $(basename "$0") cluster-logging            # Show details for cluster-logging
  $(basename "$0") --version 4.17 --all       # Query 4.17 catalog
  $(basename "$0") --cluster --all            # Query from connected cluster

ENVIRONMENT:
  REGISTRY_AUTH_FILE  Path to pull secret (default: ./pull-secret.json)
  OCP_VERSION         OCP version for catalog (default: 4.18)

EOF
    exit 0
}

check_upstream_requirements() {
    if ! command -v oc-mirror &>/dev/null; then
        echo -e "${RED}ERROR:${NC} oc-mirror not found. Install it first."
        exit 1
    fi
    if [[ ! -f "$PULL_SECRET" ]]; then
        echo -e "${RED}ERROR:${NC} Pull secret not found: $PULL_SECRET"
        echo "Set REGISTRY_AUTH_FILE or place pull-secret.json in current directory"
        exit 1
    fi
    export REGISTRY_AUTH_FILE="$PULL_SECRET"
}

check_cluster_requirements() {
    if ! command -v oc &> /dev/null; then
        echo -e "${RED}ERROR:${NC} 'oc' command not found."
        exit 1
    fi
    if ! oc whoami &> /dev/null; then
        echo -e "${RED}ERROR:${NC} Not logged into cluster. Set KUBECONFIG or run 'oc login'"
        exit 1
    fi
}

# ============================================================================
# UPSTREAM MODE (query Red Hat registry directly)
# ============================================================================

list_all_upstream() {
    echo -e "${BLUE}Querying Red Hat Operator Catalog: ${CATALOG}${NC}"
    echo "=============================================="
    echo ""
    oc-mirror list operators --catalog="$CATALOG" 2>/dev/null | head -100
    echo ""
    echo -e "${YELLOW}Note:${NC} Showing first 100 operators. Use './$(basename "$0") <name>' for details."
}

discover_upstream() {
    local OP=$1
    
    echo -e "${BLUE}Querying: ${CATALOG}${NC}"
    echo "=============================================="
    echo -e " Operator: ${GREEN}$OP${NC}"
    echo "=============================================="
    echo ""
    
    # Get channels
    echo "Available Channels:"
    local channels
    channels=$(oc-mirror list operators --catalog="$CATALOG" --package="$OP" 2>/dev/null)
    
    if [[ -z "$channels" ]]; then
        echo -e "${RED}ERROR:${NC} Operator '$OP' not found in catalog"
        echo ""
        echo "Search for similar operators:"
        oc-mirror list operators --catalog="$CATALOG" 2>/dev/null | grep -i "$OP" | head -10 || echo "  No matches"
        exit 1
    fi
    
    echo "$channels"
    echo ""
    
    # Get default channel (first one listed is usually default)
    local DEFAULT_CHANNEL
    DEFAULT_CHANNEL=$(echo "$channels" | grep -v "^PACKAGE\|^NAME\|^CHANNEL\|^$" | head -1 | awk '{print $2}')
    
    if [[ -z "$DEFAULT_CHANNEL" ]]; then
        DEFAULT_CHANNEL=$(echo "$channels" | grep -v "^$" | tail -1 | awk '{print $1}')
    fi
    
    # Get latest version in default channel
    echo "Versions in channel '$DEFAULT_CHANNEL':"
    local versions
    versions=$(oc-mirror list operators --catalog="$CATALOG" --package="$OP" --channel="$DEFAULT_CHANNEL" 2>/dev/null)
    echo "$versions" | head -20
    
    # Get latest version (last line after sorting)
    local LATEST_VERSION
    LATEST_VERSION=$(echo "$versions" | grep -E '^[0-9]' | sort -V | tail -1)
    
    echo ""
    echo "=============================================="
    echo " ImageSetConfiguration Example"
    echo "=============================================="
    echo ""
    echo "# For imageset-config.yaml:"
    echo "- name: $OP"
    echo "  channels:"
    echo "    - name: $DEFAULT_CHANNEL"
    if [[ -n "$LATEST_VERSION" ]]; then
        echo "      minVersion: '$LATEST_VERSION'"
        echo "      maxVersion: '$LATEST_VERSION'"
    fi
    echo ""
}

# ============================================================================
# CLUSTER MODE (query from connected cluster)
# ============================================================================

list_all_cluster() {
    echo -e "${BLUE}Querying cluster: $(oc whoami --show-server 2>/dev/null)${NC}"
    echo "=============================================="
    oc get packagemanifest -n openshift-marketplace \
        --sort-by=.metadata.name \
        -o custom-columns="NAME:.metadata.name,CATALOG:.status.catalogSource,DEFAULT_CHANNEL:.status.defaultChannel"
    echo ""
    echo "Usage: $0 <operator-name> for details"
}

discover_cluster() {
    local OP=$1
    
    if ! oc get packagemanifest "$OP" -n openshift-marketplace &> /dev/null; then
        echo -e "${RED}ERROR:${NC} Operator '$OP' not found"
        echo ""
        echo "Search for similar operators:"
        oc get packagemanifest -n openshift-marketplace -o name | grep -i "${OP}" | sed 's|packagemanifest.packages.operators.coreos.com/||' || echo "  No matches"
        exit 1
    fi
    
    echo "=============================================="
    echo -e " Operator: ${GREEN}$OP${NC}"
    echo "=============================================="
    echo ""
    
    oc get packagemanifest "$OP" -n openshift-marketplace -o json | jq -r '
      .status | 
      "Default Channel: \(.defaultChannel)",
      "",
      "Available Channels:",
      (.channels | sort_by(.name) | .[] | 
        "  - \(.name): \(.currentCSV)"
      )'
    
    echo ""
    echo "=============================================="
    echo " ImageSetConfiguration Example"
    echo "=============================================="
    
    local DEFAULT_CHANNEL=$(oc get packagemanifest "$OP" -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')
    local CURRENT_CSV=$(oc get packagemanifest "$OP" -n openshift-marketplace -o jsonpath="{.status.channels[?(@.name==\"$DEFAULT_CHANNEL\")].currentCSV}")
    local VERSION=$(echo "$CURRENT_CSV" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?' | head -1)
    
    echo ""
    echo "# For imageset-config.yaml:"
    echo "- name: $OP"
    echo "  channels:"
    echo "    - name: $DEFAULT_CHANNEL"
    if [[ -n "$VERSION" ]]; then
        echo "      minVersion: '$VERSION'"
        echo "      maxVersion: '$VERSION'"
    fi
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

# Parse arguments
OPERATOR=""
LIST_ALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            usage
            ;;
        --cluster|-c)
            USE_CLUSTER=true
            shift
            ;;
        --version|-v)
            OCP_VERSION="$2"
            CATALOG="registry.redhat.io/redhat/redhat-operator-index:v${OCP_VERSION}"
            shift 2
            ;;
        --all|-a)
            LIST_ALL=true
            shift
            ;;
        -*)
            echo -e "${RED}ERROR:${NC} Unknown option: $1"
            usage
            ;;
        *)
            OPERATOR="$1"
            shift
            ;;
    esac
done

# Validate arguments
if [[ "$LIST_ALL" == "false" && -z "$OPERATOR" ]]; then
    usage
fi

# Execute
if [[ "$USE_CLUSTER" == "true" ]]; then
    check_cluster_requirements
    if [[ "$LIST_ALL" == "true" ]]; then
        list_all_cluster
    else
        discover_cluster "$OPERATOR"
    fi
else
    check_upstream_requirements
    if [[ "$LIST_ALL" == "true" ]]; then
        list_all_upstream
    else
        discover_upstream "$OPERATOR"
    fi
fi

