# Printer ops kustomize overlay

This directory contains a kustomize overlay that deploys the printer-related components
(Samba share for scanner, scan mover, paperless-ngx, and PV/PVCs) into the `print` namespace.

Files:
- kustomization.yaml        - kustomize manifest list
- namespace.yaml            - creates the `print` namespace
- pvs-pvcs.yaml             - PVs and PVCs (hostPath, nodeAffinity to storagenodet3500)
- deployment-samba.yaml     - Samba Deployment + ClusterIP service (scanner writes here)
- deployment-mover.yaml     - Small mover that copies scans into paperless watch folder
- deployment-paperless.yaml - paperless-ngx Deployment + NodePort Service (31000)
- service-samba.yaml        - placeholder for CUPS/IPP NodePort (30631) if CUPS is added

How to deploy with kustomize (recommended workflow)

1) Checkout the branch that contains these manifests:
   git fetch origin
   git checkout printer-ops-v1

2) Inspect and edit files as needed (replace placeholders like DB/Redis creds and node name):
   - Ensure the node name `storagenodet3500` matches your kube node label or change it.
   - Replace simple environment passwords with Kubernetes Secrets in production.

3) Apply the overlay to your cluster:
   kubectl apply -k kustomize/printer

   This will create the `print` namespace, PVs/PVCs, Deployments and Services.

4) If a deployment requires a restart to pick up ConfigMap changes, run:
   kubectl rollout restart deployment/<name> -n print

5) Verify
   - kubectl get all -n print
   - kubectl describe pod <pod> -n print
   - Check logs: kubectl logs deployment/scan-mover -n print

6) Iterating on changes
   - Edit the YAML files locally on the printer-ops-v1 branch.
   - Commit and push to the branch:
       git add kustomize/printer/*
       git commit -m "printer: update ..."
       git push origin printer-ops-v1
   - Re-apply the overlay on the cluster:
       kubectl apply -k kustomize/printer
   - If resources require it, restart deployments with rollout restart.

Notes & recommendations
- PV hostPath directories must exist on the node and have correct permissions:
    sudo mkdir -p /srv/scan-storage /srv/paperless-input /srv/paperless-media
    sudo chown -R 1000:1000 /srv/paperless-input /srv/paperless-media
    # adjust ownership for samba user as needed

- Replace plaintext credentials with Kubernetes Secrets and mount them as env or files.
- If you require CUPS/Avahi for AirPrint, add a cups-avahi Deployment YAML to this overlay and
  include it in kustomization.yaml. That service should run hostNetwork: true for mDNS support.

