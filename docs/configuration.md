# Configuration Reference

`inventory.yml` and everything under `group_vars/` are gitignored — they carry
addresses, ports, and identifiers specific to one deployment. That makes this
document the **only version-controlled record of their shape**: which variables
exist, what each one controls, and which ones constrain each other.

Every value below is bracket notation (`<HOSTNAME>`, `<PORT>`). **Never commit a
real value into this file** — the whole point of the schema living here is that
the values do not.

Playbook paths are relative to `playbooks/nodes/`. The machines these variables
describe are covered in [architecture.md](architecture.md).

## Files

| File | Applies to | Purpose |
|------|-----------|---------|
| `inventory.yml` | — | Hosts, connection settings, and the per-host role flags |
| `group_vars/all.yml` | Every group | Identifiers shared by nodes and the IP KVM alike |
| `group_vars/nodes.yml` | `nodes` | Cluster-node settings: storage, firewall, lifecycle |
| `group_vars/ipkvm.yml` | `ipkvm` | IP KVM settings: firewall and tailnet |

Ansible's precedence rules mean a variable set in a play overrides one sourced
from `group_vars`. Anything listed here should therefore be defined **only** in
these files — redefining one in a playbook's `vars:` block silently shadows the
value the operator set.

---

## `inventory.yml`

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
          registry_cache_node: <true|false>
          slurm_controller: <true|false>
          slurm_compute_node: <true|false>
          vllm_host: <true|false>
          thread_radio_host: <true|false>
          thread_radio_device_path: <DEVICE_PATH>
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

### Connection settings

| Variable | Controls |
|----------|----------|
| `ansible_port` | SSH port Ansible connects on. Must match `ufw_allowed_ports.ssh.port`. |
| `ansible_python_interpreter` | Absolute path to the interpreter on the target. Pinned explicitly so a distribution changing its default Python cannot silently change which interpreter runs. |
| `ansible_user` | The account Ansible connects as. Created during the manual OS install, before any playbook can run. |
| `ansible_remote_tmp` | *(IP KVM only)* A writable temporary directory. Required because the appliance's root filesystem is mounted read-only, so Ansible's default location under the user's home is not writable. |

### Per-host facts

These describe what the manual OS install actually produced. Nothing discovers
them, so a mismatch between what is recorded here and what is on the machine
causes the playbooks to fail — or to configure the wrong thing.

| Variable | Controls |
|----------|----------|
| `private_ip` | The host's static LAN address. |
| `network_interface` | NIC name, used for Netplan configuration, Wake-on-LAN, and Cilium's L2 announcement policy. |
| `mac_address` | NIC hardware address, the target of Wake-on-LAN magic packets. |

### Per-host role flags

Every node runs the same playbooks; these flags are the only thing that
differentiates them. Flags marked *exactly one* must be true on a single host.

| Flag | Effect when true |
|------|------------------|
| `control_plane` | Host runs the Kubernetes control plane. |
| `bootstrap_node` | *(exactly one)* Host initializes the cluster and is where run-once, cluster-wide tasks execute. |
| `worker_node` | Host accepts scheduled workloads. |
| `nfs_server` | *(exactly one)* Host exports the NFS share; every other node mounts it. |
| `registry_cache_node` | *(exactly one)* Host holds the registry proxy cache's image blobs on local disk. The blob PersistentVolume is pinned here by node affinity, which places Harbor's registry pod here too. |
| `slurm_controller` | *(exactly one)* Host runs `slurmctld` and holds the munge key that is distributed to the rest. |
| `slurm_compute_node` | Host runs `slurmd` and accepts batch jobs. Can be combined with `slurm_controller`. |
| `vllm_host` | Host is labeled for the vLLM DaemonSet. Defaults to true. |
| `thread_radio_host` | *(exactly one)* Host physically holds the Thread USB radio. Both the border router and the Matter server pin themselves here, so moving the radio means re-flagging rather than editing manifests. |
| `thread_radio_device_path` | Stable `/dev/serial/by-id/...` path to that radio. The by-id path is used rather than `/dev/ttyUSB*` because the latter is assigned in enumeration order and changes across reboots. |
| `tailscale` | Host joins the tailnet. |
| `tailscale_exit_node` | Host advertises itself as an exit node and subnet router for the LAN. |

---

## `group_vars/all.yml`

```yaml
pass_namespace: <PASS_NAMESPACE>
dns_zone: <DNS_ZONE>
bind9_lb_ip: <BIND9_LB_IP>
lan_cidr: <CIDR>
lan_broadcast: <BROADCAST_IP>
tailscale_tailnet: <TAILSCALE_TAILNET>
tailscale_exit_node_tag: <TAILSCALE_EXIT_NODE_TAG>
tailscale_client_tag: <TAILSCALE_CLIENT_TAG>
tailscale_ssh_server_tag: <TAILSCALE_SSH_SERVER_TAG>
tailscale_upgrade: <true|false>
tailscale_min_version: <TAILSCALE_MIN_VERSION>
ssh_identity_file: <SSH_IDENTITY_FILENAME>
dropbear_identity_file: <DROPBEAR_IDENTITY_FILENAME>
dropbear_pass_private: '{{ pass_namespace }}/dropbear/private-key'
dropbear_pass_public: '{{ pass_namespace }}/dropbear/public-key'
```

| Variable | Controls |
|----------|----------|
| `pass_namespace` | Prefix for every entry the playbooks read from or write to the operator's `pass` store, so homelab secrets cannot collide with unrelated entries. |
| `dns_zone` | The internal DNS zone Bind9 is authoritative for. Every service hostname and the wildcard certificate derive from it. |
| `bind9_lb_ip` | The LoadBalancer IP Bind9 listens on. Pinned rather than pool-assigned, because nodes, pods, and LAN clients all point at this address directly — a changing IP would strand every resolver at once. |
| `lan_cidr` | The LAN subnet. Used to scope firewall rules and to advertise subnet routes over Tailscale. |
| `lan_broadcast` | The LAN broadcast address, used by the `just wake` recipe to send Wake-on-LAN packets. |
| `tailscale_tailnet` | Tailnet name, used for API calls against the tailnet's ACL. |
| `tailscale_exit_node_tag`, `tailscale_client_tag`, `tailscale_ssh_server_tag` | ACL tags assigned to hosts. `shared/infrastructure/tailscale.yml` owns the tag definitions and must run before any per-host Tailscale playbook assigns them. |
| `tailscale_upgrade` | Whether a Tailscale playbook run may upgrade an already installed client. Kept `false` so routine deploys never move the version — the IP KVM is the only always-on exit node, so a regression there costs remote access. Overridden per run with `-e tailscale_upgrade=true`, deploying the `ipkvm` and `nodes` playbooks together: neither package source can be pinned to a chosen version, so upgrading in step is what bounds the drift between them. |
| `tailscale_min_version` | Lowest Tailscale client version accepted on any host, asserted after install and before joining the tailnet. A security floor rather than a freshness check — Tailscale publishes no support window, so the only floors that bind are the retroactive ones an advisory creates. |
| `ssh_identity_file` | Filename (within `~/.ssh`) of the key used for normal node access. |
| `dropbear_identity_file` | Filename of the *separate* key used to unlock LUKS from the initramfs. Deliberately distinct from `ssh_identity_file`: the initramfs environment is a minimal, pre-boot context, so its key is scoped to that job alone. |
| `dropbear_pass_private`, `dropbear_pass_public` | `pass` store paths for that keypair, templated off `pass_namespace` so the namespace is set in one place. |

---

## `group_vars/nodes.yml`

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
router_private_ip: <ROUTER_IP>
shutdown_schedule: <SHUTDOWN_SCHEDULE>
shutdown_mode: <suspend|shutdown>
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
  node_exporter:
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
  otbr_rest:
    port: <PORT>
    protocol: tcp
  matter_server:
    port: <PORT>
    protocol: tcp
  mdns:
    port: <PORT>
    protocol: udp
tailscale_key_expiry_disabled: <true|false>
tailscale_ssh: <true|false>
```

### Access and storage

| Variable | Controls |
|----------|----------|
| `ssh_users` | Accounts added to the `ssh` group. The hardened `sshd` config permits login only for members of that group, so omitting an account here locks it out. |
| `nfs_export_path` | Path the NFS server exports. |
| `nfs_mount_point` | Path clients mount that export at. |
| `nfs_k8s_path` | Subdirectory under the mount that holds Kubernetes PersistentVolume data, keeping cluster data separate from other content on the share. |
| `nfs_group`, `nfs_group_gid` | Shared group owning the export. The GID is pinned explicitly because it must be identical on every node for the share's permissions to be consistent. |
| `nonroot_uid` | UID that non-root workloads run as. Directories created on the NFS share by earlier root-run pods need `g+w` before a non-root pod can write to them. |
| `lb_ip_pool_cidr` | The CIDR block Cilium hands out LoadBalancer IPs from. **Must not overlap** the router's DHCP range or any static assignment — nothing detects a collision, and the symptom is intermittent unreachability rather than a clear error. |
| `router_private_ip` | The LAN gateway address. |

### Lifecycle and operations

| Variable | Controls |
|----------|----------|
| `shutdown_schedule` | Cron schedule, in standard 5-field notation, for the nightly power-down. |
| `shutdown_mode` | `shutdown` for a full power-off, `suspend` for suspend-to-RAM. The nightly cycle is meant to run as `shutdown` with a Wake-on-LAN cold boot: the nodes' firmware exposes only the fragile `s2idle` sleep state, and resume races through the iSCSI/Longhorn teardown that a cold boot sidesteps entirely. See [systemd.md](systemd.md). |
| `admin_email` | Contact address used for certificate issuance and alert routing. |
| `falco_sensitive_file_container_only` | When true, Falco's *Read sensitive file untrusted* rule fires only for processes inside containers. Suppresses the constant host-level noise that Ansible itself generates by reading files like `/etc/shadow`. |
| `tailscale_key_expiry_disabled` | Disables key expiry for the host's tailnet node, so an unattended machine does not drop off the tailnet when its key would otherwise expire. |
| `tailscale_ssh` | Enables Tailscale SSH on the host. |

### `ufw_allowed_ports`

A single map of every port opened in the host firewall, keyed by the service
that needs it. Two properties are not obvious:

- **`node_only: true`** restricts the rule to other cluster nodes rather than the
  whole LAN. Used for traffic that should never be reachable from a general LAN
  client — etcd, the kubelet API, Cilium's internal ports, SLURM daemons.
- **Some entries are firewall-only.** Their port value is not consumed by any
  playbook configuration; it exists solely to open a hole for a service that
  listens on a fixed, standard port. These values must match what the service
  actually listens on, because nothing else will make them agree: `ssh`,
  `kubelet`, `node_exporter`, `etcd_client`, `etcd_peer`, `cilium_vxlan`,
  `cilium_health`, `hubble_peer`, `nfs`, `plex`, and `mdns`.

Everything else is read by the playbook that configures the corresponding
service, so changing the value there changes both the firewall rule and the
service's own listener together.

Some ports additionally need a **pod-CIDR rule** on top of the LAN rule, because
Cilium's masquerading is asymmetric for pod-to-host traffic: a pod reaching a
host port arrives with a pod source address, which the LAN-scoped rule does not
match. `infrastructure/network.yml` opens `hubble_peer`, `node_exporter`,
`kubernetes_api`, `otbr_rest`, and `matter_server` from the pod CIDR for exactly
this reason. Any new host-port service that in-cluster pods must reach — a
Prometheus scrape target especially — needs the same pair of rules, and the
symptom of forgetting the second one is a target that times out only from inside
the cluster.

---

## `group_vars/ipkvm.yml`

```yaml
tailscale_port: <TAILSCALE_PORT>
tailscale_exit_node: <true|false>
tailscale_key_expiry_disabled: <true|false>
tailscale_ssh: <true|false>
tailscale_hostname: <TAILSCALE_HOSTNAME>
ssh_users:
  - <USER>
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
  tailscale:
    port: <PORT>
    protocol: udp
  pikvm_webrtc:
    port: <PORT_RANGE>
    protocol: udp
```

| Variable | Controls |
|----------|----------|
| `tailscale_port` | UDP port `tailscaled` listens on. Set explicitly here, unlike on the nodes, so the matching `firewall_allowed_ports.tailscale` rule has a fixed value to open. |
| `tailscale_hostname` | The name the appliance registers under in the tailnet. |
| `ssh_users` | Accounts permitted to log in. |
| `firewall_allowed_ports` | Same shape as `ufw_allowed_ports`, but consumed by **nftables**, not UFW — the Arch Linux ARM `ufw` package is a Python application coupled to a specific Python version, which breaks on a rolling distribution whose aarch64 mirror lags. The key name differs to make that distinction visible at a glance. |
| `pikvm_webrtc` | The RTP/ICE port *range* used for WebRTC video. Written as a quoted string rather than a number because nftables expects the dash-range syntax inside a port set. |

---

## Constraints that span files

These are the couplings that no single file makes visible.

- **SSH port.** `ufw_allowed_ports.ssh.port` in `group_vars/nodes.yml` must match
  `ansible_port` in `inventory.yml`. If they diverge, the firewall closes the
  port Ansible is connecting on, and the next run of the network playbook locks
  the operator out of the nodes.
- **`become_exe` is `sudo.ws` on nodes, plain `sudo` on the IP KVM.** The
  `sudo.ws` setting works around an Ansible bug
  ([ansible#85837](https://github.com/ansible/ansible/issues/85837)); it is not a
  preference. `sudo.ws` is not available on Arch Linux, which is why the IP KVM
  playbooks use standard `sudo` instead.
- **Exactly-one flags.** `bootstrap_node`, `nfs_server`, `registry_cache_node`,
  `slurm_controller`, and `thread_radio_host` must each be true on exactly one
  host. Nothing validates this; setting two produces conflicting cluster state
  rather than an error.
- **`lb_ip_pool_cidr` versus the LAN.** The pool must sit inside `lan_cidr` (so
  L2 announcement reaches LAN clients) while staying outside the router's DHCP
  range (so nothing else is handed the same address).

## Keeping this file honest

Nothing enforces agreement between this document and the playbooks that read
these variables. When a playbook introduces a variable that belongs in
`group_vars` or the inventory, add it here in the same change — otherwise the
only record of the configuration surface silently becomes incomplete, and the
gap is invisible until a rebuild.
