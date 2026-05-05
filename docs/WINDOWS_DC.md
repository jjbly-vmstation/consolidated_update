# Windows Server 2025 — AD DC + Hyper-V Host (WSDC-Homelab)

## Role

`homelab` (192.168.4.62) was re-imaged as Windows Server 2025 and serves as:
- **Primary AD DC** — `vmstation.local` domain
- **Primary DNS** — all LAN clients resolve through it
- **Primary NTP** — all cluster nodes point to 192.168.4.62
- **Hyper-V host** — VM guests on 192.168.128.0/24

## Ansible access (WinRM)

Ensure WinRM is configured:

```powershell
# Run on homelab as Administrator
winrm quickconfig -quiet
winrm set winrm/config/service/Auth '@{Basic="true"}'
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
```

Create the service account Ansible uses:

```powershell
New-LocalUser -Name "svc-ansible" -Password (ConvertTo-SecureString "<PASSWORD>" -AsPlainText -Force)
Add-LocalGroupMember -Group "Administrators" -Member "svc-ansible"
```

Store the password in Ansible vault:

```bash
ansible-vault create ansible/inventory/secrets.yml
# Add: vault_windows_ansible_password: "<PASSWORD>"
```

## DNS configuration

AD DC is authoritative for `vmstation.local` and `jjbly.uk` (internal split-brain).
All LAN clients resolve through 192.168.4.62. The `jjbly.uk` zone is internal-only —
Cloudflare is the public authoritative DNS but does NOT have A records for these
services (they are LAN-only). cert-manager uses Cloudflare only to create TXT
records for Let's Encrypt DNS-01 challenge, then removes them.

DNS records managed by `k8s-certs.yml` ansible playbook:

| Name | Type | Value | Zone | Note |
|------|------|-------|------|------|
| masternode | A | 192.168.4.63 | vmstation.local | cluster control plane |
| storagenodet3500 | A | 192.168.4.61 | vmstation.local | storage node |
| jellyfin | A | 192.168.4.63 | jjbly.uk | ingress controller |
| nextcloud | A | 192.168.4.63 | jjbly.uk | ingress controller |
| vault | A | 192.168.4.63 | jjbly.uk | ingress controller |
| grafana | A | 192.168.4.63 | jjbly.uk | ingress controller |
| prometheus | A | 192.168.4.63 | jjbly.uk | ingress controller |

The `k8s-certs.yml` playbook creates the zone and records automatically.
To create manually:
```powershell
Add-DnsServerPrimaryZone -Name "jjbly.uk" -ZoneFile "jjbly.uk.dns" -DynamicUpdate None
$ip = "192.168.4.63"
foreach ($name in @("jellyfin","nextcloud","vault","grafana","prometheus")) {
    Add-DnsServerResourceRecordA -ZoneName "jjbly.uk" -Name $name -IPv4Address $ip -TimeToLive 01:00:00
}
```

## Hyper-V VM subnet

Guest VMs are on 192.168.128.0/24 (Hyper-V internal/NAT switch).
Add routes or DNS records as VMs are created.

## NTP

AD DC uses Windows Time Service (w32tm). Cluster Linux nodes are configured by
the bootstrap playbook to use 192.168.4.62 as their primary NTP source.
