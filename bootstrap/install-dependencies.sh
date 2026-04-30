#!/bin/bash
# install-dependencies.sh - Install required dependencies for cluster setup
# Part of VMStation Cluster Setup
# 
# Features:
# - Supports multiple package managers (apt, dnf, yum)
# - Version checking
# - Idempotent operations
# - Rollback capability

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/.install-state"
ROLLBACK_FILE="${SCRIPT_DIR}/.rollback-log"
FORCE_INSTALL="${FORCE_INSTALL:-false}"
DRY_RUN="${DRY_RUN:-false}"

# Required dependencies
REQUIRED_PACKAGES=(
    "ansible"
    "python3"
    "python3-pip"
    "curl"
    "wget"
    "jq"
    "sshpass"
    "git"
)

# Minimum versions (package=version)
declare -A MIN_VERSIONS=(
    ["ansible"]="2.9.0"
    ["python3"]="3.8.0"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Detect package manager
detect_package_manager() {
    if command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v yum &>/dev/null; then
        echo "yum"
    else
        log_error "No supported package manager found (apt, dnf, yum)"
        exit 1
    fi
}

# Compare versions (returns 0 if version1 >= version2)
version_gte() {
    local version1="$1"
    local version2="$2"
    printf '%s\n%s\n' "$version2" "$version1" | sort -V -C
}

# Get installed version of a package
get_installed_version() {
    local package="$1"
    case "$package" in
        ansible)
            ansible --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0"
            ;;
        python3)
            python3 --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "0.0.0"
            ;;
        *)
            echo "0.0.0"
            ;;
    esac
}

# Check if package is installed
is_installed() {
    local package="$1"
    command -v "$package" &>/dev/null || dpkg -l "$package" &>/dev/null 2>&1 || rpm -q "$package" &>/dev/null 2>&1
}

# Check if package needs update
needs_update() {
    local package="$1"
    
    if [[ "$FORCE_INSTALL" == "true" ]]; then
        return 0
    fi
    
    if ! is_installed "$package"; then
        return 0
    fi
    
    if [[ -v MIN_VERSIONS[$package] ]]; then
        local installed_version
        installed_version=$(get_installed_version "$package")
        local min_version="${MIN_VERSIONS[$package]}"
        
        if ! version_gte "$installed_version" "$min_version"; then
            log_info "$package version $installed_version is below minimum $min_version"
            return 0
        fi
    fi
    
    return 1
}

# Install package using detected package manager
install_package() {
    local package="$1"
    local pkg_manager
    pkg_manager=$(detect_package_manager)
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would install: $package"
        return 0
    fi
    
    log_info "Installing $package..."
    
    case "$pkg_manager" in
        apt)
            sudo apt-get install -y "$package"
            ;;
        dnf)
            sudo dnf install -y "$package"
            ;;
        yum)
            sudo yum install -y "$package"
            ;;
    esac
    
    # Record for rollback
    echo "$package" >> "$ROLLBACK_FILE"
}

# Update package cache
update_package_cache() {
    local pkg_manager
    pkg_manager=$(detect_package_manager)
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would update package cache"
        return 0
    fi
    
    log_info "Updating package cache..."
    
    case "$pkg_manager" in
        apt)
            sudo apt-get update
            ;;
        dnf)
            sudo dnf check-update || true
            ;;
        yum)
            sudo yum check-update || true
            ;;
    esac
}

# Install Ansible collections
install_ansible_collections() {
    local collections=(
        "ansible.posix"
        "community.general"
        "kubernetes.core"
    )
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would install Ansible collections: ${collections[*]}"
        return 0
    fi
    
    log_info "Installing Ansible collections..."
    for collection in "${collections[@]}"; do
        ansible-galaxy collection install "$collection" --upgrade
    done
}

# Save state
save_state() {
    local step="$1"
    echo "$step" >> "$STATE_FILE"
}

# Check if step was completed
step_completed() {
    local step="$1"
    if [[ -f "$STATE_FILE" ]]; then
        grep -qxF "$step" "$STATE_FILE"
    else
        return 1
    fi
}

# Rollback installations
rollback() {
    if [[ ! -f "$ROLLBACK_FILE" ]]; then
        log_warning "No rollback log found"
        return 0
    fi
    
    log_warning "Rolling back installations..."
    local pkg_manager
    pkg_manager=$(detect_package_manager)
    
    while IFS= read -r package; do
        log_info "Removing $package..."
        case "$pkg_manager" in
            apt)
                sudo apt-get remove -y "$package" || true
                ;;
            dnf)
                sudo dnf remove -y "$package" || true
                ;;
            yum)
                sudo yum remove -y "$package" || true
                ;;
        esac
    done < "$ROLLBACK_FILE"
    
    rm -f "$ROLLBACK_FILE" "$STATE_FILE"
    log_success "Rollback complete"
}

# Print usage
print_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Install dependencies required for VMStation cluster setup.

Options:
    -f, --force       Force reinstallation of all packages
    -d, --dry-run     Show what would be installed without making changes
    -r, --rollback    Rollback previously installed packages
    -h, --help        Show this help message

Environment Variables:
    FORCE_INSTALL     Same as --force (true/false)
    DRY_RUN           Same as --dry-run (true/false)

Examples:
    $(basename "$0")              # Normal installation
    $(basename "$0") --force      # Force reinstall
    $(basename "$0") --dry-run    # Preview changes
    $(basename "$0") --rollback   # Undo installations

EOF
}

# Main function
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--force)
                FORCE_INSTALL="true"
                shift
                ;;
            -d|--dry-run)
                DRY_RUN="true"
                shift
                ;;
            -r|--rollback)
                rollback
                exit 0
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done
    
    log_info "Starting dependency installation..."
    log_info "Package manager: $(detect_package_manager)"
    
    # Initialize rollback file
    if [[ "$DRY_RUN" != "true" ]]; then
        : > "$ROLLBACK_FILE"
    fi
    
    # Update package cache
    if ! step_completed "cache_updated" || [[ "$FORCE_INSTALL" == "true" ]]; then
        update_package_cache
        save_state "cache_updated"
    else
        log_info "Package cache already updated (skipping)"
    fi
    
    # Install required packages
    local installed_count=0
    local skipped_count=0
    
    for package in "${REQUIRED_PACKAGES[@]}"; do
        if needs_update "$package"; then
            install_package "$package"
            ((installed_count++))
        else
            log_info "$package is already installed and up to date (skipping)"
            ((skipped_count++))
        fi
    done
    
    # Install Ansible collections
    if is_installed "ansible"; then
        install_ansible_collections
    fi
    
    # Summary
    echo ""
    log_success "Dependency installation complete!"
    log_info "Installed: $installed_count packages"
    log_info "Skipped: $skipped_count packages"
    
    # Clean up state if successful
    if [[ "$DRY_RUN" != "true" ]]; then
        rm -f "$STATE_FILE"
    fi
}

main "$@"
