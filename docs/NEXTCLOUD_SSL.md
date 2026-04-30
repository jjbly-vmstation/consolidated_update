# Nextcloud SSL — TODO

SSL for Nextcloud is not yet implemented. Currently running HTTP on NodePort 30080.

## Planned approach

1. **Obtain certificate from AD CS** (Windows Server CA on homelab)
   - Issue a certificate for `nextcloud.lan` / `nextcloud.vmstation.local`
   - Export as PEM (cert + key)

2. **Create Kubernetes TLS secret**
   ```bash
   kubectl create secret tls nextcloud-tls \
     --cert=nextcloud.crt \
     --key=nextcloud.key \
     -n nextcloud
   ```

3. **Update Ingress to use TLS**
   ```yaml
   spec:
     tls:
       - hosts:
           - nextcloud.lan
         secretName: nextcloud-tls
     rules:
       - host: nextcloud.lan
         ...
   ```

4. **Update `OVERWRITEPROTOCOL` secret** to `https`

5. **Switch service type** from NodePort to ClusterIP (traffic enters via Ingress)

## Current state

- HTTP only
- NodePort 30080 → 192.168.4.63:30080
- Trusted domains: configured via `nextcloud-secrets` Secret
- OIDC login: removed (was tied to FreeIPA/Keycloak, both gone)
