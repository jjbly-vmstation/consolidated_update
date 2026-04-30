# Wake-on-LAN

## MAC Addresses

| Node | IP | MAC |
|------|----|-----|
| masternode | 192.168.4.63 | `00:e0:4c:68:cb:bf` |
| storagenodet3500 | 192.168.4.61 | `b8:ac:6f:7e:6c:9d` |
| homelab (WSDC-Homelab) | 192.168.4.62 | `d0:94:66:30:d6:63` |

## Waking a node

```bash
# Install wakeonlan (Debian)
sudo apt install wakeonlan

# Wake storagenodet3500
wakeonlan b8:ac:6f:7e:6c:9d

# Wake homelab
wakeonlan d0:94:66:30:d6:63
```

## Requirements

- WoL must be enabled in the node's BIOS/UEFI
- Node must be on the same LAN segment (192.168.4.0/24)
- Switch port must support WoL magic packet forwarding (ciscosw1 does by default)
- On Linux nodes, the NIC must have WoL enabled:
  ```bash
  ethtool -s <interface> wol g
  ```
  The bootstrap playbook does this automatically.

## Ansible-driven wake

From inventory, each host has a `wol_mac` var. A simple ad-hoc command:

```bash
ansible masternode -i ansible/inventory/hosts.yml -m shell \
  -a "wakeonlan b8:ac:6f:7e:6c:9d"
```
