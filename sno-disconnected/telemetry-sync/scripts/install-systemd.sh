#!/bin/bash
# =============================================================================
# install-systemd.sh - Install Systemd Units for Telemetry Sync
# =============================================================================
# Part of: SNO Disconnected Telemetry Sync
# Purpose: Installs and enables systemd service and timer units
#
# Usage: ./install-systemd.sh [--uninstall]
#
# Requirements:
#   - Run as the user that will execute telemetry sync
#   - User systemd session must be enabled (loginctl enable-linger $USER)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# -----------------------------------------------------------------------------
# Uninstall
# -----------------------------------------------------------------------------
uninstall() {
    log_info "Uninstalling telemetry sync systemd units..."
    
    # Stop and disable timers
    systemctl --user stop telemetry-sync.timer 2>/dev/null || true
    systemctl --user stop telemetry-retry.timer 2>/dev/null || true
    systemctl --user disable telemetry-sync.timer 2>/dev/null || true
    systemctl --user disable telemetry-retry.timer 2>/dev/null || true
    
    # Remove unit files
    rm -f "${SYSTEMD_USER_DIR}/telemetry-sync.service"
    rm -f "${SYSTEMD_USER_DIR}/telemetry-sync.timer"
    rm -f "${SYSTEMD_USER_DIR}/telemetry-retry.service"
    rm -f "${SYSTEMD_USER_DIR}/telemetry-retry.timer"
    
    # Reload
    systemctl --user daemon-reload
    
    log_info "Uninstall complete"
    exit 0
}

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------
preflight_checks() {
    log_info "Running pre-flight checks..."
    
    # Check if systemd user session is available
    if ! systemctl --user status &>/dev/null; then
        log_error "systemd user session not available"
        log_error "You may need to SSH with a full session or run: loginctl enable-linger ${USER}"
        exit 1
    fi
    
    # Check if scripts exist and are executable
    for script in gather-insights.sh upload-insights.sh process-queue.sh health-check.sh; do
        if [[ ! -x "${SCRIPT_DIR}/${script}" ]]; then
            log_warn "Making ${script} executable"
            chmod +x "${SCRIPT_DIR}/${script}"
        fi
    done
    
    # Check if config exists
    if [[ ! -f "${PROJECT_DIR}/config/telemetry-sync.env" ]]; then
        log_warn "Configuration file not found"
        log_warn "Copy and edit: ${PROJECT_DIR}/config/telemetry-sync.env.template"
        log_warn "              → ${PROJECT_DIR}/config/telemetry-sync.env"
    fi
    
    log_info "Pre-flight checks passed"
}

# -----------------------------------------------------------------------------
# Install
# -----------------------------------------------------------------------------
install() {
    log_info "Installing telemetry sync systemd units..."
    
    # Create systemd user directory
    mkdir -p "${SYSTEMD_USER_DIR}"
    
    # Copy unit files
    log_info "Copying unit files to ${SYSTEMD_USER_DIR}/"
    
    cp "${PROJECT_DIR}/systemd/telemetry-sync.service" "${SYSTEMD_USER_DIR}/"
    cp "${PROJECT_DIR}/systemd/telemetry-sync.timer" "${SYSTEMD_USER_DIR}/"
    cp "${PROJECT_DIR}/systemd/telemetry-retry.service" "${SYSTEMD_USER_DIR}/"
    cp "${PROJECT_DIR}/systemd/telemetry-retry.timer" "${SYSTEMD_USER_DIR}/"
    
    # Reload systemd
    log_info "Reloading systemd daemon..."
    systemctl --user daemon-reload
    
    # Enable timers
    log_info "Enabling timers..."
    systemctl --user enable telemetry-sync.timer
    systemctl --user enable telemetry-retry.timer
    
    # Start timers
    log_info "Starting timers..."
    systemctl --user start telemetry-sync.timer
    systemctl --user start telemetry-retry.timer
    
    log_info "Installation complete!"
}

# -----------------------------------------------------------------------------
# Show status
# -----------------------------------------------------------------------------
show_status() {
    echo ""
    echo "=========================================="
    echo "TELEMETRY SYNC - SYSTEMD STATUS"
    echo "=========================================="
    echo ""
    
    echo "Timers:"
    systemctl --user list-timers telemetry-sync.timer telemetry-retry.timer 2>/dev/null || true
    echo ""
    
    echo "Services:"
    systemctl --user status telemetry-sync.service --no-pager 2>/dev/null | head -5 || true
    systemctl --user status telemetry-retry.service --no-pager 2>/dev/null | head -5 || true
    echo ""
    
    echo "=========================================="
    echo "USEFUL COMMANDS"
    echo "=========================================="
    echo ""
    echo "# Check timer schedule:"
    echo "  systemctl --user list-timers"
    echo ""
    echo "# View logs:"
    echo "  journalctl --user -u telemetry-sync.service -f"
    echo ""
    echo "# Manual run:"
    echo "  systemctl --user start telemetry-sync.service"
    echo ""
    echo "# Health check:"
    echo "  ${SCRIPT_DIR}/health-check.sh"
    echo ""
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    echo "=========================================="
    echo "TELEMETRY SYNC - SYSTEMD INSTALLER"
    echo "=========================================="
    echo ""
    
    if [[ "${1:-}" == "--uninstall" ]]; then
        uninstall
    fi
    
    preflight_checks
    install
    show_status
}

main "$@"

