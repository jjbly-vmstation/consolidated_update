# Bootstrap Guide

Step-by-step first-time cluster setup.

## Prerequisites

- masternode (192.168.4.63, Debian) reachable via SSH
- storagenodet3500 (192.168.4.61, Debian) reachable via SSH
- homelab (192.168.4.62) has Windows Server 2025 + AD DC (`vmstation.local`) running
- Cloudflare API token created with DNS:Edit on `jjbly.uk` (see WINDOWS_DC.md)
- This repo cloned on masternode at `/opt/vmstation-org/consolidated_update`

## 1. Install local dependencies

```bash
./bootstrap/install-dependencies.sh
```

Installs: ansible, python3, pip, curl, wget, jq, sshpass, git.

## 2. Set up SSH keys

```bash
./bootstrap/setup-ssh-keys.sh
```

Generates `~/.ssh/vmstation_cluster` ed25519 key and distributes to storagenodet3500.
masternode uses `ansible_connection: local` — no key needed.

## 3. Verify prerequisites

```bash
./bootstrap/verify-prerequisites.sh
```

Checks tools, inventory YAML, SSH connectivity, and remote host resources.

## 4. Bootstrap Linux nodes

```bash
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/bootstrap.yml
```

Configures both Linux nodes:
- chrony NTP → AD DC at 192.168.4.62
- swap disabled
- kernel params for Kubernetes
- containerd + SystemdCgroup
- kubelet / kubeadm / kubectl

## 5. Configure masternode services

```bash
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/masternode.yml
```

Deploys on masternode: BIND9 DNS, rsyslog receiver, node_exporter.

## 6. Set up TLS and internal DNS

Store the Cloudflare API token in Ansible vault:
```bash
ansible-vault edit ansible/inventory/secrets.yml
# Add: vault_cloudflare_api_token: "<your-token>"
```

Run the cert playbook — creates `jjbly.uk` DNS zone on the Windows DC,
removes the old `lan` zone, and creates the Cloudflare secret in Kubernetes:
```bash
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/k8s-certs.yml --ask-vault-pass
```

## 7. Create application secrets

**Nextcloud** (update passwords before running):
```bash
kubectl create secret generic nextcloud-secrets \
  --from-literal=db-name=nextcloud \
  --from-literal=db-user=nextcloud \
  --from-literal=db-password=<DB_PASSWORD> \
  --from-literal=mariadb-root-password=<ROOT_PASSWORD> \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=<ADMIN_PASSWORD> \
  --from-literal=trusted-domains="nextcloud.jjbly.uk" \
  --from-literal=overwriteprotocol=https \
  --from-literal=overwritehost=nextcloud.jjbly.uk \
  --from-literal=overwritecliurl=https://nextcloud.jjbly.uk \
  -n nextcloud --dry-run=client -o yaml | kubectl apply -f -
```

**Vaultwarden**:
```bash
kubectl create secret generic vaultwarden-admin-token \
  --from-literal=token=$(openssl rand -base64 32) \
  -n vaultwarden --dry-run=client -o yaml | kubectl apply -f -
```

## 8. Apply Kubernetes manifests

```bash
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/k8s-apply.yml
```

This installs (in order):
1. cert-manager (Let's Encrypt controller)
2. ClusterIssuer (Cloudflare DNS-01)
3. nginx ingress controller
4. All app stacks (monitoring, Jellyfin, Nextcloud, Vaultwarden, Homer)

cert-manager automatically issues Let's Encrypt certs for each service.
No certificate installation needed on any client device.

## 9. Validate

```bash
kubectl get nodes
kubectl get pods -A
kubectl get certificate -A   # all should show READY=True within ~2 minutes
```

## Service URLs (internal DNS via jjbly.uk zone on Windows DC)

| Service | URL |
|---------|-----|
| Dashboard | https://home.jjbly.uk |
| Jellyfin | https://jellyfin.jjbly.uk |
| Nextcloud | https://nextcloud.jjbly.uk |
| Vaultwarden | https://vault.jjbly.uk |
| Grafana | https://grafana.jjbly.uk |
| Prometheus | https://prometheus.jjbly.uk |
