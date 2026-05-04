#!/bin/bash
# setup-ssh-keys.sh - Configure SSH keys for cluster node access
# Part of VMStation Cluster Setup
#
# Features:
# - Generate SSH key pair if not exists
# - Distribute keys to all cluster nodes
# - Configure SSH config for easy access
# - Validate SSH connectivity

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/vmstation_cluster}"
SSH_KEY_TYPE="${SSH_KEY_TYPE:-ed25519}"
SSH_KEY_COMMENT="${SSH_KEY_COMMENT:-vmstation-cluster-$(date +%Y%m%d)}"
SSH_CONFIG_FILE="${SSH_CONFIG_FILE:-$HOME/.ssh/config}"
INVENTORY_FILE="${INVENTORY_FILE:-$(dirname "$SCRIPT_DIR"ansible/inventory/hosts.yml}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

# Generate SSH key pair
generate_ssh_key() {
    if [[ -f "${SSH_KEY_PATH}" ]]; then
        log_info "SSH key already exists at ${SSH_KEY_PATH}"
        read -rp "Regenerate key? [y/N] " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            log_info "Using existing SSH key"
            return 0
        fi
        # Backup existing key
        mv "${SSH_KEY_PATH}" "${SSH_KEY_PATH}.bak.$(date +%Y%m%d%H%M%S)"
        mv "${SSH_KEY_PATH}.pub" "${SSH_KEY_PATH}.pub.bak.$(date +%Y%m%d%H%M%S)"
    fi
    
    log_info "Generating new SSH key pair..."
    mkdir -p "$(dirname "$SSH_KEY_PATH")"
    ssh-keygen -t "$SSH_KEY_TYPE" -f "$SSH_KEY_PATH" -C "$SSH_KEY_COMMENT" -N ""
    chmod 600 "$SSH_KEY_PATH"
    chmod 644 "${SSH_KEY_PATH}.pub"
    log_success "SSH key pair generated at ${SSH_KEY_PATH}"
}

# Parse hosts from inventory file
get_hosts_from_inventory() {
    if [[ ! -f "$INVENTORY_FILE" ]]; then
        log_error "Inventory file not found: $INVENTORY_FILE"
        return 1
    fi
    
    # Extract host IPs/hostnames from YAML inventory
    # Supports both IP addresses and hostnames
    grep -oP 'ansible_host:\s*\K[\d.]+|^\s+\K[a-zA-Z][\w.-]+(?=:)' "$INVENTORY_FILE" 2>/dev/null || true
}

# Distribute SSH key to a single host
distribute_key_to_host() {
    local host="$1"
    local user="${2:-root}"
    local password="${3:-}"
    
    log_info "Distributing SSH key to ${user}@${host}..."
    
    local result=0
    if [[ -n "$password" ]]; then
        # Use sshpass if password is provided
        sshpass -p "$password" ssh-copy-id -i "${SSH_KEY_PATH}.pub" -o StrictHostKeyChecking=no "${user}@${host}" || result=1
    else
        # Interactive password prompt
        ssh-copy-id -i "${SSH_KEY_PATH}.pub" -o StrictHostKeyChecking=no "${user}@${host}" || result=1
    fi
    
    if [[ $result -eq 0 ]]; then
        log_success "Key distributed to ${host}"
        return 0
    else
        log_error "Failed to distribute key to ${host}"
        return 1
    fi
}

# Configure SSH config file
configure_ssh_config() {
    local host_alias="$1"
    local hostname="$2"
    local user="${3:-root}"
    
    # Create SSH config entry
    local config_entry="
# VMStation Cluster - ${host_alias}
Host ${host_alias}
    HostName ${hostname}
    User ${user}
    IdentityFile ${SSH_KEY_PATH}
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
"
    
    # Check if entry already exists
    if grep -q "Host ${host_alias}$" "$SSH_CONFIG_FILE" 2>/dev/null; then
        log_info "SSH config entry for ${host_alias} already exists"
        return 0
    fi
    
    # Append to SSH config
    mkdir -p "$(dirname "$SSH_CONFIG_FILE")"
    echo "$config_entry" >> "$SSH_CONFIG_FILE"
    chmod 600 "$SSH_CONFIG_FILE"
    log_success "Added SSH config entry for ${host_alias}"
}

# Validate SSH connectivity
validate_ssh_connection() {
    local host="$1"
    local user="${2:-root}"
    
    log_info "Validating SSH connection to ${user}@${host}..."
    
    if ssh -i "$SSH_KEY_PATH" -o ConnectTimeout=10 -o BatchMode=yes "${user}@${host}" "echo 'SSH connection successful'" 2>/dev/null; then
        log_success "SSH connection to ${host} verified"
        return 0
    else
        log_error "SSH connection to ${host} failed"
        return 1
    fi
}

# Interactive mode for adding hosts
interactive_add_hosts() {
    local hosts=()
    
    echo ""
    log_info "Enter cluster node hostnames or IPs (empty line to finish):"
    
    while true; do
        read -rp "Host: " host
        if [[ -z "$host" ]]; then
            break
        fi
        hosts+=("$host")
    done
    
    if [[ ${#hosts[@]} -eq 0 ]]; then
        log_warning "No hosts provided"
        return 1
    fi
    
    read -rp "SSH user for all hosts [root]: " ssh_user
    ssh_user="${ssh_user:-root}"
    
    read -rsp "SSH password (leave empty for key-based auth): " ssh_password
    echo ""
    
    for host in "${hosts[@]}"; do
        distribute_key_to_host "$host" "$ssh_user" "$ssh_password"
        configure_ssh_config "vmstation-${host//[^a-zA-Z0-9]/-}" "$host" "$ssh_user"
    done
}

# Print usage
print_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [COMMAND]

Configure SSH keys for VMStation cluster nodes.

Commands:
    generate        Generate new SSH key pair
    distribute      Distribute keys to nodes from inventory
    validate        Validate SSH connectivity to all nodes
    interactive     Interactive mode to add hosts
    all             Run all steps (default)

Options:
    -k, --key-path PATH     Path for SSH key (default: ~/.ssh/vmstation_cluster)
    -i, --inventory PATH    Path to inventory file
    -u, --user USER         SSH user for distribution
    -h, --help              Show this help message

Environment Variables:
    SSH_KEY_PATH            Same as --key-path
    SSH_KEY_TYPE            SSH key type (default: ed25519)
    INVENTORY_FILE          Same as --inventory

Examples:
    $(basename "$0")                          # Run all steps using inventory
    $(basename "$0") generate                 # Only generate SSH key
    $(basename "$0") interactive              # Interactive host addition
    $(basename "$0") --user admin distribute  # Distribute as 'admin' user

EOF
}

# Main function
main() {
    local command="all"
    local ssh_user="root"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -k|--key-path)
                SSH_KEY_PATH="$2"
                shift 2
                ;;
            -i|--inventory)
                INVENTORY_FILE="$2"
                shift 2
                ;;
            -u|--user)
                ssh_user="$2"
                shift 2
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            generate|distribute|validate|interactive|all)
                command="$1"
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done
    
    log_info "SSH Key Setup for VMStation Cluster"
    echo ""
    
    case "$command" in
        generate)
            generate_ssh_key
            ;;
        distribute)
            if [[ ! -f "${SSH_KEY_PATH}.pub" ]]; then
                log_error "SSH public key not found. Run 'generate' first."
                exit 1
            fi
            local hosts
            hosts=$(get_hosts_from_inventory)
            if [[ -z "$hosts" ]]; then
                log_error "No hosts found in inventory"
                exit 1
            fi
            for host in $hosts; do
                distribute_key_to_host "$host" "$ssh_user"
                configure_ssh_config "vmstation-${host//[^a-zA-Z0-9]/-}" "$host" "$ssh_user"
            done
            ;;
        validate)
            local hosts
            hosts=$(get_hosts_from_inventory)
            local failed=0
            for host in $hosts; do
                if ! validate_ssh_connection "$host" "$ssh_user"; then
                    ((failed++))
                fi
            done
            if [[ $failed -gt 0 ]]; then
                log_error "$failed host(s) failed validation"
                exit 1
            fi
            ;;
        interactive)
            generate_ssh_key
            interactive_add_hosts
            ;;
        all)
            generate_ssh_key
            echo ""
            if [[ -f "$INVENTORY_FILE" ]]; then
                local hosts
                hosts=$(get_hosts_from_inventory)
                if [[ -n "$hosts" ]]; then
                    for host in $hosts; do
                        distribute_key_to_host "$host" "$ssh_user" || true
                        configure_ssh_config "vmstation-${host//[^a-zA-Z0-9]/-}" "$host" "$ssh_user"
                    done
                    echo ""
                    for host in $hosts; do
                        validate_ssh_connection "$host" "$ssh_user" || true
                    done
                else
                    log_warning "No hosts in inventory. Use 'interactive' mode to add hosts."
                fi
            else
                log_warning "Inventory file not found. Use 'interactive' mode to add hosts."
            fi
            ;;
    esac
    
    echo ""
    log_success "SSH key setup complete!"
}

main "$@"
