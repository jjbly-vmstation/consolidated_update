# Nextcloud TLS

Nextcloud is served over HTTPS at `https://nextcloud.jjbly.uk` with a
Let's Encrypt certificate issued and auto-renewed by cert-manager.

## Why Let's Encrypt over the AD CA

The original plan was to use the Windows Server AD CA to issue a wildcard
`*.lan` cert. This was abandoned because:

- Every device (phones, family members' laptops, tablets) would need the
  AD CA root cert manually installed. When the cert rotates annually, every
  device needs it again.
- Let's Encrypt certs are trusted by every OS and browser out of the box —
  no installation, no rotation ceremony, no family support calls.
- DNS-01 challenge works for internal-only hostnames: Cloudflare handles
  the TXT record validation so Let's Encrypt never needs to reach our
  internal network.

## How it works

1. cert-manager runs in Kubernetes with a `ClusterIssuer` configured for
   Let's Encrypt ACME + Cloudflare DNS-01.
2. The Nextcloud ingress has the annotation:
   `cert-manager.io/cluster-issuer: letsencrypt-prod`
3. cert-manager creates a `_acme-challenge.nextcloud.jjbly.uk` TXT record
   in Cloudflare, Let's Encrypt verifies it, cert is issued, TXT record
   is deleted.
4. cert-manager auto-renews 30 days before expiry. Zero manual steps.

## Internal DNS

`nextcloud.jjbly.uk` resolves internally via the `jjbly.uk` zone on the
Windows DC (192.168.4.62), pointing to the nginx ingress controller at
192.168.4.63. Cloudflare has no A record for this hostname — it stays
internal-only.

## Nextcloud trusted domains

The `nextcloud-secrets` Kubernetes secret must have:
```
trusted-domains=nextcloud.jjbly.uk
overwriteprotocol=https
overwritehost=nextcloud.jjbly.uk
overwritecliurl=https://nextcloud.jjbly.uk
```

To recreate the secret:
```bash
kubectl delete secret nextcloud-secrets -n nextcloud
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
