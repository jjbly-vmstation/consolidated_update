# Cisco Switch Reference (ciscosw1)

LAN switch for the vmstation.local homelab.

## Port assignments

| Port | Device | Notes |
|------|--------|-------|
| Gi0/1 | masternode | 192.168.4.63 |
| Gi0/2 | storagenodet3500 | 192.168.4.61 |
| Gi0/3 | homelab (WSDC-Homelab) | 192.168.4.62 |
| Gi0/4 | Uplink / router | 192.168.4.1 |

## Useful commands

```
# Show interface status
show interfaces status

# Show MAC address table
show mac address-table

# Show IP ARP (if L3 switch / SVI configured)
show ip arp

# Save config
copy running-config startup-config
```

## WoL note

Magic packets are broadcast traffic. If nodes are on the same VLAN (they are),
the switch forwards them without special configuration.
