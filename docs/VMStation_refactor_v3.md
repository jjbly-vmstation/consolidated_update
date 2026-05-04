# VMStation consolidated refactor / simplify stack v3
Aims to minimize documentation and technical drift while moving to new system setup.

---

## Overview
- **Purpose:** With the introduction of the new Windows Server Domain Controller we need to adjust the IdP stack due to the introduction of a centralized Kerberos provider, DNS server, etc.
- **Related systems:** Potentially entire LAN infrastructure will be using this ADDC as its DNS. Majorly affects masternode, storagenodet3500, WSDC-Homelab (previously named 'homelab').

---

## Architecture
### System Diagram
                                                          ----->+----------------------+
                                              -----------/      |                      |
                 +---------------------------/                  |   storagenodet3500   |
                 |                      |                       |                      |
                 | AD Domain Controller |                       +----------------------+
                 |                      |                               --/
                 +-----------\----------+                            --/
                  /           \                                  ---/
                 |             -\                             --/
                 /               \                         --/
                |                 ------------------------/
                /                 |                      |
               |                  |Cisco Catalyst 3650v02|         +----------------------+
               /                  |                      |         |                      |
              |                   |                      |         |    Router/LAN        |
              /                  /-----------------------<--------->                      |
             |               /--                                   +----------------------+
             v----------------------+
             |                      |
             |      masternode      |
             |                      |
             +----------------------+

### Components
- **ciscosw1 — Cisco Catalyst 3650v02** Central switch, LAN backbone
- **masternode — MiniPC** Control plane node for Kubernetes cluster, also responsible for observability. Experimental proxy pods to wake Nextcloud/Jellyfin NAS machine as it will usually be in S5 sleep
- **storagenodet3500 — Dell Precision T3500** NAS machine hosting SAMBA/NFS shares, Jellyfin Server, media store and Nextcloud server
- **WSDC-Homelab — Dell PowerEdge R710** Windows Server 2025 Active Directory Domain Controller, responsible for IdP source of truth, DNS, NTP, etc.

---

## Strategy

### Step 1. Cleanup
Clean up previous Kubernetes deployment and remove outdated services on Linux machines.

*   **Remove all Services & Deployments:**
    `kubectl delete all --all --all-namespaces`
*   **Remove Namespaces:**
    `kubectl delete ns --all`
*   **Wipe Custom Resource Definitions (CRDs):**
    `kubectl delete crd --all`
*   **Remove old/outdated Services added manually**
    1.  Find failed services: `systemctl list-units --state-failed`
    2.  Stop and disable: `sudo systemctl stop <name> && sudo systemctl disable <name>`
    3.  Reload daemon: `sudo systemctl daemon-reload && sudo systemctl reset-failed`
*   **Wipe Local Persistent Volumes:**
    `sudo rm -rf /var/lib/kubelet/*`
*   **Clean the CNI:**
    `sudo rm -rf /etc/cni/net.d/*`
*   **Clean up virtual network interfaces:**
    `sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X`
*   **Kubeadm Reset (control plane):**
    `sudo kubeadm reset -f`

#### Cleanup Summary
| Target | Action | Why? |
| :--- | :--- | :--- |
| **K8s API** | `kubectl delete ns` | Clears the logical cluster state. |
| **Networking** | `rm -rf /etc/cni/net.d` | Prevents IP address conflicts on redeploy. |
| **Storage** | `rm -rf /var/lib/etcd` | Wipes the database for a true Day 0 start. |

---

### Step 2. Preflight checklist for joining AD DC
Ensure resolv.conf and required packages are prepared.

*   **Prepare DNS** — `/etc/resolv.conf`:
    ```conf
    search vmstation.local
    nameserver 192.168.4.62
    nameserver 8.8.8.8
    ```

*   **Install tools:**
    ```bash
    sudo apt update
    sudo apt install -y realmd sssd sssd-tools libnss-sss libpam-sss adcli samba-common-bin packagekit
    ```

*   **Confirm visibility into domain:**
    `realm discover vmstation.local`

---

### Step 3. Prepare Active Directory

#### 1. Create the Organizational Unit
1. Open **Active Directory Users and Computers** (ADUC).
2. Right-click `vmstation.local` → **New** → **Organizational Unit**.
3. Name it `K8s_Nodes`.

#### 2. Create the Service Account
1. Inside `K8s_Nodes` (or a dedicated `Service_Accounts` OU), right-click → **New** → **User**.
2. **User logon name:** `svc_k8s_join`
3. Set a strong password and check **"Password never expires"**.

#### 3. Delegate Join Permissions
1. Right-click the `K8s_Nodes` OU → **Delegate Control** → Next.
2. Add `svc_k8s_join` → Next.
3. Select **"Create a custom task to delegate"** → Next.
4. Select **"Only the following objects in the folder"**, check **Computer objects** and both Create/Delete checkboxes → Next.
5. Check **General**, **Property-specific**, and **Creation/deletion of specific child objects**.
6. Check the following permissions:
   - Reset Password
   - Read and write account restrictions
   - Validated write to DNS host name
   - Validated write to service principal name
7. Click **Finish**.

Then enable Advanced Features in ADUC (**View → Advanced Features**), right-click `K8s_Nodes` → **Properties → Security → Advanced → Add**:
- Principal: `svc_k8s_join`
- Applies to: **Descendant Computer objects**
- Permissions: Reset password, Read all properties, Write all properties, Read/Write public information

#### 4. Verify Kerberos encryption policy
**Group Policy Management → Default Domain Controllers Policy:**
`Computer Configuration → Policies → Windows Settings → Security Settings → Local Policies → Security Options → Network security: Configure encryption types allowed for Kerberos`
Ensure **AES 128** and **AES 256** are checked.

---

### Step 4. Join Linux Nodes to the Domain

#### Export the CA certificate from WSDC-Homelab

AD CS was already installed (`vmstation-WSDC-HOMELAB-CA`) and the DC held a valid
Domain Controller certificate, so LDAPS was already active on port 636.
We only needed to export the CA root so Linux nodes could trust it.

Run on **WSDC-Homelab** PowerShell (Administrator):
```powershell
# Confirm LDAPS is listening
netstat -an | findstr :636

# Export the CA root cert
# Use [0] index — Get-ChildItem returns duplicate entries for this CA
$ca = Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -like "*vmstation-WSDC-HOMELAB-CA*" }
Export-Certificate -Cert $ca[0] -FilePath C:\vmstation-ca.cer -Type CERT
certutil -encode C:\vmstation-ca.cer C:\vmstation-ca.pem
```

Transfer to each Linux node. From an RDP session the easiest method is to
`Get-Content C:\vmstation-ca.pem`, copy the output, save it as a `.pem` file
locally, then SCP it across:
```bash
scp vmstation-ca.pem jjbly@192.168.4.63:/tmp/vmstation-ca.pem
```

#### Trust the CA on each Linux node

```bash
# Must use .crt extension — update-ca-certificates ignores anything else
sudo cp /tmp/vmstation-ca.pem /usr/local/share/ca-certificates/vmstation-ca.crt
sudo update-ca-certificates
# Should output: 1 added
```

Verify LDAPS works before attempting the join:
```bash
ldapsearch -H ldaps://wsdc-homelab.vmstation.local \
  -x -b "DC=vmstation,DC=local" \
  -D "svc_k8s_join@vmstation.local" -W \
  -s base "(objectClass=*)"
# result: 0 Success
```

#### Join the node

Windows Server 2025 enforces LDAP channel binding — the SASL bind must include
a Channel Binding Token (CBT) referencing the TLS session. adcli's LDAP client
library does not send this token, so the password set fails even over LDAPS.
Samba's join implementation handles CBT correctly, so use `--membership-software=samba`
(`samba-common-bin` was already installed in Step 2):

```bash
sudo realm join --user=svc_k8s_join \
  --computer-ou="OU=K8s_Nodes,DC=vmstation,DC=local" \
  --membership-software=samba \
  vmstation.local
```

Verify the join and confirm the object is in the correct OU:
```bash
realm list
```
```powershell
# On DC
Get-ADComputer -Identity "MASTERNODE" | Select-Object DistinguishedName
# CN=MASTERNODE,OU=K8s_Nodes,DC=vmstation,DC=local
```

---

## Change History
| Date | Change | Author |
|------|--------|--------|
| 2026-03-10 | Init | Justin Bains |
| 2026-05-04 | AD join process documented through completion | Justin Bains |
