# Architecture

This document describes how compute is laid out in the homelab: the physical
machines involved, what each one is responsible for, and how the pieces relate
to one another. It is deliberately structural — the *what runs where* view — and
is the starting point for the rest of the documentation:

| Document | Covers |
|----------|--------|
| [k8-cluster-components.md](k8-cluster-components.md) | Every component installed on the cluster, as a layered stack |
| [k8-cluster-network.md](k8-cluster-network.md) | Pod networking, LAN exposure, ingress, TLS, and DNS |
| [k8-cluster-authentication.md](k8-cluster-authentication.md) | The identity provider and how each service integrates with it |
| [systemd.md](systemd.md) | Boot and shutdown ordering where systemd, NFS, and Kubernetes storage collide |
| [home-automation.md](home-automation.md) | Working notes on the Home Assistant / Thread / Matter stack |

No hostnames, addresses, or other identifying values appear below; `<zone>`
stands in for the internal DNS zone, and playbook paths are relative to
`playbooks/nodes/`.

## Physical hardware

Four classes of physical device make up the homelab. Only the first is managed
as cluster capacity; the other three exist to operate it, recover it, or consume
what it serves.

| Class | Count | Managed by Ansible | Role |
|-------|-------|--------------------|------|
| **Compute nodes** | Several | Yes — `nodes` group | Run the Kubernetes cluster and all workloads |
| **IP KVM** | One | Yes — `ipkvm` group | Out-of-band console and power control for the nodes |
| **Operator workstation (macOS)** | One | Partly — `localhost` plays | Runs the playbooks; holds the secrets and cluster credentials |
| **iOS devices** | Several | No | Clients of the services the cluster exposes |

### Compute nodes

The cluster is built from x86_64 workstations running Ubuntu. They are
homogeneous — same distribution, same base configuration, same playbooks — and
differ only in the roles assigned to them through per-host inventory flags
(`control_plane`, `worker_node`, `nfs_server`, `slurm_controller`,
`thread_radio_host`, and so on). Every node is a worker; role concentration on
any single node is a matter of inventory, not of hardware.

**AMD GPUs.** Each node carries an AMD Ryzen AI APU, so the GPU is integrated
rather than a discrete accelerator card. `infrastructure/rocm.yml` installs the
AMDGPU kernel driver and the ROCm stack on every node, and puts the accounts in
`gpu_users` into the `video` and `render` groups (via `/etc/adduser.conf`, so
new users inherit access automatically) rather than gating GPU use behind root.
`render` owns `/dev/kfd` and `/dev/dri/renderD*`, which is what ROCm opens;
`video` owns `/dev/dri/card*`. The playbook ends by running `rocminfo` as each
of those accounts, since `usermod` returning 0 does not mean the account can
open the device. The `rocm` use case installs no Vulkan driver, so Mesa's comes
from Ubuntu alongside it.

That the GPUs are APUs rather than data-center parts has a direct architectural
consequence: **the Kubernetes AMD GPU Operator does not support them** — it
targets AMD Instinct accelerators only. There is therefore no GPU device plugin
advertising a schedulable `amd.com/gpu` resource. Workloads that need the GPU
reach it by mounting the `/dev/kfd` and `/dev/dri` device nodes from the host
instead, which is why GPU workloads such as vLLM are deployed as a DaemonSet
pinned to GPU-labeled nodes rather than as a Deployment with a GPU resource
request. See `TODO.md` for the conditions under which this would be revisited.

Two independent schedulers share the same GPUs, for two different kinds of work:

- **Kubernetes** — long-running services (inference endpoints, transcoding,
  media analysis) that should always be up.
- **SLURM** — batch and interactive jobs submitted by hand, with one node acting
  as the controller and all nodes acting as compute nodes.

Because both schedulers see the same physical devices and neither is aware of
the other's allocations, GPU contention between them is not arbitrated
automatically; it is managed by not running heavy work on both at once.

Beyond compute, the nodes also provide the cluster's storage substrate. Their
local disks back Longhorn's replicated block volumes, and one node additionally
exports an NFS share used for shared, multi-writer data. Both paths are
described in [systemd.md](systemd.md), which covers the boot- and
shutdown-ordering hazards that having two storage systems on one host creates.

Node disks are LUKS-encrypted, which means a node cannot finish booting
unattended — it needs a passphrase before the root filesystem is available.
Two mechanisms bridge that gap:

- **Dropbear in the initramfs** — a minimal SSH server that comes up on the LAN
  before the root filesystem is unlocked, so the operator can log in and supply
  the key remotely.
- **Wake-on-LAN** — the NIC is configured to accept magic packets, including
  from within the initramfs environment, so a powered-off node can be started
  without physical access.

### IP KVM

A single Arch Linux-based PiKVM appliance provides out-of-band access to the
compute nodes. It is a separate inventory group (`ipkvm`) with its own
playbooks, because it shares almost nothing with the Ubuntu nodes: a different
distribution, a different package manager, a read-only root filesystem that
must be remounted read-write before any change, `nftables` instead of `ufw`,
and plain `sudo` instead of the nodes' `sudo.ws`.

Its purpose is to cover the cases the in-band paths cannot:

- Console access at the **BIOS/firmware and bootloader level**, before any
  operating system — and therefore before SSH, Dropbear, or the network stack —
  exists.
- Video, keyboard, and mouse when a node has hung hard enough that it is not
  answering the network at all — an early-boot hang before networking starts, or
  a shutdown wedged on storage teardown, neither of which leaves any remote path
  in.
- Power control, as a last resort when Wake-on-LAN and a clean shutdown are not
  options.

The IP KVM is itself a dependency-inversion risk: it is the tool used to recover
the cluster, so it must not depend on the cluster to function. It is configured
to forward only `*.<zone>` queries to the cluster's Bind9 resolver as a
split-DNS *routing* domain, precisely so that a Bind9 outage — the exact kind of
failure that would send an operator to the KVM — cannot also strand the KVM's
own name resolution.

### Operator workstation (macOS)

A single Mac is the Ansible control node. It is where every playbook in this
repository is run from, via the `just` recipes, and it is never a target of the
cluster playbooks — with the deliberate exception of the `localhost` plays that
set up the operator's own environment (SSH client configuration, the Dropbear
unlock key materialized to `~/.ssh`, and the SLURM munge key fetched from the
controller for redistribution).

It is also the trust anchor for the whole homelab, holding:

- The **`pass` store** (GPG-backed), from which playbooks read the secrets they
  seed into the cluster.
- The **SSH private keys** for the `ansible` user on the nodes, and the separate
  keypair used for Dropbear initramfs unlock.
- The **kubeconfig** used to administer the cluster.

The practical consequence is that the workstation is a single point of failure
for *administration*, though not for *operation*: the cluster keeps serving
traffic without it, but nothing can be changed, unlocked, or recovered until it
is available.

### iOS devices

Phones and tablets are pure consumers — nothing is deployed to them and they
appear nowhere in the inventory. They matter architecturally because they are
the client class least able to participate in the cluster's normal
authentication model, and that shapes how some services are exposed.

Most web UIs sit behind Traefik and are gated by Authentik ForwardAuth, which
assumes a browser that can follow a redirect to a login page and carry a session
cookie. Native mobile apps frequently cannot: they speak a fixed protocol and
authenticate with credentials the app itself holds. The Zotero iOS client is the
clearest example — it syncs file attachments over **WebDAV using HTTP Basic
authentication only**, and will not follow a redirect to an SSO provider. Its
route is therefore deployed *without* the ForwardAuth middleware, and the
WebDAV server authenticates each request itself against an htpasswd file
supplied through the cluster's secrets pipeline.

This is not a one-off. Home automation, password management, and file sync hit
the same constraint from their own companion apps, and each resolves it the same
way: for the paths those clients use, the service performs its own
authentication instead of delegating to the proxy — sometimes while its browser
UI stays gated. The full taxonomy of these integration models, and the reasoning
behind each exception, is in
[k8-cluster-authentication.md](k8-cluster-authentication.md).

iOS clients reach services over the LAN by name through Bind9, or from outside
the LAN over the Tailscale tailnet, which routes the homelab network via
subnet-route exit nodes.

## Operating systems

Three operating systems are in play, and the split falls exactly along the
hardware boundaries above. The choice is largely implicit in the playbooks —
there is no OS-detection layer and no attempt at cross-distribution
portability — so this section makes the assumptions explicit.

| OS | Where | Package manager | Managed by Ansible |
|----|-------|-----------------|--------------------|
| **Ubuntu Server (LTS, x86_64)** | Compute nodes | `apt` | Fully — `nodes` group |
| **Arch Linux ARM (aarch64)** | IP KVM | `pacman` | Fully — `ipkvm` group |
| **macOS** | Operator workstation | None (manual) | Only via `localhost` plays |
| **iOS** | Client devices | None | Not at all |

Each inventory group pins `ansible_python_interpreter` explicitly rather than
letting Ansible discover one, so a distribution changing its default Python does
not silently change which interpreter the playbooks run under.

### Getting the OS onto the hardware — manual

**There is no OS provisioning automation.** No PXE or network boot, no
autoinstall or preseed file, no cloud-init, no golden image. Every machine was
installed by hand from installation media, and the IP KVM was flashed from a
prebuilt appliance image.

That manual step establishes everything the playbooks then take as given:

- Disk partitioning, the LUKS encryption of the root volume, and the LVM volume
  group that scratch and NFS storage are later carved out of.
- The network interface and its address on the LAN.
- The initial `ansible` user, its group membership, and its authorized key —
  without which the first playbook cannot connect at all.

Automation begins **after** a machine is booted, on the network, and reachable
over SSH as that user. Everything from that point is codified and idempotent, so
the un-automated surface is bounded to the install itself — but it is a real
gap, with two consequences:

- **Rebuilding a node is not reproducible from this repository.** Recovering
  from a lost or replaced machine means repeating the manual install from
  memory or notes before any playbook is useful.
- **Hardware facts are transcribed by hand.** The interface name, MAC address,
  LAN address, and volume group name live in `inventory.yml` and playbook
  variables because nothing discovers them. If the installer produced something
  different from what is recorded, the playbooks will fail — or worse,
  configure the wrong thing — and the mismatch is only visible by comparing
  the two by eye.

This is distinct from the boot-time automation described under
[Compute nodes](#compute-nodes). Wake-on-LAN and Dropbear automate *starting and
unlocking* a machine that is already installed; neither has anything to do with
putting an operating system on it in the first place.

### Ubuntu Server — compute nodes

The nodes run Ubuntu Server 25.10 on x86_64. Everything about the node
playbooks assumes the Debian/Ubuntu shape of the world: `apt` for packages,
Netplan and `systemd-networkd` for interface configuration, `ufw` for the host
firewall, and LVM for the volume groups backing scratch and NFS storage.

Two consequences are worth naming:

- **Third-party repositories are keyed to the release codename.** Docker,
  Tailscale, Kubernetes, and ROCm are each installed from their own APT
  repository, and the repository lines are templated from
  `ansible_distribution_release`. This is what keeps the fleet on a *single*
  Ubuntu release in practice — an OS upgrade is not just an in-place
  `do-release-upgrade`, it requires confirming that every upstream publishes
  packages for the new codename first. ROCm is the tightest of these: AMD
  publishes `amdgpu-install` repositories for two Ubuntu codenames at 7.1.1,
  jammy and noble, and `infrastructure/rocm.yml` falls back to the closest one
  when the running release is not among them. The fallback installs binaries
  linked against the older release's libraries — ROCm's `lld` needs a
  `libxml2.so.2` that Ubuntu no longer ships after 25.04, which the playbook
  supplies itself (see
  [ROCm#6046](https://github.com/ROCm/ROCm/issues/6046)).
- **`become_exe` is `sudo.ws`, not `sudo`.** This is a workaround for an Ansible
  bug ([ansible#85837](https://github.com/ansible/ansible/issues/85837)) rather
  than a preference, and it applies to every privileged task on the nodes.

Packages are installed through the package manager wherever an upstream
repository exists; the handful of exceptions (a downloaded `.deb`, a release
tarball) always clean up their temporary artifacts afterward.

### Arch Linux ARM — IP KVM

The IP KVM appliance runs a PiKVM image built on Arch Linux ARM (aarch64). It is
a rolling-release distribution on a different CPU architecture from everything
else in the homelab, which is the reason it gets its own inventory group and its
own playbook tree instead of sharing the nodes' roles. Concretely, it differs in
four ways that touch nearly every task:

- **`pacman`, not `apt`** — packages come from the Arch Linux ARM repositories.
- **Read-only root filesystem** — the image mounts `/` read-only by default, so
  every playbook that writes to the appliance wraps its changes in a block that
  remounts read-write and restores read-only in an `always` handler, even on
  failure. For the same reason the group sets `ansible_remote_tmp` to a writable
  path rather than accepting the default under the user's home.
- **`nftables`, not `ufw`** — the Arch Linux ARM `ufw` package is a Python
  application coupled to a specific Python version, which breaks on a rolling
  distribution whose aarch64 mirror lags the x86 one. `nftables` is in the base
  system and has no such coupling.
- **Plain `sudo`** — the `sudo.ws` workaround used on the nodes is not packaged
  for Arch, so the IP KVM playbooks use standard `sudo`.

The rolling-release model is also a mild operational hazard: unlike the nodes,
which stay on a fixed LTS until deliberately upgraded, the appliance drifts
forward whenever it is updated. That is another argument for keeping its
dependencies on the cluster minimal.

### macOS — operator workstation

The Mac is not configured by Ansible in any general sense — there is no play
that installs its packages or manages its system state. Its tooling (`just`,
`uv`, `ansible`, `pass`, `gnupg`, `bao`, `kubectl`, `helm`) is installed by
hand, as documented in `README.md`.

What does exist is a small set of `localhost` plays that reach into the
operator's own environment where a workflow genuinely requires it: writing the
SSH client configuration and unlock key used for the Dropbear initramfs,
staging the SLURM munge key for redistribution, and installing the homelab CA
certificate into the OS trust store. That last one is the only place the
playbooks branch on the control host's OS at all — it checks
`ansible_facts.system == 'Darwin'` and installs into the macOS System keychain,
falling back to the Linux `update-ca-certificates` path otherwise, so the
repository still works from a Linux control host. The trust-store play is
opt-out (`-e install_ca_root=false`) precisely because modifying the control
host is a surprise if the playbook is run from CI or a shared machine.

Split DNS for the internal zone is likewise a local, manual step on macOS: a
resolver entry under `/etc/resolver` pointing the zone at Bind9, rather than
anything the playbooks write.

### iOS — client devices

iOS is entirely unmanaged. No playbook targets it, no configuration is pushed to
it, and it holds no homelab credentials beyond the per-app logins described
above. The one piece of state it needs is **trust in the homelab CA**, which is
installed by hand as a Configuration Profile so the wildcard certificate
fronting every service validates. That manual step is the price of running a
private CA rather than a publicly trusted one, and it recurs for every new
device and every CA rotation.
