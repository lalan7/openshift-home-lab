#!/bin/bash
# generate-imageset-config.sh
# Generates imageset-config.yaml with only the LATEST version of each operator
# Rerun this script when you want to upgrade operators to get new versions

set -e

# ============================================================================
# CONFIGURATION
# ============================================================================
CATALOG="registry.redhat.io/redhat/redhat-operator-index:v4.18"
OCP_CHANNEL="stable-4.18"
OCP_MIN_VERSION="4.18.14"
OCP_MAX_VERSION="4.18.16"
PULL_SECRET="${PULL_SECRET:-pull-secret.json}"

# ============================================================================
# HELP
# ============================================================================
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [output-file]

Generate a new imageset-config.yaml with latest operator versions.

This script creates a FRESH config file from the hardcoded operator list below.
For updating an existing config, use update-imageset-versions.sh instead.

ARGUMENTS:
  output-file           Output file path (default: imageset-config.yaml)

OPTIONS:
  --help, -h            Show this help message

ENVIRONMENT:
  PULL_SECRET           Path to pull secret (default: pull-secret.json)

HARDCODED OPERATORS:
  - cincinnati-operator (v1)
  - local-storage-operator (stable)
  - cluster-observability-operator (stable)
  - submariner (stable-0.22)
  - cluster-logging (stable-6.4)
  - elasticsearch-operator (stable-5.8)

EXAMPLES:
  $(basename "$0")                        # Generate imageset-config.yaml
  $(basename "$0") my-config.yaml         # Generate custom output file

SEE ALSO:
  update-imageset-versions.sh   # Update existing config (recommended)
  discover-operator.sh          # Find operator channels/versions

EOF
    exit 0
}

# Handle --help first
if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    usage
fi

OUTPUT_FILE="${1:-imageset-config.yaml}"

# Operators to mirror with their channels
declare -A OPERATORS=(
    ["cincinnati-operator"]="v1"
    ["local-storage-operator"]="stable"
    ["cluster-observability-operator"]="stable"
    ["submariner"]="stable-0.22"
    ["cluster-logging"]="stable-6.4"
    ["elasticsearch-operator"]="stable-5.8"
)

echo "=== Operator Version Finder ==="
echo "Catalog: ${CATALOG}"
echo ""

# Function to get latest version from catalog
get_latest_version() {
    local package=$1
    local channel=$2
    
    # Use grpcurl or opm to query catalog, or fall back to oc-mirror list
    # For simplicity, we'll use oc-mirror list with v1 (deprecated but works for listing)
    
    if command -v oc &> /dev/null; then
        # Try from connected cluster first
        version=$(oc get packagemanifest "$package" -o jsonpath="{.status.channels[?(@.name==\"$channel\")].currentCSV}" 2>/dev/null | sed 's/.*\.v//' | sed 's/-.*//')
        if [[ -n "$version" ]]; then
            echo "$version"
            return
        fi
    fi
    
    # Fallback: return empty (will use channel without version constraint)
    echo ""
}

# Function to generate operator entry
generate_operator_entry() {
    local package=$1
    local channel=$2
    local version=$3
    
    echo "        - name: ${package}"
    echo "          channels:"
    echo "            - name: ${channel}"
    if [[ -n "$version" ]]; then
        echo "              minVersion: ${version}"
        echo "              maxVersion: ${version}"
    fi
}

echo "Querying operator versions..."
echo ""

# Build operators section
OPERATORS_YAML=""
for package in "${!OPERATORS[@]}"; do
    channel="${OPERATORS[$package]}"
    echo -n "  ${package} (${channel}): "
    
    version=$(get_latest_version "$package" "$channel")
    
    if [[ -n "$version" ]]; then
        echo "v${version} ✓"
    else
        echo "(all versions - couldn't determine latest)"
    fi
    
    OPERATORS_YAML+=$(generate_operator_entry "$package" "$channel" "$version")
    OPERATORS_YAML+=$'\n'
done

# Generate the full config
cat > "${OUTPUT_FILE}" << EOF
# ImageSetConfiguration for SNO Disconnected Cluster
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# 
# This config mirrors ONLY the latest version of each operator.
# Regenerate with: ./scripts/generate-imageset-config.sh
#
apiVersion: mirror.openshift.io/v2alpha1
kind: ImageSetConfiguration
mirror:
  platform:
    architectures:
      - amd64
    channels:
      - name: ${OCP_CHANNEL}
        minVersion: ${OCP_MIN_VERSION}
        maxVersion: ${OCP_MAX_VERSION}
    graph: true
  
  operators:
    - catalog: ${CATALOG}
      packages:
${OPERATORS_YAML}
EOF

echo ""
echo "=== Generated: ${OUTPUT_FILE} ==="
echo ""
cat "${OUTPUT_FILE}"
echo ""
echo "=== Next Steps ==="
echo "1. Review the generated config above"
echo "2. Copy to servermind: scp ${OUTPUT_FILE} lab-user@servermind.home.lab:~/oc-mirror-workspace/"
echo "3. Run mirror: oc mirror --v2 --config ${OUTPUT_FILE} docker://mirror-registry.sno.local:8443/ocp4 --workspace file://./workspace --authfile pull-secret.json"
echo ""
echo "To upgrade operators later, rerun this script to get new latest versions."

