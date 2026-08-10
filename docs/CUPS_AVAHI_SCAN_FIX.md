# Fixing CUPS/avahi: AirPrint mismatch, duplicate mDNS daemons, and scanning

## What was broken

1. **AirPrint queue name mismatch** — `airprint-configmap.yaml` advertised
   `rp=printers/Brother_MFC`, but the actual CUPS queue created by
   `deployment-cups.yaml` is `Brother_MFC_9130CW`. Fixed to match.

2. **Two competing avahi daemons on the same host network namespace** —
   the `cups` pod (via `ydkn/cups`, which runs its own avahi-daemon over
   dbus to auto-publish CUPS's print queues) and the standalone
   `avahi-reflector` DaemonSet were both `hostNetwork: true` on
   storagenodet3500, both trying to bind UDP 5353. `avahi-reflector`'s own
   logs showed it self-detecting this:
   ```
   *** WARNING: Detected another IPv4 mDNS stack running on this host. ***
   *** WARNING: Detected another IPv6 mDNS stack running on this host. ***
   ```
   Fixed by removing `avahi-reflector` entirely and mounting the same
   `airprint.service` file directly into the `cups` pod's existing
   `/etc/avahi/services` directory instead — one avahi-daemon, both service
   definitions.

3. **`airprint-configmap.yaml` was never in `kustomization.yaml`** — it
   only existed on the cluster because someone `kubectl apply -f`'d it by
   hand at some point, outside the tracked GitOps flow. A from-scratch
   `kubectl apply -k kustomize/printer` would never have created it. Now
   tracked.

4. **Scanning (`scanservjs`) never worked, wrong protocol** —
   `SANED_NET_HOSTS=192.168.4.72` configures the generic SANE `net`
   backend, which requires a `saned` daemon running on the target host.
   Brother printers don't run `saned` - they use their own proprietary
   network scan protocol (confirmed by `avahi-browse` showing
   `_scanner._tcp`, Brother's legacy Bonjour scan-sharing type, not
   `_uscan._tcp`/eSCL - so the generic `airscan` backend isn't an option
   either). This needs Brother's own `brscan4` SANE backend, which isn't
   in the stock `sbs20/scanservjs` image.

## The scanning fix: custom scanservjs image

`kustomize/printer/scanservjs-brother/Dockerfile` layers Brother's
`brscan4` driver onto the stock scanservjs image and registers the printer
by IP at build time. There's no public, redistributable, stable URL for
Brother's driver package, so **you have to supply it yourself**:

1. Go to https://support.brother.com/g/b/downloadtop.aspx?c=us&lang=en&prod=mfc9130cw_us
2. Select **Linux (deb)**.
3. Find the **brscan4** package (a standalone SANE driver, not the full
   "Driver Install Tool" bundle — the Dockerfile only needs the one .deb)
   and copy its actual download link.

### Build it on storagenodet3500

There's no image registry in this stack, and the pod is pinned to
storagenodet3500 (see `nodeSelector` in the updated deployment), so the
image has to be built directly into containerd's local image store on
that node — nothing to push or pull.

```bash
# on storagenodet3500, one-time
sudo apt-get update
sudo apt-get install -y nerdctl buildkit
sudo systemctl enable --now buildkit

cd /opt/vmstation-org/consolidated_update/kustomize/printer/scanservjs-brother
sudo nerdctl --namespace k8s.io build \
  --build-arg BROTHER_BRSCAN4_URL="<the actual URL from Brother's site>" \
  -t localhost/scanservjs-brother:latest .
```

`--namespace k8s.io` is what makes this land in the same containerd
namespace kubelet/CRI reads from — no `docker save` / `ctr import` dance
needed.

Confirm it registered correctly before deploying:
```bash
sudo nerdctl --namespace k8s.io run --rm localhost/scanservjs-brother:latest \
  brsaneconfig4 -q
# should list: BrotherMFC9130CW MFC-9130CW 192.168.4.72
```

### Deploy

```bash
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/k8s-apply.yml --tags printer
# (or from masternode: kubectl apply -k kustomize/printer)

kubectl rollout restart deployment/scanservjs -n print
kubectl logs -n print deploy/scanservjs -f
```

You should see `scanimage -L` return the Brother device instead of
`No devices found`, and the scanservjs web UI
(`http://masternode.local:30808`) should list it as a scan source.

### If the printer's IP ever changes

The IP is baked into the image at build time via `brsaneconfig4`. If
`192.168.4.72` changes, rebuild with `--build-arg SCANNER_IP=<new-ip>` and
redeploy — it's not read from a runtime env var like the old
`SANED_NET_HOSTS` approach was.

## Verifying the avahi consolidation

```bash
kubectl logs -n print deploy/cups | grep -i "another.*mDNS\|WARNING"
# should be empty now - only one avahi-daemon (in the cups pod) is running

avahi-browse -a -t   # from any LAN machine
# should still show the AirPrint entries, just without the duplicate
# "Brother MFC-9130CW AirPrint" identity from the old reflector - and the
# rp= path now actually matches the real CUPS queue name.
```
