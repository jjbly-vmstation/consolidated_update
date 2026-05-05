# Troubleshooting — VMStation Homelab

Issues hit during initial cluster bring-up and how they were resolved.

---

## AD CS certificate request failures

### CERTSRV_E_NO_CERT_TYPE (0x80094801)

**Symptom:** `certreq -submit` denied with "The request contains no certificate template information."

**Cause:** The AD CA policy module requires every CSR to name a certificate template. The original INF had no `[RequestAttributes]` section.

**Fix:** Added to the INF:
```ini
[RequestAttributes]
CertificateTemplate = WebServer
```

Configurable via the `cert_template` variable in `k8s-certs.yml`. To list templates available on your CA:
```powershell
certutil -CATemplates
```

---

### User context template conflicts with machine context (0x8004e00c)

**Symptom:** `certreq -new` failed with "User context template conflicts with machine context."

**Cause:** `WebServer` is a machine-scoped template but the INF had `MachineKeySet = FALSE`.

**Fix:** Set `MachineKeySet = TRUE` in `[NewRequest]` and updated the PFX export to look in `Cert:\LocalMachine\My` instead of `Cert:\CurrentUser\My`.

---

### CERTSRV_E_TEMPLATE_DENIED (0x80094012)

**Symptom:** `certreq -submit` denied with "The permissions on the certificate template do not allow the current user to enroll."

**Cause:** The ansible service account had no Enroll permission on the WebServer template.

**Fix:** On the DC as Domain Admin:
1. `mmc certtmpl.msc` → right-click **Web Server** → **Properties** → **Security**
2. Add the ansible service account, grant **Read** + **Enroll**
3. Re-publish if needed: `certutil -SetCAtemplates +WebServer`

---

### ERROR_FILE_EXISTS on wildcard.rsp (0x80070050)

**Symptom:** `certreq -submit` failed with "The file exists" on `wildcard.rsp`.

**Cause:** `certreq -submit` writes a `.rsp` response file and refuses to overwrite it. The stale-file cleanup task didn't include `wildcard.rsp`.

**Fix:** Added `wildcard.rsp` to the cleanup loop in `k8s-certs.yml`.

---

## Kubernetes pod failures

### CreateContainerConfigError — missing Secret

**Symptom:** Nextcloud and MariaDB pods stuck in `CreateContainerConfigError`. No useful output from `kubectl logs`.

**Cause:** Pods reference a Secret (`nextcloud-secrets`) that doesn't exist in the namespace. Kubernetes can't start the container when a required Secret is missing.

**Fix:** Create the secret before running `k8s-apply.yml`:
```bash
kubectl create secret generic nextcloud-secrets \
  --from-literal=db-name=nextcloud \
  --from-literal=db-user=nextcloud \
  --from-literal=db-password=CHANGEME \
  --from-literal=mariadb-root-password=CHANGEME \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=CHANGEME \
  --from-literal=trusted-domains=nextcloud.lan \
  --from-literal=overwriteprotocol=https \
  --from-literal=overwritehost=nextcloud.lan \
  --from-literal=overwritecliurl=https://nextcloud.lan \
  -n nextcloud
```

Same issue for Vaultwarden:
```bash
kubectl create secret generic vaultwarden-admin-token \
  --from-literal=token=$(openssl rand -base64 32) \
  -n vaultwarden
```

---

### ContainerCreating / MountVolume failed — missing host directories

**Symptom:** Pods stuck in `ContainerCreating`. `kubectl describe pod` shows:
```
MountVolume.NewMounter initialization failed for volume "vaultwarden-pv":
path "/var/lib/vaultwarden" does not exist
```

**Cause:** Local PersistentVolumes bind to host paths that must exist before the kubelet can mount them. The directories were not created anywhere in the automation.

**Affected paths:**

| Node | Path |
|---|---|
| masternode | `/var/lib/vaultwarden` |
| masternode | `/srv/monitoring_data/prometheus` |
| masternode | `/srv/monitoring_data/grafana` |
| masternode | `/srv/monitoring_data/loki` |
| storagenodet3500 | `/srv/media/nextcloud` |
| storagenodet3500 | `/srv/media/jellyfin-config` |
| storagenodet3500 | `/var/lib/k8s/mariadb` |

**Fix:** Added directory creation tasks to `k8s-apply.yml` so they are created automatically before manifests are applied.

---

### Namespace not found during TLS secret install

**Symptom:** `k8s-certs.yml` failed installing the wildcard TLS secret into the `vaultwarden` namespace with `namespaces "vaultwarden" not found`.

**Cause:** The cert playbook ran before `k8s-apply.yml` had created the namespace.

**Fix:** Added an idempotent namespace-creation task to `k8s-certs.yml` that runs before the secret install loop.
