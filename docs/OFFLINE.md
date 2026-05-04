# Offline / Air-Gap Capability

## Goal

Full cluster redeployment with zero internet access. Scenario: power
outage takes down the entire homelab AND the ISP connection. When power
returns, the cluster must be rebuildable from scratch using only local
resources.

---

## What currently requires internet

| Dependency | Used by | Fix |
|------------|---------|-----|
| github.com | Git remote, CI/CD trigger | Gitea on masternode |
| docker.io / ghcr.io / quay.io | All container images | Local OCI registry |
| pkgs.k8s.io | kubelet, kubeadm, kubectl apt repo | Local apt mirror |
| download.docker.com | containerd apt repo | Local apt mirror |
| galaxy.ansible.com | Ansible collections | Pre-downloaded, committed |
| github.com/actions/runner | GitHub Actions runner | Gitea Actions runner |
| github.com/prometheus/node_exporter | Binary download in masternode.yml | Pre-downloaded to local mirror |
| pool.ntp.org | Fallback NTP | AD DC is already primary; remove pool fallback |

---

## Target architecture

```
masternode (192.168.4.63) — always-on control plane
├── Gitea                      :3000   local Git server (mirrors to GitHub when online)
├── Gitea Actions runner              self-hosted CI/CD (Gitea Actions = GitHub Actions syntax)
├── OCI registry (Distribution)  :5000   local container image cache
└── BIND9                             secondary DNS (already planned)

storagenodet3500 (192.168.4.61) — storage worker
├── apt-mirror                        local Debian + Kubernetes + Docker apt repos
└── NFS /srv/monitoring_data          monitoring PVs (already in use)
```

### Offline redeployment flow (no internet)

```
Power restored
  └─ masternode boots (always-on)
       └─ SSH to masternode
            └─ git clone http://192.168.4.63:3000/vmstation/homelab.git
                 └─ ansible-playbook bootstrap.yml    (apt from local mirror)
                      └─ ansible-playbook masternode.yml
                           └─ ansible-playbook cicd.yml   (Gitea runner)
                                └─ kubectl apply -k kustomize/monitoring/
                                     (images from 192.168.4.63:5000)
```

### When internet IS available

```
Developer pushes to Gitea → Gitea Actions runner runs CI → merge to main
Gitea push-mirrors to GitHub automatically (one-way, best-effort)
apt-mirror cronjob syncs package repos nightly
image-sync cronjob pulls new image tags and pushes to local registry
```

---

## Implementation plan

### Phase 1 — Local Git + CI (replaces GitHub Actions)

**Playbook: `ansible/playbooks/gitea.yml`**

Install Gitea on masternode:
- Single binary, runs as systemd service `gitea.service`
- Data stored at `/var/lib/gitea`
- Listens on `:3000`
- Configure push-mirror to GitHub (Settings → Mirror) when internet is available
- Gitea Actions is built into Gitea ≥ 1.21 — enable in `app.ini`

**Playbook: `ansible/playbooks/cicd.yml`** (updated from GitHub runner plan)

Install Gitea Actions runner on masternode:
- `act_runner` binary from Gitea releases (pre-download to local mirror)
- Registers against local Gitea (`http://192.168.4.63:3000`) — no internet needed
- Same `.github/workflows/ci.yml` syntax works unchanged

**Note on GitHub portfolio visibility:**
Gitea push-mirrors the repo to GitHub automatically when online.
Recruiters still see the GitHub repo. CI runs locally on Gitea.

---

### Phase 2 — Local container registry (replaces Docker Hub / ghcr.io)

**Playbook: `ansible/playbooks/registry.yml`**

Install Docker Distribution (OCI registry v2) on masternode:
- Runs as a container or binary on `:5000`
- Storage at `/var/lib/registry` (or NFS-backed from storagenodet3500)
- No auth required for homelab (or basic auth via htpasswd)

**Script: `scripts/image-sync.sh`**

Pull all images referenced in kustomization files from the internet
and push to the local registry. Run this periodically when online, or
manually before a planned outage:

```bash
#!/bin/bash
# Usage: ./scripts/image-sync.sh [--dry-run]
# Reads image references from kustomization.yaml files,
# pulls from upstream, re-tags, pushes to 192.168.4.63:5000

LOCAL_REGISTRY="192.168.4.63:5000"

IMAGES=(
  "prom/prometheus:v2.55.0"
  "grafana/grafana:11.4.0"
  "grafana/loki:3.3.0"
  "grafana/promtail:3.3.0"
  "prom/node-exporter:v1.6.1"
  "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.10.0"
  "prom/blackbox-exporter:v0.25.0"
  "jellyfin/jellyfin:10.10"
  "nextcloud:29-apache"
  "mariadb:10.11"
  "busybox:latest"
  "alpine:3.19"
)

for image in "${IMAGES[@]}"; do
  local_tag="${LOCAL_REGISTRY}/${image}"
  echo "Syncing ${image} → ${local_tag}"
  docker pull "${image}"
  docker tag  "${image}" "${local_tag}"
  docker push "${local_tag}"
done
```

**Kustomize image override:**

Update each `kustomization.yaml` to rewrite image names to the local
registry. Add a `newName` to every image entry:

```yaml
# kustomize/monitoring/kustomization.yaml
images:
  - name: prom/prometheus
    newName: 192.168.4.63:5000/prom/prometheus
    newTag: v2.55.0
  - name: grafana/grafana
    newName: 192.168.4.63:5000/grafana/grafana
    newTag: "11.4.0"
  # ... etc
```

This means `kubectl apply -k` pulls from the local registry with no
changes to deployment/statefulset manifests.

---

### Phase 3 — Local apt mirror (replaces pkgs.k8s.io / download.docker.com)

**Playbook: `ansible/playbooks/apt-mirror.yml`**

Install `apt-mirror` on storagenodet3500 (has 500GB+ disk):

Mirror these repos:
- `https://pkgs.k8s.io/core:/stable:/v1.29/deb/` — kubelet, kubeadm, kubectl
- `https://download.docker.com/linux/debian` — containerd
- `http://deb.debian.org/debian` — base Debian packages (bookworm)

Serve the mirror over HTTP from storagenodet3500 on `:8080`.

**Update `bootstrap.yml`:**

Replace external apt repo URLs with the local mirror:
```yaml
k8s_apt_repo: "deb [signed-by=...] http://192.168.4.61:8080/kubernetes/v1.29/ /"
containerd_apt_repo: "deb [signed-by=...] http://192.168.4.61:8080/docker/ bookworm stable"
```

**Cron job** on storagenodet3500:
```
0 3 * * 0  apt-mirror    # weekly sync when internet is available
```

---

### Phase 4 — Pre-downloaded binaries (replaces GitHub release downloads)

The `masternode.yml` playbook currently downloads `node_exporter` from
GitHub releases. Replace with:

1. Download the binary into `files/binaries/node_exporter-<version>.tar.gz`
   and commit it (it's ~10MB), OR
2. Serve it from storagenodet3500's local HTTP server alongside apt-mirror.

Same applies to any future binaries (Gitea, act_runner, etc.).

---

### Phase 5 — Ansible collections offline

Pre-download required Ansible collections and commit them to the repo:

```bash
ansible-galaxy collection download \
  ansible.posix \
  community.general \
  -p ansible/collections/

# Commit ansible/collections/ to the repo
# Install offline during bootstrap:
ansible-galaxy collection install --offline \
  -r ansible/requirements.yml \
  -p ansible/collections/
```

Add `ansible/requirements.yml`:
```yaml
collections:
  - name: ansible.posix
  - name: community.general
```

---

## Bootstrap order (fully offline)

Assuming masternode has the repo checked out (USB drive or previously
cloned when online):

```
1.  bootstrap/install-dependencies.sh --offline
    └─ apt-get from local mirror on storagenodet3500
2.  ansible-playbook apt-mirror.yml          # only needed if mirror isn't up yet
3.  ansible-playbook bootstrap.yml           # uses local apt mirror
4.  ansible-playbook masternode.yml          # node_exporter from local copy
5.  ansible-playbook registry.yml            # start local OCI registry
6.  ansible-playbook gitea.yml               # start local Git server
7.  ansible-playbook cicd.yml               # Gitea Actions runner
8.  kubectl apply -k kustomize/monitoring/   # images from local registry
9.  kubectl apply -k kustomize/jellyfin/
10. kubectl apply -k kustomize/nextcloud/
```

---

## Cold-start: no internet AND repo not on disk

Keep a copy of the repo on **storagenodet3500's NFS share** at
`/srv/vmstation/homelab.git` (bare git repo). If masternode needs to be
rebuilt from scratch:

```bash
# On masternode after OS install:
git clone /mnt/nfs/vmstation/homelab.git /srv/vmstation/homelab
cd /srv/vmstation/homelab
./bootstrap/install-dependencies.sh
# ... continue with bootstrap order above
```

The NFS share is on storagenodet3500 which has local power and disk —
it survives masternode being wiped.

---

## Upgrade policy (when online)

```
Weekly cron on storagenodet3500:
├── apt-mirror sync
└── image-sync.sh --new-tags-only    # pull any new pinned tags

Before planned outage:
└── run image-sync.sh manually to ensure all current tags are cached
```

Renovate (or manual) bumps image tags in kustomization.yaml → CI
validates → merge → image-sync.sh picks up the new tag on next run.
