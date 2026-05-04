# Homelab

Ansible playbooks to configure Ubuntu x86_64 compute nodes, Arch Linux-based IP KVM devices, and manage a Kubernetes homelab cluster.

> This code was generated with AI assistance.

## Prerequisites

- [just](https://github.com/casey/just)
- [uv](https://github.com/astral-sh/uv)
- [bao](https://openbao.org/)
- [gnupg](https://gnupg.org/)
- [pass](https://www.passwordstore.org/)

## Setup

1.  Create a virtual environment with required dependencies:

    ```sh
    just venv
    ```

2.  Create an `inventory.yml` file with the following structure:

    ```yaml
    all:
      children:
        nodes:
          vars:
            ansible_port: <SSH_PORT>
            ansible_python_interpreter: <PYTHON_PATH>
            ansible_user: <USER>
          hosts:
            <HOSTNAME>:
              private_ip: <IP>
              network_interface: <INTERFACE>
              mac_address: <MAC>
              control_plane: <true|false>
              bootstrap_node: <true|false>
              worker_node: <true|false>
              nfs_server: <true|false>
              slurm_controller: <true|false>
              slurm_compute_node: <true|false>
              vllm_host: <true|false>
              tailscale: <true|false>
              tailscale_exit_node: <true|false>
        ipkvm:
          vars:
            ansible_python_interpreter: <PYTHON_PATH>
            ansible_user: <USER>
            ansible_remote_tmp: <TMP_PATH>
          hosts:
            <HOSTNAME>:
              private_ip: <IP>
    ```

3.  Create a `group_vars/all.yml` file for variables shared across all inventory groups:

    ```yaml
    pass_namespace: <PASS_NAMESPACE>
    dns_zone: <DNS_ZONE>
    bind9_lb_ip: <BIND9_LB_IP>
    tailscale_tailnet: <TAILSCALE_TAILNET>
    tailscale_exit_node_tag: <TAILSCALE_EXIT_NODE_TAG>
    tailscale_client_tag: <TAILSCALE_CLIENT_TAG>
    tailscale_ssh_server_tag: <TAILSCALE_SSH_SERVER_TAG>
    ```

4.  Create a `group_vars/nodes.yml` file for cluster-node group variables:

    ```yaml
    ssh_users:
      - <USER>
      - <ANSIBLE_USER>
    nfs_export_path: <NFS_EXPORT_PATH>
    nfs_mount_point: <NFS_MOUNT_POINT>
    nfs_k8s_path: <NFS_K8S_PATH>
    nfs_group: <NFS_GROUP>
    nfs_group_gid: <NFS_GROUP_GID>
    nonroot_uid: <NONROOT_UID>
    lb_ip_pool_cidr: <CIDR>
    lan_cidr: <CIDR>
    router_private_ip: <ROUTER_IP>
    shutdown_schedule: <SHUTDOWN_SCHEDULE>
    admin_email: <ADMIN_EMAIL>
    falco_sensitive_file_container_only: <true|false>
    ufw_allowed_ports:
      ssh:
        port: <PORT>
        protocol: tcp
      dropbear:
        port: <PORT>
        protocol: tcp
      kubernetes_api:
        port: <PORT>
        protocol: tcp
      kubelet:
        port: <PORT>
        protocol: tcp
        node_only: true
      etcd_client:
        port: <PORT>
        protocol: tcp
        node_only: true
      etcd_peer:
        port: <PORT>
        protocol: tcp
        node_only: true
      cilium_vxlan:
        port: <PORT>
        protocol: udp
        node_only: true
      cilium_health:
        port: <PORT>
        protocol: tcp
        node_only: true
      hubble_peer:
        port: <PORT>
        protocol: tcp
        node_only: true
      traefik_http:
        port: <PORT>
        protocol: tcp
      traefik_https:
        port: <PORT>
        protocol: tcp
      bind9_dns_tcp:
        port: <PORT>
        protocol: tcp
      bind9_dns_udp:
        port: <PORT>
        protocol: udp
      gitea_ssh:
        port: <PORT>
        protocol: tcp
      vllm_api:
        port: <PORT>
        protocol: tcp
      nfs:
        port: <PORT>
        protocol: tcp
      tailscale:
        port: <PORT>
        protocol: udp
      slurm_ctld:
        port: <PORT>
        protocol: tcp
        node_only: true
      slurm_d:
        port: <PORT>
        protocol: tcp
        node_only: true
      syncthing_sync_tcp:
        port: <PORT>
        protocol: tcp
      syncthing_sync_udp:
        port: <PORT>
        protocol: udp
      syncthing_discovery:
        port: <PORT>
        protocol: udp
    tailscale_key_expiry_disabled: <true|false>
    tailscale_ssh: <true|false>
    ```

5.  Create a `group_vars/ipkvm.yml` file for IP KVM group variables:

    ```yaml
    tailscale_port: <TAILSCALE_PORT>
    tailscale_exit_node: <true|false>
    tailscale_key_expiry_disabled: <true|false>
    tailscale_ssh: <true|false>
    tailscale_hostname: <TAILSCALE_HOSTNAME>
    ssh_users:
      - <USER>
    lan_cidr: <CIDR>
    firewall_allowed_ports:
      ssh:
        port: <PORT>
        protocol: tcp
      pikvm_http:
        port: <PORT>
        protocol: tcp
      pikvm_https:
        port: <PORT>
        protocol: tcp
    ```

## Directory Structure

Playbooks are organized by Ansible inventory group, then by category. Each category maintains its
own `templates/` folder (if applicable) to keep playbooks and their dependencies tightly coupled:

- `playbooks/nodes/infrastructure/`: OS-level configurations and bare-metal setup.
- `playbooks/nodes/cluster/`: Kubernetes cluster bootstrapping and core platform components,
  including the Git server (`git.yml`) and GitOps controller (`gitops.yml`).
- `playbooks/nodes/development/`: Language toolchains, development environments, and common CLI
  utilities.
- `playbooks/nodes/service/`: Cluster-hosted user services (e.g. Syncthing, Jellyfin,
  Vaultwarden).
- `playbooks/ipkvm/infrastructure/`: OS-level configurations for IP KVM devices.
- `playbooks/shared/infrastructure/`: Tailnet- and other cross-group config that targets
  `localhost` rather than a specific inventory group (e.g. the Tailscale ACL).

## Usage

### Run a Playbook

To run a specific playbook, specify the inventory group, category, and playbook name:

```sh
just install <GROUP> <CATEGORY> <PLAYBOOK>
```

**Examples:**

```sh
just install nodes infrastructure docker
just install nodes cluster observability
just install shared infrastructure tailscale
just install ipkvm infrastructure tailscale
```

### Verify Connectivity

To ping a subset of machines:

```sh
just ping <SUBSET>
```

### Linting

To lint all playbooks, or optionally a specific playbook or directory:

```sh
just lint [TARGET]
```

**Example:**

```sh
just lint playbooks/nodes/cluster/bootstrap.yml
```

## Kubernetes

### Deploy a New Cluster

Requires `ssh`, `network`, `docker`, and optionally `nfs` from `playbooks/nodes/infrastructure/`
to be installed first. Then run the cluster playbooks in this order:

1. `kubernetes`
2. `bootstrap`
3. `network`
4. `storage`
5. `database`
6. `observability`
7. `secrets`
8. `authentication`
9. `git`
10. `gitops`
11. `security`

Once complete, services in `playbooks/nodes/service/` are self-contained and can be installed in
any order.

### Destroy the Cluster

Run on each node to tear down Kubernetes and reset cluster state:

```sh
kubeadm reset -f --cri-socket unix:///var/run/cri-dockerd.sock
```

## Notes

- **Fixed-port services**: The following `ufw_allowed_ports` entries have standard ports that are
  not consumed by any playbook configuration — the port values defined here are used only by the
  UFW firewall rules and must match what the service actually listens on: `ssh`, `kubelet`,
  `etcd_client`, `etcd_peer`, `cilium_vxlan`, `cilium_health`, `hubble_peer`, and `nfs`.
- **SSH port**: `ufw_allowed_ports.ssh.port` in `group_vars/nodes.yml` must match `ansible_port`
  in `inventory.yml`.
- **`become_exe` configuration**: `become_exe` must be set to `sudo.ws` on cluster nodes to resolve
  an issue with Ansible. See [Ansible Issue #85837](https://github.com/ansible/ansible/issues/85837)
  for details. IP KVM playbooks use standard `sudo` as `sudo.ws` is not available on Arch Linux.
- **Service playbook run order**: Once the cluster playbooks (`bootstrap`, `network`, `storage`,
  `database`, `observability`, `secrets`, `authentication`, `git`, `gitops`, `security`) have all been run,
  services in `playbooks/nodes/service/` are self-contained. Each service playbook applies its
  own HTTPRoute, Traefik ForwardAuth Middleware, and namespace hardening, so adding a new service
  does NOT require re-running any cluster playbook:
  ```sh
  just install nodes service <SERVICE>
  ```
- **Cluster master credentials in the pass store**: every cluster-level master key — the etcd
  encryption-at-rest key plus the OpenBao unseal keys + root token — lives in the operator's
  `pass` store (`~/.password-store/`). Secrets are namespaced under `pass_namespace` to avoid
  collision
  with other pass entries. The store must be initialized before running cluster playbooks:
  `pass init <PASS_GPG_KEY_ID>`. `cluster/bootstrap.yml` generates and stores the etcd key at
  `<pass_namespace>/kubernetes/etcd-encryption-key`. `cluster/secrets.yml` populates
  `<pass_namespace>/openbao/unseal-key-1..5` and `<pass_namespace>/openbao/root-token`. A backup
  of `~/.password-store/` covers the cluster's entire master-key set.
- **etcd encryption at rest**: `cluster/bootstrap.yml` enables AES-CBC encryption for all
  Kubernetes Secret resources. The 32-byte AES key is generated on the Ansible host on first
  install and stored in the pass store at `kubernetes/etcd-encryption-key` (see above); the
  playbook then renders `/etc/kubernetes/encryption/encryption-config.yaml` from that pass entry,
  mounts the directory read-only into the kube-apiserver pod, and patches the static pod manifest
  to consume it via `--encryption-provider-config`. After the apiserver picks the config up, the
  playbook re-encrypts every existing Secret with a `kubectl get secrets -A -o json | kubectl
  replace -f -` pass. The key never leaves the pass store or that single config file on the
  control plane, and never goes to git. If the control-plane file is ever lost, re-running
  `bootstrap.yml` reads the existing key from the pass store and restores the file (no ciphertext
  rotation needed). To rotate, edit the config file on the control plane by hand and update the
  pass entry (`pass edit kubernetes/etcd-encryption-key`), add the new key as the FIRST entry
  under `keys:`, leave the old one as the second, and re-run `bootstrap.yml`.
- **Pod Security Admission**: `cluster/security.yml` configures the kube-apiserver with a
  cluster-wide default Pod Security Standard (`restricted`) so every namespace is protected by
  default. Only true infrastructure namespaces (`kube-system`, `longhorn-system`, `cnpg-system`,
  `cert-manager`, `observability`, `falco`, `kyverno`) are listed in the apiserver-level
  `psa_exempt_namespaces` list. App service namespaces stay on the `restricted` default; if a
  service needs to opt out (e.g. `vllm` for hostPath GPU access), the service playbook applies a
  `pod-security.kubernetes.io/enforce=privileged` label on its own namespace. Adding a new service
  therefore does not require editing `cluster/security.yml`. The playbook patches the static
  `kube-apiserver.yaml` pod manifest; the kubelet reloads the apiserver automatically. Run after
  `cluster/authentication.yml`:
  ```sh
  just install nodes cluster security
  ```
- **Falco**: `cluster/security.yml` also deploys Falco as a DaemonSet via the
  `falcosecurity/falco` Helm chart. Falco monitors kernel syscalls using the modern eBPF driver
  (CO-RE, no kernel module required) and evaluates events against the default ruleset plus custom
  homelab rules. Falcosidekick forwards alerts to Alertmanager (`observability.yml` must be
  deployed first). The `falco` namespace is exempt from PSA enforcement because Falco pods require
  elevated kernel capabilities. To trigger a test detection:
  ```sh
  kubectl -n default run falco-test --image=alpine --restart=Never --rm -it -- sh
  ```
- **Open WebUI and vLLM**: Open WebUI (`service/openwebui.yml`) connects to vLLM
  (`service/vllm.yml`) using the vLLM API key from the `vllm-credentials` Secret. vLLM must be
  deployed first. Open WebUI's built-in authentication is disabled — access is gated entirely by
  Traefik ForwardAuth (Authentik). The `vllm_host` inventory variable controls which nodes run a
  vLLM instance.
- **Jellyfin**: Jellyfin (`service/jellyfin.yml`) is a self-hosted media server deployed via the
  official Helm chart. All access is gated by Traefik ForwardAuth backed by Authentik — no OIDC
  plugin is required. The HTTPRoute and ForwardAuth Middleware are applied by the Jellyfin playbook
  itself.
- **OpenBao secrets engine**: `cluster/secrets.yml` installs OpenBao (single-replica StatefulSet),
  the External Secrets Operator, Stakater Reloader, and a cluster-scoped `openbao` SecretStore.
  Reloader rolls any workload annotated with `reloader.stakater.com/auto: "true"` whenever an
  ESO-materialized Secret changes, completing the OpenBao -> ESO -> K8s Secret -> running pod
  rotation pipeline. The five unseal keys plus the initial root token are persisted to the pass
  store on the Ansible host (see *Cluster master credentials* above) — nothing is written to
  `group_vars` or rendered Helm values. The pass store is only accessed when OpenBao is sealed or
  `openbao_force_reconfigure=true` is passed; on healthy already-unsealed clusters the playbook is
  a fast no-op. Local tooling
  required: `bao`, `kubectl`, `helm`, `jq`, `curl`; the host resolver must point at bind9 (see
  *Local DNS Resolution* below). The API is exposed at `openbao.<DNS_ZONE>/v1/*`
  (token-authenticated, no ForwardAuth). After every cluster reboot OpenBao comes up sealed;
  re-running the same command unseals it:
  ```sh
  just install nodes cluster secrets
  ```
  The web UI is enabled in the pod but only reachable after `cluster/authentication.yml` runs,
  which adds a `/`-prefix HTTPRoute gated by Authentik ForwardAuth (so `openbao.<DNS_ZONE>/ui/`
  requires SSO, then OpenBao's own login). `authentication.yml` also sources the Authentik
  bootstrap password from OpenBao via ESO instead of `group_vars`. For ad-hoc CLI work:
  ```sh
  just bao-shell             # subshell with BAO_ADDR, BAO_SKIP_VERIFY, BAO_TOKEN preset
  just bao-token | pbcopy    # copy the root token for the UI Token auth method
  ```
- **Local DNS Resolution**: To resolve homelab services (e.g., `*.homelab.internal`) from your
  local machine, configure your OS to use the cluster's Bind9 LoadBalancer IP as its nameserver.
  Note that Syncthing sync traffic uses a **dedicated LoadBalancer IP** (separate from the web GUI)
  to ensure high-performance data transfer. Cluster nodes are configured automatically by
  `cluster/network.yml`; the snippets below are for additional client machines.
  - **macOS Setup**:
    ```sh
    sudo mkdir -p /etc/resolver
    echo "nameserver <BIND9_LB_IP>" | sudo tee /etc/resolver/<DNS_ZONE>
    ```
  - **Linux Setup (systemd-resolved)**:
    ```sh
    sudo mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNS=<BIND9_LB_IP>\nDomains=~<DNS_ZONE>\n' \
      | sudo tee /etc/systemd/resolved.conf.d/<DNS_ZONE>.conf
    sudo systemctl restart systemd-resolved
    ```
- **Flushing the local DNS cache**: If a service is unreachable or resolves to a stale IP after a
  cluster change, flush the local DNS cache. Common triggers include deploying a new service,
  changing a LoadBalancer IP, or redeploying Bind9:
  ```sh
  just flush-dns
  ```
