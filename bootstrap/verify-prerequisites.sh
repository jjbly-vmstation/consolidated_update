#!/bin/bash
# verify-prerequisites.sh - Verify all prerequisites for cluster setup
# Part of VMStation Cluster Setup
#
# Features:
# - Check local tool availability
# - Verify network connectivity
# - Validate SSH access to nodes
# - Check system requirements on nodes
# - Generate verification report

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY_FILE="${INVENTORY_FILE:-$(dirname "$SCRIPT_DIR"ansible/inventory/hosts.yml}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/vmstation_cluster}"
SSH_USER="${SSH_USER:-root}"
REPORT_FILE="${REPORT_FILE:-/tmp/vmstation-prereq-report.txt}"

# Minimum requirements
MIN_MEMORY_MB=2048
MIN_DISK_GB=20
MIN_CPU_CORES=2

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Status tracking
declare -a PASSED=()
declare -a WARNINGS=()
declare -a FAILED=()

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    PASSED+=("$1")
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    WARNINGS+=("$1")
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    FAILED+=("$1")
}

# Check if command exists
check_command() {
    local cmd="$1"
    local required="${2:-true}"
    
    if command -v "$cmd" &>/dev/null; then
        local version
        version=$("$cmd" --version 2>/dev/null | head -1 || echo "unknown version")
        log_pass "$cmd is installed ($version)"
        return 0
    else
        if [[ "$required" == "true" ]]; then
            log_fail "$cmd is not installed (required)"
            return 1
        else
            log_warn "$cmd is not installed (optional)"
            return 0
        fi
    fi
}

# Check local prerequisites
check_local_prerequisites() {
    log_info "Checking local prerequisites..."
    echo ""
    
    # Required tools
    check_command "ansible" "true"
    check_command "ansible-playbook" "true"
    check_command "python3" "true"
    check_command "ssh" "true"
    check_command "ssh-keygen" "true"
    check_command "curl" "true"
    check_command "jq" "true"
    
    # Optional tools
    check_command "kubectl" "false"
    check_command "helm" "false"
    check_command "sshpass" "false"
    
    echo ""
}

# Check SSH key exists
check_ssh_key() {
    log_info "Checking SSH key..."
    
    if [[ -f "$SSH_KEY_PATH" ]]; then
        log_pass "SSH private key exists: $SSH_KEY_PATH"
    else
        log_fail "SSH private key not found: $SSH_KEY_PATH"
    fi
    
    if [[ -f "${SSH_KEY_PATH}.pub" ]]; then
        log_pass "SSH public key exists: ${SSH_KEY_PATH}.pub"
    else
        log_fail "SSH public key not found: ${SSH_KEY_PATH}.pub"
    fi
    
    echo ""
}

# Check inventory file
check_inventory() {
    log_info "Checking inventory file..."
    
    if [[ -f "$INVENTORY_FILE" ]]; then
        log_pass "Inventory file exists: $INVENTORY_FILE"
        
        # Validate YAML syntax
        if python3 -c "import yaml; yaml.safe_load(open('$INVENTORY_FILE'))" 2>/dev/null; then
            log_pass "Inventory file has valid YAML syntax"
        else
            log_fail "Inventory file has invalid YAML syntax"
        fi
        
        # Check for hosts
        local host_count
        host_count=$(grep -c 'ansible_host' "$INVENTORY_FILE" 2>/dev/null || echo "0")
        if [[ "$host_count" -gt 0 ]]; then
            log_pass "Inventory contains $host_count host(s)"
        else
            log_warn "Inventory has no hosts defined"
        fi
    else
        log_warn "Inventory file not found: $INVENTORY_FILE"
    fi
    
    echo ""
}

# Check network connectivity
check_network() {
    log_info "Checking network connectivity..."
    
    # Check internet connectivity
    if curl -s --connect-timeout 5 https://api.github.com >/dev/null; then
        log_pass "Internet connectivity OK (github.com reachable)"
    else
        log_warn "Internet connectivity limited (github.com unreachable)"
    fi
    
    # Check DNS resolution
    if host google.com &>/dev/null; then
        log_pass "DNS resolution working"
    else
        log_warn "DNS resolution may have issues"
    fi
    
    echo ""
}

# Get hosts from inventory
get_hosts_from_inventory() {
    if [[ ! -f "$INVENTORY_FILE" ]]; then
        return 1
    fi
    
    grep -oP 'ansible_host:\s*\K[\d.]+|^\s+\K[a-zA-Z][\w.-]+(?=:)' "$INVENTORY_FILE" 2>/dev/null || true
}

# Check SSH connectivity to a host
check_ssh_connectivity() {
    local host="$1"
    
    if ssh -i "$SSH_KEY_PATH" -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no \
        "${SSH_USER}@${host}" "echo 'ok'" 2>/dev/null | grep -q 'ok'; then
        log_pass "SSH to ${host} OK"
        return 0
    else
        log_fail "SSH to ${host} failed"
        return 1
    fi
}

# Check remote host requirements
check_remote_host() {
    local host="$1"
    
    log_info "Checking requirements on ${host}..."
    
    # Check SSH connectivity first
    if ! check_ssh_connectivity "$host"; then
        log_fail "Cannot check ${host} - SSH failed"
        return 1
    fi
    
    # Check memory
    local memory_kb
    memory_kb=$(ssh -i "$SSH_KEY_PATH" -o BatchMode=yes "${SSH_USER}@${host}" "grep MemTotal /proc/meminfo | awk '{print \$2}'" 2>/dev/null)
    local memory_mb=$((memory_kb / 1024))
    
    if [[ $memory_mb -ge $MIN_MEMORY_MB ]]; then
        log_pass "${host}: Memory ${memory_mb}MB >= ${MIN_MEMORY_MB}MB"
    else
        log_fail "${host}: Memory ${memory_mb}MB < ${MIN_MEMORY_MB}MB required"
    fi
    
    # Check CPU cores
    local cpu_cores
    cpu_cores=$(ssh -i "$SSH_KEY_PATH" -o BatchMode=yes "${SSH_USER}@${host}" "nproc" 2>/dev/null)
    
    if [[ $cpu_cores -ge $MIN_CPU_CORES ]]; then
        log_pass "${host}: CPU cores ${cpu_cores} >= ${MIN_CPU_CORES}"
    else
        log_fail "${host}: CPU cores ${cpu_cores} < ${MIN_CPU_CORES} required"
    fi
    
    # Check disk space
    local disk_gb
    disk_gb=$(ssh -i "$SSH_KEY_PATH" -o BatchMode=yes "${SSH_USER}@${host}" "df -BG / | tail -1 | awk '{print \$4}' | tr -d 'G'" 2>/dev/null)
    
    if [[ $disk_gb -ge $MIN_DISK_GB ]]; then
        log_pass "${host}: Available disk ${disk_gb}GB >= ${MIN_DISK_GB}GB"
    else
        log_warn "${host}: Available disk ${disk_gb}GB < ${MIN_DISK_GB}GB recommended"
    fi
    
    # Check swap status
    local swap_status
    swap_status=$(ssh -i "$SSH_KEY_PATH" -o BatchMode=yes "${SSH_USER}@${host}" "swapon --show 2>/dev/null | wc -l" 2>/dev/null)
    
    if [[ $swap_status -eq 0 ]]; then
        log_pass "${host}: Swap is disabled"
    else
        log_warn "${host}: Swap is enabled (should be disabled for Kubernetes)"
    fi
    
    echo ""
}

# Check Ansible can reach hosts
check_ansible_connectivity() {
    log_info "Checking Ansible connectivity..."
    
    if [[ ! -f "$INVENTORY_FILE" ]]; then
        log_warn "Skipping Ansible check - no inventory file"
        return 0
    fi
    
    if ansible -i "$INVENTORY_FILE" all -m ping -o 2>/dev/null | grep -q "SUCCESS"; then
        log_pass "Ansible can reach all hosts"
    else
        log_warn "Ansible ping failed for some hosts"
    fi
    
    echo ""
}

# Generate report
generate_report() {
    log_info "Generating verification report..."
    
    {
        echo "VMStation Cluster Prerequisites Verification Report"
        echo "=================================================="
        echo "Generated: $(date)"
        echo ""
        echo "Summary:"
        echo "  Passed:   ${#PASSED[@]}"
        echo "  Warnings: ${#WARNINGS[@]}"
        echo "  Failed:   ${#FAILED[@]}"
        echo ""
        
        if [[ ${#PASSED[@]} -gt 0 ]]; then
            echo "PASSED:"
            for item in "${PASSED[@]}"; do
                echo "  ✓ $item"
            done
            echo ""
        fi
        
        if [[ ${#WARNINGS[@]} -gt 0 ]]; then
            echo "WARNINGS:"
            for item in "${WARNINGS[@]}"; do
                echo "  ⚠ $item"
            done
            echo ""
        fi
        
        if [[ ${#FAILED[@]} -gt 0 ]]; then
            echo "FAILED:"
            for item in "${FAILED[@]}"; do
                echo "  ✗ $item"
            done
            echo ""
        fi
        
    } > "$REPORT_FILE"
    
    log_info "Report saved to: $REPORT_FILE"
}

# Print summary
print_summary() {
    echo ""
    echo "========================================="
    echo "Verification Summary"
    echo "========================================="
    echo ""
    echo -e "${GREEN}Passed:${NC}   ${#PASSED[@]}"
    echo -e "${YELLOW}Warnings:${NC} ${#WARNINGS[@]}"
    echo -e "${RED}Failed:${NC}   ${#FAILED[@]}"
    echo ""
    
    if [[ ${#FAILED[@]} -gt 0 ]]; then
        echo -e "${RED}Some prerequisites are not met. Please review the failures above.${NC}"
        return 1
    elif [[ ${#WARNINGS[@]} -gt 0 ]]; then
        echo -e "${YELLOW}All prerequisites met with some warnings. Review warnings above.${NC}"
        return 0
    else
        echo -e "${GREEN}All prerequisites verified successfully!${NC}"
        return 0
    fi
}

# Print usage
print_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Verify prerequisites for VMStation cluster setup.

Options:
    -i, --inventory PATH    Path to inventory file
    -k, --key PATH          SSH key path
    -u, --user USER         SSH user (default: root)
    -r, --report PATH       Report file path
    -l, --local-only        Only check local prerequisites
    -h, --help              Show this help message

Environment Variables:
    INVENTORY_FILE          Path to inventory file
    SSH_KEY_PATH            SSH key path
    SSH_USER                SSH user

Examples:
    $(basename "$0")                    # Full verification
    $(basename "$0") --local-only       # Only local checks
    $(basename "$0") -r /tmp/report.txt # Custom report path

EOF
}

# Main function
main() {
    local local_only=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--inventory)
                INVENTORY_FILE="$2"
                shift 2
                ;;
            -k|--key)
                SSH_KEY_PATH="$2"
                shift 2
                ;;
            -u|--user)
                SSH_USER="$2"
                shift 2
                ;;
            -r|--report)
                REPORT_FILE="$2"
                shift 2
                ;;
            -l|--local-only)
                local_only=true
                shift
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                log_fail "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done
    
    echo "========================================="
    echo "VMStation Prerequisites Verification"
    echo "========================================="
    echo ""
    
    # Local checks
    check_local_prerequisites
    check_ssh_key
    check_inventory
    check_network
    
    # Remote checks (if not local-only)
    if [[ "$local_only" != "true" ]]; then
        local hosts
        hosts=$(get_hosts_from_inventory)
        
        if [[ -n "$hosts" ]]; then
            for host in $hosts; do
                check_remote_host "$host"
            done
            check_ansible_connectivity
        else
            log_warn "No hosts in inventory, skipping remote checks"
        fi
    fi
    
    # Generate report and print summary
    generate_report
    print_summary
}

main "$@"
