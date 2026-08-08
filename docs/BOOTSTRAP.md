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

## 6. Set up internal DNS (optional — only needed for public/external cert issuance)

Local access no longer needs this step: every app is reached over plain
HTTP via avahi mDNS `.local` hostnames (see Service URLs below), not
`jjbly.uk`. Skip straight to step 7 unless you specifically want public
HTTPS via cert-manager + Cloudflare for a service.

```bash
ansible-vault edit ansible/inventory/secrets.yml
# Add: vault_cloudflare_api_token: "<your-token>"
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/k8s-certs.yml --ask-vault-pass
```

## 7. Create application secrets

**Nextcloud** (update passwords before running — see docs/NEXTCLOUD_SSL.md
for why these values must stay `http`/`masternode.local`, not `https`/
`jjbly.uk`, or the browser will hit a cert error):
```bash
kubectl create secret generic nextcloud-secrets \
  --from-literal=db-name=nextcloud \
  --from-literal=db-user=nextcloud \
  --from-literal=db-password=<DB_PASSWORD> \
  --from-literal=mariadb-root-password=<ROOT_PASSWORD> \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=<ADMIN_PASSWORD> \
  --from-literal=trusted-domains="masternode.local masternode.local:30301" \
  --from-literal=overwriteprotocol=http \
  --from-literal=overwritehost=masternode.local:30301 \
  --from-literal=overwritecliurl=http://masternode.local:30301 \
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
1. cert-manager + nginx ingress controller (optional infra, kept for possible
   future public/external exposure — no app currently uses it)
2. All app stacks: Jellyfin, Nextcloud, Vaultwarden, Homer, nodectl

Every app is served over plain HTTP on a fixed NodePort, reached via each
node's avahi/mDNS `.local` hostname — no TLS, no cert-manager, no
Cloudflare, no jjbly.uk DNS zone required for local access.

## 9. Validate

```bash
kubectl get nodes
kubectl get pods -A
```

## Service URLs (local mDNS, PC only for now)

| Service | URL |
|---------|-----|
| Dashboard | http://masternode.local:30300 |
| Jellyfin | http://storagenodet3500.local:30096 |
| Nextcloud | http://masternode.local:30301 |
| Vaultwarden | http://masternode.local:30302 |
| Paperless-ngx | http://masternode.local:31000 |
| CUPS | http://masternode.local:30631 |
| Web Scanner | http://masternode.local:30808 |

