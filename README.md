# Homelab

Ansible Playbooks to configure Ubuntu x86_64 machines and manage a Kubernetes homelab cluster.

> This code was generated with AI assistance.

## Prerequisites

- [just](https://github.com/casey/just)
- [uv](https://github.com/astral-sh/uv)

## Setup

1.  Create a virtual environment with required dependencies:

    ```sh
    just venv
    ```

2.  Create an `inventory.yml` file with the following structure:

    ```yaml
    all:
      children:
        homelab:
          vars:
            ansible_port: <SSH_PORT>
          hosts:
            <HOSTNAME>:
              ansible_user: <USER>
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
    ```

3.  Create a `group_vars/homelab.yml` file for group-level variables:

    ```yaml
    ssh_users:
      - <USER>
      - <ANSIBLE_USER>
    dns_zone: <DNS_ZONE>
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
    bootstrap_admin_password: <BOOTSTRAP_ADMIN_PASSWORD>
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
      plex:
        port: <PORT>
        protocol: tcp
    ```

## Directory Structure

Playbooks are organized logically into categories, and each category maintains its own
`templates/` folder (if applicable) to keep playbooks and their dependencies tightly coupled:

- `infrastructure/`: OS-level configurations and bare-metal setup.
- `cluster/`: Kubernetes cluster bootstrapping and core components.
- `development/`: Language toolchains and development environments.
- `services/`: Cluster-hosted services (e.g. Gitea, ArgoCD, Syncthing).

## Usage

### Run a Playbook

To run a specific playbook on a subset of machines, specify the category and the playbook name:

```sh
just install <CATEGORY> <PLAYBOOK> [SUBSET]
```

**Example:**

```sh
just install infrastructure docker
```

or

```sh
just install cluster observability homelab
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
just lint playbooks/cluster/bootstrap.yml
```

## Notes

- **Fixed-port services**: The following `ufw_allowed_ports` entries have standard ports that are not consumed by any playbook configuration — the port values defined here are used only by the UFW firewall rules and must match what the service actually listens on: `ssh`, `kubelet`, `etcd_client`, `etcd_peer`, `cilium_vxlan`, `cilium_health`, `hubble_peer`, and `nfs`.
- **SSH port**: `ufw_allowed_ports.ssh.port` in `group_vars/homelab.yml` must match `ansible_port` in `inventory.yml`.
- **`become_exe` configuration**: `become_exe` must be set to `sudo.ws` to resolve an issue
  with Ansible. See [Ansible Issue #85837](https://github.com/ansible/ansible/issues/85837)
  for details.
- **Service playbook run order**: Some Playbooks have dependencies on others. For example, the authentication Playbook must be (re)deployed after adding a new Kubernetes service:
  ```sh
  just install services <SERVICE>
  just install cluster authentication
  ```
- **Pod Security Admission**: `cluster/security.yml` configures the kube-apiserver with a cluster-wide default Pod Security Standard (`baseline`) so every namespace is protected by default. Exempt namespaces (e.g. `kube-system`, `longhorn-system`, `vllm`, `observability`) and namespaces opted up to the `restricted` profile (e.g. `default`) are listed in the playbook `vars`. The playbook patches the static `kube-apiserver.yaml` pod manifest; the kubelet reloads the apiserver automatically. Run after `cluster/authentication.yml`:
  ```sh
  just install cluster security
  ```
  When adding a new service that needs host access (privileged pods, hostPath, hostNetwork, hostPID), add its namespace to `psa_exempt_namespaces` in `cluster/security.yml` and re-run the playbook.
- **Open WebUI and vLLM**: Open WebUI (`services/openwebui.yml`) connects to vLLM (`services/vllm.yml`) using the vLLM API key from the `vllm-credentials` Secret. vLLM must be deployed first. Open WebUI's built-in authentication is disabled — access is gated entirely by Traefik ForwardAuth (Authentik). The `vllm_host` inventory variable controls which nodes run a vLLM instance.
- **Jellyfin**: Jellyfin (`services/jellyfin.yml`) is a self-hosted media server deployed via the official Helm chart. All access is gated by Traefik ForwardAuth backed by Authentik — no OIDC plugin is required. After deploying, re-run `cluster/authentication.yml` to apply the HTTPRoute and ForwardAuth middleware.
- **Local DNS Resolution**: To resolve homelab services (e.g., `*.homelab.internal`) from your local machine, configure your OS to use the cluster's Bind9 LoadBalancer IP as its nameserver. Note that Syncthing sync traffic uses a **dedicated LoadBalancer IP** (separate from the web GUI) to ensure high-performance data transfer.
  - **macOS Setup**:
    ```sh
    sudo mkdir -p /etc/resolver
    echo "nameserver <BIND9_LB_IP>" | sudo tee /etc/resolver/<DNS_ZONE>
    ```
- **Flushing the local DNS cache**: If a service is unreachable or resolves to a stale IP after a cluster change, flush the local DNS cache. Common triggers include deploying a new service, changing a LoadBalancer IP, or redeploying Bind9:
  ```sh
  just flush-dns
  ```
