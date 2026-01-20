#!/bin/bash
# check-registry-space.sh - Quick check of mirror-registry disk space
# Usage: ./check-registry-space.sh [--watch]

set -euo pipefail

REGISTRY_VM="mirror-registry"
WARN_THRESHOLD=20  # GB - warn if less than this available

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

check_space() {
    echo "=== Mirror Registry Disk Space ==="
    echo ""
    
    # Get disk info
    local output
    output=$(kcli ssh "$REGISTRY_VM" "df -h / | tail -1" 2>/dev/null)
    
    # Parse values
    local size used avail percent
    read -r _ size used avail percent _ <<< "$output"
    
    # Remove % sign for comparison
    local percent_num=${percent%\%}
    local avail_num=${avail%G}
    
    # Display
    printf "Total:     %s\n" "$size"
    printf "Used:      %s (%s)\n" "$used" "$percent"
    
    # Color based on available space
    if [[ "${avail: -1}" == "G" ]] && (( ${avail_num%.*} < WARN_THRESHOLD )); then
        printf "Available: ${RED}%s${NC} ⚠️  LOW SPACE!\n" "$avail"
    elif (( percent_num > 80 )); then
        printf "Available: ${YELLOW}%s${NC}\n" "$avail"
    else
        printf "Available: ${GREEN}%s${NC} ✅\n" "$avail"
    fi
    
    echo ""
    
    # Get registry data size
    local registry_size
    registry_size=$(kcli ssh "$REGISTRY_VM" "sudo du -sh /var/lib/containers 2>/dev/null | cut -f1" 2>/dev/null || echo "N/A")
    printf "Registry data: %s\n" "$registry_size"
    
    echo ""
    echo "$(date '+%Y-%m-%d %H:%M:%S')"
}

# Watch mode - refresh every 30 seconds
if [[ "${1:-}" == "--watch" ]] || [[ "${1:-}" == "-w" ]]; then
    echo "Watching disk space (Ctrl+C to stop)..."
    echo ""
    while true; do
        clear
        check_space
        sleep 30
    done
else
    check_space
fi

