# CI/CD — Self-Hosted GitHub Actions Runner

## Decision

Use a **GitHub Actions self-hosted runner on masternode** rather than a
fully self-hosted CI system (Drone, Jenkins, etc.).

### Rationale

- **No chicken-egg problem.** The runner is a daemon that dials *out* to
  GitHub over HTTPS — GitHub never pushes in. It can be installed as a
  simple systemd service via an Ansible playbook that is a documented
  manual prerequisite, exactly like installing Ansible itself.
- **Same Actions syntax.** Existing `.github/workflows/ci.yml` runs
  on masternode's hardware with no changes to workflow files.
- **No extra infrastructure.** No Drone server, no separate database,
  no extra UI to maintain.
- **Works behind NAT.** masternode only needs outbound HTTPS to
  `github.com` — which it already has.

### Future upgrade path

Once the self-hosted runner pattern is proven, migrate to **Tekton** for
full GitHub independence. Tekton runs entirely inside the k8s cluster as
pods, triggered by webhooks. No external service dependency.

---

## Bootstrap sequence (one-time manual setup)

The runner playbook is a **documented prerequisite** — run it manually
once before the rest of the automation is wired to CI/CD.

```
1.  bootstrap/install-dependencies.sh        # install ansible, deps
2.  ansible-playbook bootstrap.yml           # containerd, kubeadm, NTP, WoL
3.  ansible-playbook masternode.yml          # DNS, syslog, node_exporter
4.  ansible-playbook cicd.yml               # install GitHub Actions runner ← TODO
    └─ registers runner with GitHub
    └─ installs as systemd service: actions-runner.service
    └─ runner comes online, picks up queued CI jobs
──────────────────────────────────────────────────────────────────────────────
5.  All subsequent changes go through CI/CD via pull requests
```

---

## TODO: implement ansible/playbooks/cicd.yml

### What the playbook must do

1. **Download the runner binary** from
   `https://github.com/actions/runner/releases` (pin the version).

2. **Register the runner** with the GitHub repo using a registration
   token. The token is short-lived (1 hour) so it must be passed at
   playbook run time, not stored in vault:
   ```bash
   ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/cicd.yml \
     -e "runner_token={{ lookup('env','GITHUB_RUNNER_TOKEN') }}"
   ```
   Generate the token at:
   `github.com/jjbly-vmstation/consolidated_update → Settings → Actions → Runners → New self-hosted runner`

3. **Install as systemd service** so it survives reboots.

4. **Run as a dedicated non-root user** (`actions-runner`) for isolation.

5. **Set runner labels** so workflow files can target it:
   ```yaml
   # .github/workflows/ci.yml
   jobs:
     lint:
       runs-on: [self-hosted, masternode]
   ```

### Playbook skeleton

```yaml
---
# cicd.yml — Install GitHub Actions self-hosted runner on masternode
# Prerequisite: run after bootstrap.yml and masternode.yml
#
# Usage:
#   export GITHUB_RUNNER_TOKEN=<token from GitHub UI>
#   ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/cicd.yml \
#     -e "runner_token=${GITHUB_RUNNER_TOKEN}"

- name: Install GitHub Actions self-hosted runner
  hosts: control_plane
  become: true
  gather_facts: true

  vars:
    runner_version: "2.317.0"          # pin — update via Renovate or manually
    runner_user: actions-runner
    runner_dir: /opt/actions-runner
    runner_labels: "self-hosted,masternode,linux,x64"
    github_repo: "jjbly-vmstation/consolidated_update"

  tasks:
    - name: Create runner user
      ansible.builtin.user:
        name: "{{ runner_user }}"
        system: true
        shell: /bin/bash
        home: "{{ runner_dir }}"
        create_home: true

    - name: Download runner tarball
      ansible.builtin.get_url:
        url: "https://github.com/actions/runner/releases/download/v{{ runner_version }}/actions-runner-linux-x64-{{ runner_version }}.tar.gz"
        dest: "/tmp/actions-runner.tar.gz"
        mode: '0644'

    - name: Extract runner
      ansible.builtin.unarchive:
        src: "/tmp/actions-runner.tar.gz"
        dest: "{{ runner_dir }}"
        remote_src: true
        owner: "{{ runner_user }}"
        group: "{{ runner_user }}"
        creates: "{{ runner_dir }}/config.sh"

    - name: Register runner with GitHub
      ansible.builtin.command:
        cmd: >
          ./config.sh
          --url https://github.com/{{ github_repo }}
          --token {{ runner_token }}
          --name masternode
          --labels {{ runner_labels }}
          --unattended
          --replace
        chdir: "{{ runner_dir }}"
      become_user: "{{ runner_user }}"
      no_log: true    # hide token from logs

    - name: Install runner as systemd service
      ansible.builtin.command:
        cmd: ./svc.sh install {{ runner_user }}
        chdir: "{{ runner_dir }}"
      args:
        creates: /etc/systemd/system/actions-runner.service

    - name: Start and enable runner service
      ansible.builtin.systemd:
        name: actions-runner
        state: started
        enabled: true
        daemon_reload: true
```

### CI workflow update needed

Once the runner is online, update `.github/workflows/ci.yml` to target it:

```yaml
jobs:
  lint:
    runs-on: [self-hosted, masternode]   # was: ubuntu-latest
```

Self-hosted runners have full access to the cluster network (kubectl,
ansible, etc.) so the workflow can also deploy — not just lint.

---

## GitHub independence upgrade (future — Tekton)

When full independence from GitHub CI infrastructure is desired:

1. Install Tekton Pipelines and Tekton Triggers into the cluster
2. Configure a GitHub webhook → Tekton EventListener
3. Mirror workflows as Tekton Pipeline + Task resources
4. Retain GitHub Actions self-hosted runner as fallback during migration

This is a significant undertaking. Defer until the self-hosted runner
pattern is stable and the operational overhead of Tekton is justified.
