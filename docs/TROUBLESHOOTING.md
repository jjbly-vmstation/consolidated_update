# Troubleshooting — VMStation Homelab

---

## TLS / Certificate issues

### ERR_CERT_AUTHORITY_INVALID or cert warnings after fresh deploy

cert-manager takes 30–90 seconds to issue a new certificate after an ingress
is first created. During that time nginx serves a self-signed fallback cert.

Check cert status:
```bash
kubectl get certificate -A
kubectl describe certificate <name> -n <namespace>
kubectl describe challenge -n <namespace>   # if still pending
```

If a cert is stuck `pending` for more than 5 minutes, the most common causes:
- Cloudflare API token secret missing from `cert-manager` namespace
- Token doesn't have DNS:Edit permission for `jjbly.uk`
- DNS-01 challenge TXT record didn't propagate before Let's Encrypt checked

Re-create the Cloudflare secret:
```bash
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/k8s-certs.yml --ask-vault-pass
```

### Service still resolving to old .lan address

The old `lan` DNS zone on the Windows DC may still exist. Remove it:
```powershell
Remove-DnsServerZone -Name "lan" -Force
```
Or re-run `k8s-certs.yml` which removes it automatically.

---

## Kubernetes pod failures

### CreateContainerConfigError — missing Secret

**Symptom:** Nextcloud or MariaDB pods stuck in `CreateContainerConfigError`.

**Cause:** The `nextcloud-secrets` Secret doesn't exist in the namespace.

**Fix:**
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
  -n nextcloud
```

For Vaultwarden:
```bash
kubectl create secret generic vaultwarden-admin-token \
  --from-literal=token=$(openssl rand -base64 32) \
  -n vaultwarden
```

### ContainerCreating — MountVolume failed / path does not exist

**Symptom:** Pod stuck in `ContainerCreating`. `kubectl describe pod` shows path does not exist.

**Cause:** Local PersistentVolumes require the host directory to exist before the pod starts.

**Fix:** Run the apply playbook — it creates all directories automatically:
```bash
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/k8s-apply.yml
```

Current paths (all on root filesystem, not on /srv/media):

| Node | Path |
|---|---|
| masternode | `/var/lib/vaultwarden` |
| masternode | `/srv/monitoring_data/prometheus` |
| masternode | `/srv/monitoring_data/grafana` |
| masternode | `/srv/monitoring_data/loki` |
| storagenodet3500 | `/var/lib/jellyfin/config` |
| storagenodet3500 | `/var/lib/jellyfin/cache` |
| storagenodet3500 | `/var/lib/k8s/nextcloud` |
| storagenodet3500 | `/var/lib/k8s/mariadb` |

**Rule:** `/srv/media` on storagenodet3500 is for media files only.
All application config, cache, and databases go under `/var/lib`.

### PersistentVolume spec is immutable

**Symptom:** `kubectl apply` fails with `spec.persistentvolumesource is immutable after creation`.

**Cause:** Kubernetes does not allow changing a PV's path after creation.

**Fix:** Scale down the workload, delete the PVC and PV, then re-apply:
```bash
kubectl scale deployment <name> -n <namespace> --replicas=0
kubectl delete pvc <name> -n <namespace>
kubectl delete pv <name>
kubectl apply -k kustomize/<app>/
kubectl scale deployment <name> -n <namespace> --replicas=1
```

---

## Jellyfin

### Can't log in / forgot password

Jellyfin stores users in a SQLite database at `/config/data/jellyfin.db` on the
config PVC (`/var/lib/jellyfin/config` on storagenodet3500).

Reset via Python (no sqlite3 binary needed):
```bash
kubectl cp jellyfin/<pod>:/config/data/jellyfin.db /tmp/jellyfin.db
python3 -c "
import sqlite3
conn = sqlite3.connect('/tmp/jellyfin.db')
conn.execute(\"UPDATE Users SET Password = NULL, MustUpdatePassword = 1 WHERE Username = 'root';\")
conn.commit(); conn.close(); print('done')
"
kubectl cp /tmp/jellyfin.db jellyfin/<pod>:/config/data/jellyfin.db
kubectl rollout restart deployment/jellyfin -n jellyfin
```
Log in as `root` with no password, then set a new one immediately.

### Artwork missing / blue backgrounds after pod restart

Jellyfin's image cache is at `/cache` (PVC at `/var/lib/jellyfin/cache`).
If it was recently migrated from an emptyDir it may be empty. Trigger a rescan:

Dashboard → Libraries → Scan All Libraries

### Plugins not appearing in Catalog

Jellyfin 10.10 removed the Repositories UI tab. Either:
- Use the Catalog tab (works with the default repo URL)
- Install manually by placing plugin DLLs in `/var/lib/jellyfin/config/plugins/<name>/`
  on storagenodet3500, then `kubectl rollout restart deployment/jellyfin -n jellyfin`

Intro Skipper is **built into Jellyfin 10.10** — enable it at Dashboard → Playback.

---

## Prometheus / Grafana

### Node count shows more nodes than exist

Caused by stale or duplicate scrape targets in `prometheus-config` ConfigMap.
The cluster has exactly 2 nodes: `masternode` (192.168.4.63) and
`storagenodet3500` (192.168.4.61). The Windows DC (192.168.4.62) runs no
Linux exporters and must not appear as a node-exporter target.

After fixing the ConfigMap, apply and restart:
```bash
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/k8s-apply.yml --tags monitoring
kubectl rollout restart deployment/prometheus -n monitoring
```
