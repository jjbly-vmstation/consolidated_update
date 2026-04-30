#!/bin/bash
# prepare-nodes.sh - Prepare cluster nodes for deployment
# Part of VMStation Cluster Setup
#
# Features:
# - Update system packages
# - Configure hostnames and hosts file
# - Set up required kernel parameters
# - Configure firewall rules
# - Install container runtime prerequisites

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY_FILE="${INVENTORY_FILE:-$(dirname "$SCRIPT_DIR"ansible/inventory/hosts.yml}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/vmstation_cluster}"
SSH_USER="${SSH_USER:-root}"
DRY_RUN="${DRY_RUN:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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

log_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

# Execute command on remote host
remote_exec() {
    local host="$1"
    local cmd="$2"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would execute on ${host}: $cmd"
        return 0
    fi
    
    ssh -i "$SSH_KEY_PATH" -o ConnectTimeout=30 -o StrictHostKeyChecking=no "${SSH_USER}@${host}" "$cmd"
}

# Parse hosts from inventory
get_hosts_from_inventory() {
    if [[ ! -f "$INVENTORY_FILE" ]]; then
        log_error "Inventory file not found: $INVENTORY_FILE"
        return 1
    fi
    
    grep -oP 'ansible_host:\s*\K[\d.]+|^\s+\K[a-zA-Z][\w.-]+(?=:)' "$INVENTORY_FILE" 2>/dev/null || true
}

# Detect remote OS
detect_remote_os() {
    local host="$1"
    
    local os_id
    os_id=$(remote_exec "$host" "cat /etc/os-release | grep '^ID=' | cut -d= -f2 | tr -d '\"'" 2>/dev/null)
    echo "$os_id"
}

# Update system packages on remote host
update_system_packages() {
    local host="$1"
    local os_id="$2"
    
    log_info "Updating system packages on ${host}..."
    
    case "$os_id" in
        ubuntu|debian)
            remote_exec "$host" "apt-get update && apt-get upgrade -y"
            ;;
        centos|rhel|rocky|almalinux)
            remote_exec "$host" "yum update -y || dnf update -y"
            ;;
        fedora)
            remote_exec "$host" "dnf update -y"
            ;;
        *)
            log_warning "Unknown OS: $os_id, skipping package update"
            ;;
    esac
}

# Configure kernel parameters for Kubernetes
configure_kernel_params() {
    local host="$1"
    
    log_info "Configuring kernel parameters on ${host}..."
    
    # Kernel parameters required for Kubernetes
    local kernel_params="
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
"
    
    remote_exec "$host" "cat > /etc/sysctl.d/99-kubernetes.conf << 'EOF'
${kernel_params}
EOF"
    
    # Load required kernel modules
    remote_exec "$host" "modprobe br_netfilter && modprobe overlay"
    
    # Ensure modules are loaded on boot
    remote_exec "$host" "cat > /etc/modules-load.d/kubernetes.conf << 'EOF'
br_netfilter
overlay
EOF"
    
    # Apply sysctl parameters
    remote_exec "$host" "sysctl --system"
    
    log_success "Kernel parameters configured on ${host}"
}

# Disable swap (required for Kubernetes)
disable_swap() {
    local host="$1"
    
    log_info "Disabling swap on ${host}..."
    
    remote_exec "$host" "swapoff -a"
    remote_exec "$host" "sed -i '/swap/d' /etc/fstab"
    
    log_success "Swap disabled on ${host}"
}

# Configure firewall rules
configure_firewall() {
    local host="$1"
    local node_type="${2:-worker}" # master or worker
    
    log_info "Configuring firewall on ${host} (${node_type})..."
    
    # Check if firewall is active
    local firewall_active
    firewall_active=$(remote_exec "$host" "systemctl is-active firewalld 2>/dev/null || systemctl is-active ufw 2>/dev/null || echo 'inactive'")
    
    if [[ "$firewall_active" == "inactive" ]]; then
        log_info "No active firewall detected on ${host}"
        return 0
    fi
    
    # Common Kubernetes ports
    local common_ports=(
        "10250/tcp"  # Kubelet API
        "10255/tcp"  # Read-only Kubelet API
        "30000-32767/tcp"  # NodePort Services
    )
    
    # Master-specific ports
    local master_ports=(
        "6443/tcp"   # Kubernetes API
        "2379-2380/tcp"  # etcd
        "10251/tcp"  # kube-scheduler
        "10252/tcp"  # kube-controller-manager
    )
    
    # Open common ports
    for port in "${common_ports[@]}"; do
        remote_exec "$host" "firewall-cmd --permanent --add-port=${port} 2>/dev/null || ufw allow ${port} 2>/dev/null || true"
    done
    
    # Open master ports if applicable
    if [[ "$node_type" == "master" ]]; then
        for port in "${master_ports[@]}"; do
            remote_exec "$host" "firewall-cmd --permanent --add-port=${port} 2>/dev/null || ufw allow ${port} 2>/dev/null || true"
        done
    fi
    
    # Reload firewall
    remote_exec "$host" "firewall-cmd --reload 2>/dev/null || ufw reload 2>/dev/null || true"
    
    log_success "Firewall configured on ${host}"
}

# Install container runtime prerequisites
install_container_runtime_prereqs() {
    local host="$1"
    local os_id="$2"
    
    log_info "Installing container runtime prerequisites on ${host}..."
    
    case "$os_id" in
        ubuntu|debian)
            remote_exec "$host" "apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release"
            ;;
        centos|rhel|rocky|almalinux|fedora)
            remote_exec "$host" "yum install -y yum-utils device-mapper-persistent-data lvm2 || dnf install -y dnf-plugins-core"
            ;;
    esac
    
    log_success "Container runtime prerequisites installed on ${host}"
}

# Configure hostname
configure_hostname() {
    local host="$1"
    local hostname="$2"
    
    log_info "Setting hostname on ${host} to ${hostname}..."
    
    remote_exec "$host" "hostnamectl set-hostname ${hostname}"
    
    log_success "Hostname set on ${host}"
}

# Prepare single node
prepare_node() {
    local host="$1"
    local node_name="${2:-}"
    local node_type="${3:-worker}"
    
    log_step "Preparing node: ${host}"
    
    local os_id
    os_id=$(detect_remote_os "$host")
    log_info "Detected OS: ${os_id}"
    
    # Set hostname if provided
    if [[ -n "$node_name" ]]; then
        configure_hostname "$host" "$node_name"
    fi
    
    # Update packages
    update_system_packages "$host" "$os_id"
    
    # Configure kernel parameters
    configure_kernel_params "$host"
    
    # Disable swap
    disable_swap "$host"
    
    # Configure firewall
    configure_firewall "$host" "$node_type"
    
    # Install container runtime prerequisites
    install_container_runtime_prereqs "$host" "$os_id"
    
    log_success "Node ${host} preparation complete"
    echo ""
}

# Print usage
print_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [HOST...]

Prepare cluster nodes for VMStation deployment.

Options:
    -i, --inventory PATH    Path to inventory file
    -u, --user USER         SSH user (default: root)
    -k, --key PATH          SSH key path
    -d, --dry-run           Show what would be done
    -h, --help              Show this help message

Arguments:
    HOST                    Specific host(s) to prepare (optional)
                            If not provided, uses hosts from inventory

Environment Variables:
    INVENTORY_FILE          Path to inventory file
    SSH_KEY_PATH            SSH key path
    SSH_USER                SSH user
    DRY_RUN                 Dry run mode (true/false)

Examples:
    $(basename "$0")                      # Prepare all nodes from inventory
    $(basename "$0") 192.168.1.10         # Prepare specific host
    $(basename "$0") --dry-run            # Preview changes
    $(basename "$0") -u admin node1 node2 # Prepare specific nodes as 'admin'

EOF
}

# Main function
main() {
    local hosts=()
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--inventory)
                INVENTORY_FILE="$2"
                shift 2
                ;;
            -u|--user)
                SSH_USER="$2"
                shift 2
                ;;
            -k|--key)
                SSH_KEY_PATH="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN="true"
                shift
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                print_usage
                exit 1
                ;;
            *)
                hosts+=("$1")
                shift
                ;;
        esac
    done
    
    log_info "VMStation Node Preparation"
    log_info "========================="
    echo ""
    
    # Get hosts from inventory if none provided
    if [[ ${#hosts[@]} -eq 0 ]]; then
        if [[ -f "$INVENTORY_FILE" ]]; then
            mapfile -t hosts < <(get_hosts_from_inventory)
        fi
        
        if [[ ${#hosts[@]} -eq 0 ]]; then
            log_error "No hosts provided and none found in inventory"
            print_usage
            exit 1
        fi
    fi
    
    log_info "Nodes to prepare: ${hosts[*]}"
    log_info "SSH User: ${SSH_USER}"
    log_info "SSH Key: ${SSH_KEY_PATH}"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warning "DRY RUN MODE - No changes will be made"
    fi
    echo ""
    
    # Prepare each node
    local failed=0
    for host in "${hosts[@]}"; do
        if ! prepare_node "$host"; then
            ((failed++))
            log_error "Failed to prepare node: ${host}"
        fi
    done
    
    # Summary
    echo ""
    echo "========================================="
    if [[ $failed -eq 0 ]]; then
        log_success "All nodes prepared successfully!"
    else
        log_error "${failed}/${#hosts[@]} node(s) failed preparation"
        exit 1
    fi
}

main "$@"
