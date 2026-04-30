# VMStation Homelab Cluster

Consolidated mono-repo for the VMStation homelab Kubernetes environment.

## Hardware

| Host | IP | OS | Role |
|------|----|----|------|
| masternode | 192.168.4.63 | Debian 12 | K8s control plane, secondary DNS, syslog receiver |
| storagenodet3500 | 192.168.4.61 | Debian 12 | K8s worker, Jellyfin, Nextcloud, NFS storage |
| homelab (WSDC-Homelab) | 192.168.4.62 | Windows Server 2025 | AD DC, primary DNS/NTP, Hyper-V host |
| ciscosw1 | — | Cisco IOS | LAN switching |

**WoL MACs:** masternode `00:e0:4c:68:cb:bf` · storagenodet3500 `b8:ac:6f:7e:6c:9d` · homelab `d0:94:66:30:d6:63`

## Quick start

```bash
# 1. Install dependencies on masternode
./bootstrap/install-dependencies.sh

# 2. Distribute SSH keys
./bootstrap/setup-ssh-keys.sh

# 3. Verify prerequisites
./bootstrap/verify-prerequisites.sh

# 4. Bootstrap Linux nodes (NTP, containerd, kubeadm, WoL)
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/bootstrap.yml

# 5. Configure masternode services (DNS, syslog, node_exporter)
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/masternode.yml

# 6. Apply all Kubernetes manifests
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/k8s-apply.yml
```

## Application index

| App | NodePort | Node |
|-----|----------|------|
| Grafana | 192.168.4.63:30300 | masternode |
| Prometheus | 192.168.4.63:30090 | masternode |
| Loki | 192.168.4.63:31100 | masternode |
| Jellyfin | 192.168.4.61:30096 | storagenodet3500 |
| Nextcloud | 192.168.4.63:30080 | storagenodet3500 (PVs) |

## Repository layout

```
.
├── bootstrap/              # One-time setup scripts (run on masternode)
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/hosts.yml # masternode (local) + storagenodet3500 (ssh) + homelab (winrm)
│   ├── group_vars/
│   └── playbooks/
│       ├── bootstrap.yml   # Debian: containerd, kubeadm, chrony, WoL
│       ├── masternode.yml  # BIND9 secondary DNS + rsyslog + node_exporter
│       └── k8s-apply.yml  # kubectl apply -k for all apps
├── kustomize/
│   ├── jellyfin/           # Media server (storagenodet3500, port 30096)
│   ├── nextcloud/          # File sharing — HTTP until AD DC SSL done
│   └── monitoring/         # Prometheus · Grafana · Loki · Promtail · exporters
└── docs/
    ├── BOOTSTRAP.md        # First-time setup walkthrough
    ├── WAKE_ON_LAN.md
    ├── CISCO_SWITCH.md
    ├── WINDOWS_DC.md       # AD DC setup, WinRM, DNS records
    └── NEXTCLOUD_SSL.md    # TODO: AD CS cert integration
```

## Outstanding TODOs

1. **Nextcloud SSL** — obtain cert from AD CS, create TLS secret — see `docs/NEXTCLOUD_SSL.md`
2. **Nextcloud AD SSO** — Kerberos/SAML via AD DC (after SSL)
3. **Grafana admin password** — replace hardcoded `"admin"` with a Secret
4. **Jellyfin DNS** — create `jellyfin.lan` A record on AD DC → 192.168.4.61
5. **WinRM setup** — run `winrm quickconfig` and create `svc-ansible` on homelab before Ansible connects

---

<!-- original consolidation plan preserved below for reference -->

# Homelab Consolidation Plan

## Current State — 6 Repos

| Repo | Purpose | Verdict |
|------|---------|---------|
| cluster-docs | Documentation only | Strip to essentials, merge into new repo |
| cluster-setup | Bootstrap scripts, WoL, power management | Keep scripts, drop power management |
| cluster-config | Ansible inventory, playbooks, host configs | Keep, heavily updated |
| cluster-application-stack | Jellyfin + Nextcloud manifests | Keep, migrate to clean kustomize |
| cluster-monitor-stack | Prometheus/Grafana/Loki | Keep, migrate to clean kustomize |
| cluster-infra | Kubespray, Terraform, FreeIPA tooling | **Remove entirely** — AD DC replaces it |

---

## Infrastructure (Updated)

| Host | IP | OS | Role |
|------|----|----|------|
FQDN of vmstation.local.x where x is one of the hostnames following
| masternode | 192.168.4.63 | Debian | K8s control plane, secondary DNS, log/metric ingester |
| storagenodet3500 | 192.168.4.61 | Debian | K8s worker, media/storage |
| homelab -> RENAMED TO "WSDC-Homelab" | 192.168.4.62 | **Windows Server 2025** | AD DC + Kerberos, Hyper-V host |
| ciscosw1 | — | Cisco IOS | LAN switching |
Also WSDC-Homelab has various VMs running on homelab 192.168.128.x/24 subnet

**WoL MACs** (kept from inventory.ini):
- masternode: `00:e0:4c:68:cb:bf`
- storagenodet3500: `b8:ac:6f:7e:6c:9d`
- homelab: `d0:94:66:30:d6:63`

---

## What Gets REMOVED

### cluster-infra — entire repo dropped
- Kubespray submodule → not needed, cluster already exists
- No Terraform but AD DC handles DNS/LDAP provisioning now
- FreeIPA playbooks/roles → replaced by Windows AD
- `inventory.ini` → superseded by new `ansible/inventory/hosts.yml`
- Helm charts in cluster-infra → moving to Kustomize

### cluster-docs — all bloat docs dropped
These files exist only as process artifacts from previous AI sessions and have zero operational value:
- `MIGRATION_ANALYSIS.md`
- `CAPABILITY_PARITY_ANALYSIS.md`
- `IMPROVEMENTS_AND_STANDARDS.md`
- `FINAL_VALIDATION_REPORT.md`
- `DEPLOYMENT_SEQUENCE.md` / `DEPLOYMENT_SUMMARY.md`
- `BASELINE_REPORT.md`
- `POST-DEPLOY-PATCHES-RATIONALE.md`
- `PR_SUMMARY.md`
- `CHANGELOG.md`
- `FREEIPA_PASSWORD_RECOVERY.md` — FreeIPA is gone
- All subdirs: `architecture/`, `components/`, `deployment/`, `development/`, `getting-started/`, `operations/`, `reference/`, `roadmap/`, `troubleshooting/`

### cluster-setup — power management dropped
- `power-management/` directory entirely — dangerous autosleep scripts
  - Already partially flagged (`README_REMOVED.md` exists there)
  - The playbooks and templates in that dir are removed
- Only essential files in this repo are the canonical inventory file in /ansible/inventory/hosts.yaml

### cluster-config — stale host configs dropped
- `hosts/rhel10/` — host no longer exists (migrated to Windows Server 2025)
- `ansible/inventory/staging/` — homelab has one environment
- `ansible/playbooks/kerberos-setup.yml` — was for FreeIPA, not AD
- `ansible/playbooks/keycloak-setup.yml` — Keycloak removed, AD DC is auth
- `ansible/playbooks/infrastructure-services.yml` — references FreeIPA

### cluster-application-stack — remove from Jellyfin
- `manifests/jellyfin/oauth2-proxy-deployment.yaml` — was FreeIPA-tied
- `manifests/jellyfin/oauth2-proxy-service.yaml` — same
- `manifests/jellyfin/configmap.yaml` — folded into deployment env vars
- `kustomize/base/`, `kustomize/overlays/` — unused skeleton, replaced by flat per-app dirs
- `helm-charts/` — moving to Kustomize only
- `ansible/` in this repo — ansible consolidates to one place

### cluster-application-stack — remove from Nextcloud
- OIDC `install-oidc-login` init container — was for Keycloak/FreeIPA, now removed
- All `OIDC_LOGIN_*` env vars from Nextcloud deployment
- `manifests/nextcloud/secret-placeholder.yaml` — replaced by proper instructions

### cluster-monitor-stack — remove
- `manifests/grafana/oauth-secret.yaml` — FreeIPA OAuth secret reference
- Grafana `GF_AUTH_GENERIC_OAUTH_*` env vars — Keycloak OAuth disabled
- `ansible/` in this repo — ansible consolidates

---

## What Gets KEPT / MIGRATED

### Bootstrap scripts (cluster-setup → new repo `bootstrap/`)
- `bootstrap/install-dependencies.sh` ✓
- `bootstrap/setup-ssh-keys.sh` ✓
- `bootstrap/prepare-nodes.sh` ✓
- `bootstrap/verify-prerequisites.sh` ✓

### Docs (cluster-docs → new repo `docs/`)
Only 5 real docs survive:
- `BOOTSTRAP.md` — step-by-step first-time setup
- `WAKE_ON_LAN.md` — WoL setup + MAC table (from cluster-setup)
- `CISCO_SWITCH.md` — switch reference
- `WINDOWS_DC.md` — AD DC + Hyper-V setup and Ansible WinRM config
- `NEXTCLOUD_SSL.md` — **TODO stub**: AD DC cert integration not yet implemented

### Ansible (cluster-config → new repo `ansible/`)
- `ansible.cfg` — clean, single config
- `inventory/hosts.yml` — rewritten for current hosts (see below)
- `group_vars/all.yml` — cluster-wide vars (domain, DNS, NTP all point to AD DC)
- `group_vars/linux_nodes.yml`
- `group_vars/windows_nodes.yml` — WinRM + admin service account
- `playbooks/bootstrap.yml` — Debian node setup (containerd, k8s packages, WoL)
- `playbooks/masternode.yml` — BIND9 secondary DNS + rsyslog receiver + node_exporter
- `playbooks/k8s-apply.yml` — runs `kubectl apply -k` for all apps

**Removed playbooks**: kerberos-setup, keycloak-setup, FreeIPA infra services, gather-baseline, validate-config (these were FreeIPA-era or unused)

**Kept playbooks**: syslog-server (adapted into masternode.yml), ntp-sync (adapted into bootstrap.yml), baseline-hardening (adapted into bootstrap.yml)

### Jellyfin Kustomize (highest priority — actively used)
All pinned to `storagenodet3500` (192.168.4.61).

Files: `kustomization.yaml`, `namespace.yaml`, `deployment.yaml`, `service.yaml`, `ingress.yaml`, `persistentvolume.yaml`, `persistentvolumeclaim.yaml`

Changes from original:
- oauth2-proxy removed entirely
- configmap folded inline
- `ingress.yaml` host updated to `jellyfin.lan`
- Image tag pinned to `10.10` (not `latest`)
- kustomization.yaml now includes PV + PVC

### Nextcloud Kustomize
PVs moved from `homelab` (now Windows — can't host Linux PVs) to `storagenodet3500`.

Files: `kustomization.yaml`, `namespace.yaml`, `nextcloud.yaml`, `mariadb.yaml`, `service.yaml`, `persistentvolume.yaml`, `persistentvolumeclaim.yaml`

Changes from original:
- `install-oidc-login` init container removed
- All `OIDC_LOGIN_*` env vars removed
- `nodeAffinity` in PVs changed from `homelab` → `storagenodet3500`
- Comment added: `# SSL from AD DC not yet implemented — see docs/NEXTCLOUD_SSL.md`

### Monitoring Kustomize (cluster-monitor-stack → new repo `kustomize/monitoring/`)
Files kept as-is except:
- `grafana/oauth-secret.yaml` removed
- Grafana `GF_AUTH_GENERIC_OAUTH_ENABLED` set to `false`, other OAuth env vars removed
- `GF_SECURITY_ADMIN_PASSWORD` flagged as "must be replaced with a Secret"
- Image tags updated to current stable: Prometheus `v2.55`, Grafana `11.4`, Loki `3.3`, Promtail `3.3`

Components: Prometheus (StatefulSet + RBAC), Grafana, Loki (StatefulSet), Promtail (DaemonSet), node-exporter, kube-state-metrics, blackbox-exporter

---

## Proposed New Repo Structure

```
homelab/                          ← single consolidated repo
├── README.md                     ← hardware table, quick start, app index
├── .gitignore
│
├── docs/
│   ├── BOOTSTRAP.md
│   ├── WAKE_ON_LAN.md
│   ├── CISCO_SWITCH.md
│   ├── WINDOWS_DC.md
│   └── NEXTCLOUD_SSL.md          ← TODO: AD DC cert integration
│
├── bootstrap/
│   ├── install-dependencies.sh
│   ├── setup-ssh-keys.sh
│   ├── prepare-nodes.sh
│   └── verify-prerequisites.sh
│
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/
│   │   └── hosts.yml             ← masternode (local), storagenodet3500 (ssh), homelab (winrm)
│   ├── group_vars/
│   │   ├── all.yml
│   │   ├── linux_nodes.yml
│   │   └── windows_nodes.yml
│   └── playbooks/
│       ├── bootstrap.yml         ← Debian: containerd, kubeadm, swap off, WoL
│       ├── masternode.yml        ← BIND9 secondary DNS + rsyslog + node_exporter
│       └── k8s-apply.yml         ← kubectl apply -k for all apps
│
└── kustomize/
    ├── jellyfin/                 ← PRIORITY — actively used by family
    │   ├── kustomization.yaml
    │   ├── namespace.yaml
    │   ├── deployment.yaml
    │   ├── service.yaml
    │   ├── ingress.yaml
    │   ├── persistentvolume.yaml
    │   └── persistentvolumeclaim.yaml
    │
    ├── nextcloud/                ← HTTP only until AD DC SSL done
    │   ├── kustomization.yaml
    │   ├── namespace.yaml
    │   ├── nextcloud.yaml
    │   ├── mariadb.yaml
    │   ├── service.yaml
    │   ├── persistentvolume.yaml
    │   └── persistentvolumeclaim.yaml
    │
    └── monitoring/
        ├── kustomization.yaml
        ├── namespace.yaml
        ├── prometheus/
        │   ├── rbac.yaml
        │   ├── configmap.yaml
        │   ├── deployment.yaml
        │   └── service.yaml
        ├── grafana/
        │   ├── configmap.yaml
        │   ├── deployment.yaml
        │   └── service.yaml
        ├── loki/
        │   ├── configmap.yaml
        │   ├── deployment.yaml
        │   └── service.yaml
        ├── promtail/
        │   ├── rbac.yaml
        │   ├── configmap.yaml
        │   └── daemonset.yaml
        └── exporters/
            ├── node-exporter.yaml
            ├── kube-state-metrics.yaml
            └── blackbox-exporter.yaml
```

---

## New Ansible Inventory (`ansible/inventory/hosts.yml`)

```yaml
all:
  children:
    linux_nodes:
      children:
        control_plane:
          hosts:
            masternode:
              ansible_host: 192.168.4.63
              ansible_connection: local
              ansible_user: root
              wol_mac: "00:e0:4c:68:cb:bf"
        workers:
          hosts:
            storagenodet3500:
              ansible_host: 192.168.4.61
              ansible_user: root
              ansible_ssh_private_key_file: ~/.ssh/id_k3s
              wol_mac: "b8:ac:6f:7e:6c:9d"
    windows_nodes:
      hosts:
        homelab:
          ansible_host: 192.168.4.62
          ansible_connection: winrm
          ansible_winrm_transport: ntlm
          ansible_winrm_server_cert_validation: ignore
          ansible_user: svc-ansible
          ansible_password: "{{ vault_windows_ansible_password }}"
          wol_mac: "d0:94:66:30:d6:63"
```

---

## Key Decisions

| Decision | Reason |
|----------|--------|
| Nextcloud PVs moved from `homelab` → `storagenodet3500` | homelab is now Windows — can't mount Linux hostPath PVs |
| Nextcloud OIDC removed | Was tied to Keycloak/FreeIPA, both gone. SSL TODO documented. |
| Jellyfin oauth2-proxy removed | Was tied to FreeIPA OIDC. Jellyfin has its own auth. |
| masternode as secondary DNS | AD DC is primary; masternode BIND9 forwards to it and provides LAN redundancy |
| Monitoring stays on masternode | Control plane node, has `node-role.kubernetes.io/control-plane` taint toleration |
| No Helm — Kustomize only | Simpler, no Tiller, no chart versioning to manage |
| No staging environment | It's a homelab — one environment |
| power-management fully dropped | Dangerous autosleep in a cluster context; WoL kept separately |

---

## Outstanding TODOs (not blocking)

1. **Nextcloud SSL** — obtain cert from AD CS, create k8s TLS secret, switch from NodePort to Ingress with TLS
2. **Nextcloud AD SSO** — Kerberos/SAML login via AD DC (future, after SSL)
3. **Grafana admin password** — currently hardcoded `"admin"`, needs a k8s Secret
4. **Jellyfin ingress host** — set to `jellyfin.lan`; requires DNS A record on AD DC pointing to a node IP
5. **Windows WinRM** — `winrm quickconfig` must be run on homelab before ansible can connect
6. **Hyper-V VMs as k8s workers** — if additional compute needed, Linux VMs on homelab could join the cluster
```
