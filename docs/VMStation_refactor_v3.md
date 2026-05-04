# <VMStation consolidated refactor / simplify stack v3 >
<Aims to minimize documentation and technical drift while moving to new system setup>

---

## Overview
- **Purpose:**  With the introduction to the new Windows Server Domain Controller we need to adjust IdP stack due to the introduction of a centralized Kerberos provider, DNS server, etc
- **Primary users:** 
- **Dependencies:**  
- **Related systems:** Potentially entire LAN infrastructure will be using this ADDC as it's DNS, majorly affects masternode, storagenodet3500, WSDC-Homelab (previously named 'homelab')  

---

## Architecture
### System Diagram
                                                              ----->+----------------------+            
                                                  -----------/      |                      |            
                     +---------------------------/                  |                      |            
                     |                      |                       |   storagenodet3500   |            
                     |                      |                       |                      |            
                     | AD Domain Controller |                       |                      |            
                     |                      |                       |                      |            
                     |                      |                       +----------------------+            
                     |                      |                               --/                         
                     +-----------\----------+                            --/                            
                      /           \                                  ---/                               
                     |             -\                             --/                                   
                     /               \                         --/                                      
                    |                 ------------------------/                                         
                    /                 |                      |                                          
                   |                  |                      |                                          
                   /                  |Cisco Catalyst 3650v02|                  +----------------------+
                  /                   |                      |                  |                      |
                 |                    |                      |                  |                      |
                 /                    |                      |                  |                      |
                |                    /-----------------------<------------------>                      |
                /                 /--                                           |                      |
               |               /--                                              |    Router/LAN        |
               /            /--                                                 +----------------------+
              v----------------------+                                                                  
              |                      |                                                                  
              |      masternode      |                                                                  
              |                      |                                                                  
              |                      |                                                                  
              |                      |                                                                  
              |                      |                                                                  
              +----------------------+                                                                  

### Components
- **Component 1 ciscosw1 — Cisco Catalyst 3650v02** Central Switch provides LAN backbone 
- **Component 2 masternode — MiniPC** control plane node for kubernetes cluster, also responsible for observability. Experimental proxy pods to wake Nextcloud/Jellyfin NAS machine as it will usually be in S5 sleep
- **Component 3 storagenodet3500 — Dell Precision T3500** NAS machine hosting SAMBA/NFS shares as well as Jellyfin Server, media store and Nextcloud server
- **Component 4 WSDL-Homelab — Dell poweredge R710** Windows Server 2025 Active Directory Domain Controller responsible for IdP source of truth, DNS, etc


---

## Strategy
### Step 1. Cleanup
- Clean up previous Kubernetes deployment, Remove outdated Services on linux machines

*   **Remove all Services & Deployments:**
    `kubectl delete all --all --all-namespaces`
*   **Remove the Monitoring Namespace:** 
    `kubectl delete ns --all`
    `kubectl get ns`
*   **Wipe Custom Resource Definitions (CRDs):** Remove any leftover CRDs that can cause "ghost" errors during a new install
    `kubectl delete crd --all`
    `kubectl get crd`

*   **Remove old/outdated Services that were added manually**
  ### A. Removing services
  1.  **Find the service name:**
      `systemctl list-units --type=service | grep -i failed`
      `systemctl list-units --state-failed`
  2.  **Stop and Disable it:** (This prevents it from starting on boot)
      `sudo systemctl stop prometheus-node-exporter`
      `sudo systemctl disable prometheus-node-exporter`
  ### B. Reload the Daemon
  `sudo systemctl daemon-reload`
  `sudo systemctl reset-failed`

*   **Wipe Local Persistent Volumes:**
    `sudo kubectl delete pv`
    `sudo kubectl delete pvc`

    Check `/var/lib/kubelet/pods/`:
    `sudo rm -rf /var/lib/kubelet/*`
*   **Clean the CNI (Network Interface):**
    Old IP addresses assigned to the Prometheus pods might be cached.
    `sudo rm -rf /etc/cni/net.d/*`
*   **Clean up virtual network interface links:**
    `ip link show`
    `sudo ip link delete 'name' `
    `sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X`

## Complete cluster destruction
**Kubeadm Reset:** perform on control plane:
  `sudo kubeadm reset -f`

---

### Summary Checklist
| Target | Action | Why? |
| :--- | :--- | :--- |
| **Prometheus** | `systemctl disable` | Stops the boot-time log spam. |
| **K8s API** | `kubectl delete ns` | Clears the "logical" cluster state. |
| **Networking** | `rm -rf /etc/cni/net.d` | Prevents IP address conflicts on redeploy. |
| **Storage** | `rm -rf /var/lib/etcd` | Wipes the database for a true "Day 0" start. |



### Step 2. Preflight checklist for joining AD DC
- Ensure resolv.conf and required packages are prepared

*   **Prepare DNS**
    ```conf
    search vmstation.local
    nameserver 192.168.4.62
    nameserver 8.8.8.8
    ```

*   **Install tools** 
    ```bash 
    sudo apt update
    sudo apt install -y realmd sssd sssd-tools libnss-sss libpam-sss adcli samba-common-bin packagekit
    ```
*   **Confirm visibility into domain**
    `realm discover vmstation.local`

*   **Create Organizational Units**
    ### 1. Create the dedicated *Organizational Unit (OU)*
      1.  Open **Active Directory Users and Computers** (ADUC).
      2.  Right-click your domain (`vmstation.local`) -> **New** -> **Organizational Unit**.
      3.  Name it `K8s_Nodes`

    ### 2. Create the Service Account
    1.  Inside your `K8s_Nodes` OU (or a dedicated `Service_Accounts` OU), right-click -> **New** -> **User**.
    2.  **Full Name:** `Kubernetes Join Service`
    3.  **User logon name:** `s_k8s_join`
    4.  **Password:** Set a strong password.
    5.  **Crucial:** Check **"Password never expires"**. (You don't want your nodes losing domain trust because of a 90-day password policy).

    ### 3. Delegate Join Permissions
    By default, any user can join 10 machines, but "Delegating Control" allows this account to manage these specific objects indefinitely without being an Admin.
    1.  Right-click your new **`K8s_Nodes`** OU.
    2.  Select **Delegate Control...** and click **Next**.
    3.  Click **Add**, type `s_k8s_join`, and click **OK**, then **Next**.
    4.  Select **"Create a custom task to delegate"** and click **Next**.
    5.  Select **"Only the following objects in the folder"** and check:
        *   **Computer objects**
        *   Check **"Create selected objects in this folder"** and **"Delete selected objects in this folder"**.
    6.  Click **Next**.
    7.  Check **General**, **Property-specific**, and **Creation/deletion of specific child objects**.
    8.  In the list, check:
        *   **Reset Password**
        *   **Read and write account restrictions**
        *   **Validated write to DNS host name**
        *   **Validated write to service principal name**
        *   **This account supports Kerberos AES 128 bit encryption** and **AES 256 bit**

    9.  Click **Finish**.

    10. Go to Group Policy Management and checkl 
        * Open Group Policy Management on your Windows DC.
        * Look at the Default Domain Controllers Policy.
        * Navigate to: Computer Configuration -> Policies -> Windows Settings -> Security Settings -> Local Policies -> Security Options.
        * Find: Network security: Configure encryption types allowed for Kerberos.
        * Check AES 128 and 256?

    11. Enable Advanced Features In the Active Directory Users and Computers window:
        * Click the View menu at the top.
        * Click on Advanced Features. (The screen might flicker as it refreshes).
        * Now, right-click your K8s_Nodes OU and select Properties.
        * The Security tab should now be visible between Managed By and Object.

    12. Set the "Descendant" Permissions
        * Click Advanced (at the bottom).
        * Click Add to add a new permission entry.
        * Click Select a principal and type svc_k8s_join.
        * Change the Applies to dropdown from "This object and all descendant objects" to "Descendant Computer objects".
        * Check the following boxes:
          * Reset password
          * Read all properties
          * Write all properties
          * Read/Write public information

    ---

    ### 4. Join the Linux Node to the Specific OU
    `realm` needs to put the computer in that specific OU, ensure a clean join.

    **Run this on your Linux nodes:**
    ```bash
    sudo realm leave
    sudo realm discover vmstation.local
    sudo realm join --user=svc_k8s_join --computer-ou="OU=K8s_Nodes,DC=vmstation,DC=local" --membership-software=adcli vmstation.local
    ```
    Note an error was thrown 
    ```bash
    sudo realm join --user=svc_k8s_join --computer-ou="OU=K8s_Nodes,DC=vmstation,DC=local" --membership-software=adcli vmstation.local
    Password for svc_k8s_join: 
    See: journalctl REALMD_OPERATION=r11755471.3442696
    realm: Couldn't join realm: Failed to join the domain
    ```
    journalctl revealed disabled Kerberos encryption types
    * edit `sudo nano /etc/krb5.conf` with 
    ```bash
    [libdefaults]
      default_realm = VMSTATION.LOCAL
      dns_lookup_realm = false
      dns_lookup_kdc = true
      # Add these lines:
      permitted_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
    ```

### Why this is the "Pro" way:
*   **Security:** If the `s_k8s_join` account is ever compromised, the attacker can only mess with the computers in that specific `K8s_Nodes` folder, not your entire domain.
*   **Automation:** As you add more worker nodes to your Kubernetes cluster, you can use this same service account in a script without worrying about Domain Admin credentials being exposed.

**Once you run that command, check your ADUC "K8s_Nodes" folder—you should see your Linux hostname appear there as a Computer object!**`
``````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````








### Step summary
1.  SSH into control plane and spin down kubernetes cluster, cleanup any leftover configs and interfaces manually 
2.  Prepare machines for joining Domain Controller
3.  

- Step 2  Deploy minimal Kubernetes 


### Steps
1.  
2.  
3.  

- Step 3  

### Steps
1.  
2.  
3.  

---

## Configuration
### Config Files
**Path:** `C:\path\to\config` or `/etc/...`  
**Keys:**  
- `key1`: description  
- `key2`: description  

### Environment Variables
- `VAR_NAME`: purpose  
- `VAR_NAME2`: purpose  

---

## Usage
### Common Commands
- `command --flag`: what it does  
- `script.ps1`: purpose  

### Workflows
#### Routine Task 1
1.  
2.  
3.  

#### Routine Task 2
1.  
2.  
3.  

---

## Maintenance
### Scheduled Tasks
- Daily:  
- Weekly:  
- Monthly:  

### Logs
- **Location:**  
- **Rotation policy:**  
- **How to read them:**  

---

## Troubleshooting
### Common Issues
- **Issue:**  
  **Cause:**  
  **Fix:**  

- **Issue:**  
  **Cause:**  
  **Fix:**  

### Diagnostic Commands
- `command`: what it reveals  
- `powershell cmd`: purpose  

---

## Security
- Authentication method  
- Permissions model  
- Backup strategy  
- Recovery steps  

---

## Change History
| Date | Change | Author |
|------|---------|--------|
| YYYY‑MM‑DD | Init | Justin Bains |

---

## Appendix
### File Structure
