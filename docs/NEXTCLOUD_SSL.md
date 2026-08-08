# Nextcloud access (local-only, avahi mDNS)

Nextcloud — and every other homelab app (Vaultwarden, Jellyfin, Paperless,
the homepage dashboard) — is served over **plain HTTP** on a fixed
`NodePort`, reached through each node's `.local` mDNS hostname (avahi):

```
http://masternode.local:30301
```

There is no TLS, no cert-manager, no Cloudflare, and no `jjbly.uk` DNS zone
involved. This replaced the earlier Let's Encrypt + Cloudflare DNS-01 +
`nginx-ingress` setup (see git history if you ever want that back for real
public/mobile access).

## Why nextcloud.jjbly.uk used to throw a cert error

The old setup pointed the `nextcloud-secrets` Secret at
`overwriteprotocol=https` / `overwritehost=nextcloud.jjbly.uk`. Nextcloud
uses those values to decide what URL to redirect the browser to — so even
when loading it over plain `http://masternode.local:30301`, Nextcloud's own
code forced a redirect to `https://nextcloud.jjbly.uk`, which either hit the
wrong host or a port with no TLS listener behind it, hence the certificate
error. This wasn't a browser-trust problem — Nextcloud was actively
redirecting you to the old HTTPS setup.

## Required nextcloud-secrets values

```
trusted-domains=masternode.local masternode.local:30301
overwriteprotocol=http
overwritehost=masternode.local:30301
overwritecliurl=http://masternode.local:30301
```

`trusted-domains` is space-separated (the official Nextcloud image splits on
whitespace) — include both the bare hostname and the `host:port` form so
Nextcloud accepts the `Host` header your browser actually sends.

To (re)create the secret:
```bash
kubectl delete secret nextcloud-secrets -n nextcloud
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
  -n nextcloud

kubectl rollout restart deployment/nextcloud -n nextcloud
```

If Nextcloud was already installed with the old `https`/`jjbly.uk` values,
also fix what got persisted into `config/config.php` directly — env vars
alone don't override values Nextcloud already wrote to disk:

```bash
kubectl exec -n nextcloud deploy/nextcloud -- php occ config:system:set \
  overwriteprotocol --value="http"
kubectl exec -n nextcloud deploy/nextcloud -- php occ config:system:set \
  overwrite.cli.url --value="http://masternode.local:30301"
kubectl exec -n nextcloud deploy/nextcloud -- php occ config:system:set \
  trusted_domains 1 --value="masternode.local"
kubectl exec -n nextcloud deploy/nextcloud -- php occ config:system:set \
  trusted_domains 2 --value="masternode.local:30301"
```

## How it's exposed

`kustomize/nextcloud/service.yaml` sets the `nextcloud` Service to
`type: NodePort` with a fixed `nodePort: 30301`, so it's reachable at
`masternode.local:30301` (or any other node's `.local` hostname/IP — a
NodePort forwards cluster-wide regardless of which node the pod is actually
running on). There's no Ingress object for Nextcloud anymore.

## Desktop client / mobile

This only covers browser (PC) access. The desktop and mobile Nextcloud apps
can also point at `http://masternode.local:30301`, but plain HTTP sync from
outside the LAN won't work — out of scope here, per "PC only for now".
