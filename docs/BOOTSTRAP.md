# Bootstrap Guide

Step-by-step first-time cluster setup.

## Prerequisites

- masternode (192.168.4.63, Debian) is reachable via SSH
- storagenodet3500 (192.168.4.61, Debian) is reachable via SSH
- homelab (192.168.4.62) has Windows Server 2025 installed and WinRM enabled
- AD DC (`vmstation.local`) is running on homelab
- This repo is cloned on masternode

## 1. Install local dependencies

On masternode:

```bash
./bootstrap/install-dependencies.sh
```

Installs: ansible, python3, pip, curl, wget, jq, sshpass, git.

## 2. Set up SSH keys

```bash
./bootstrap/setup-ssh-keys.sh
```

Generates `~/.ssh/vmstation_cluster` ed25519 key pair and distributes it to
`storagenodet3500`. masternode uses `ansible_connection: local` and needs no key.

## 3. Verify prerequisites

```bash
./bootstrap/verify-prerequisites.sh
```

Checks local tools, inventory YAML validity, SSH connectivity, and remote host
resources (RAM, CPU, disk). Report written to `/tmp/vmstation-prereq-report.txt`.

## 4. Run bootstrap playbook (Linux nodes)

```bash
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/bootstrap.yml
```

Configures on masternode and storagenodet3500:
- chrony NTP (pointing to AD DC at 192.168.4.62)
- swap disabled
- kernel params for Kubernetes (br_netfilter, ip_forward, etc.)
- containerd + SystemdCgroup
- kubelet / kubeadm / kubectl (held at v1.29)
- Wake-on-LAN enabled

## 5. Configure masternode services

```bash
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/masternode.yml
```

Deploys on masternode:
- BIND9 secondary DNS (forwards to AD DC)
- rsyslog syslog receiver (UDP/TCP 514)
- node_exporter

## 6. Apply Kubernetes manifests

Assumes cluster is already initialized (kubeadm or Kubespray). Run:

```bash
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/k8s-apply.yml
```

Or apply individual stacks:

```bash
kubectl apply -k kustomize/monitoring/
kubectl apply -k kustomize/jellyfin/
kubectl apply -k kustomize/nextcloud/
```

## 7. Create Nextcloud secrets

Before applying Nextcloud, create the required secret:

```bash
kubectl create secret generic nextcloud-secrets \
  --from-literal=db-name=nextcloud \
  --from-literal=db-user=nextcloud \
  --from-literal=db-password=<DB_PASSWORD> \
  --from-literal=mariadb-root-password=<ROOT_PASSWORD> \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=<ADMIN_PASSWORD> \
  --from-literal=trusted-domains="192.168.4.63 nextcloud.lan" \
  --from-literal=overwriteprotocol=http \
  --from-literal=overwritehost="192.168.4.63:30080" \
  --from-literal=overwritecliurl="http://192.168.4.63:30080" \
  -n nextcloud
```

## 8. Validate

```bash
kubectl get nodes
kubectl get pods -A
```

Expected: all nodes Ready, all pods Running.
