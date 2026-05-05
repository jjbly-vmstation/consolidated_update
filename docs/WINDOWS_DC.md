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

AD DC is authoritative for `vmstation.local`. masternode runs BIND9 as a
forwarding secondary — all LAN queries go to 192.168.4.62 first.

DNS records to create on AD DC:

| Name | Type | Value | Note |
|------|------|-------|------|
| masternode | A | 192.168.4.63 | vmstation.local zone |
| storagenodet3500 | A | 192.168.4.61 | vmstation.local zone |
| jellyfin | A | 192.168.4.63 | lan zone — ingress controller |
| nextcloud | A | 192.168.4.63 | lan zone — ingress controller |
| vault | A | 192.168.4.63 | lan zone — ingress controller |
| grafana | A | 192.168.4.63 | lan zone — ingress controller |
| prometheus | A | 192.168.4.63 | lan zone — ingress controller |

All `*.lan` names point to masternode (192.168.4.63) where nginx ingress runs.
The ingress controller routes to the correct backend pod based on the Host header.

Create the lan zone and records:
```powershell
Add-DnsServerPrimaryZone -Name "lan" -ZoneFile "lan.dns" -DynamicUpdate None
$ip = "192.168.4.63"
foreach ($name in @("jellyfin","nextcloud","vault","grafana","prometheus")) {
    Add-DnsServerResourceRecordA -ZoneName "lan" -Name $name -IPv4Address $ip -TimeToLive 01:00:00
}
```

## Hyper-V VM subnet

Guest VMs are on 192.168.128.0/24 (Hyper-V internal/NAT switch).
Add routes or DNS records as VMs are created.

## NTP

AD DC uses Windows Time Service (w32tm). Cluster Linux nodes are configured by
the bootstrap playbook to use 192.168.4.62 as their primary NTP source.
