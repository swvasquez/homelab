# Operations

The things you need to know to run this homelab that aren't derivable from any
single tool's documentation: what order playbooks must run in, the one-time
manual steps that no playbook can do for you, and the recurring procedures.

This document covers *operating* the homelab. What each component **is** belongs
to [k8-cluster-components.md](k8-cluster-components.md); how variables are
**configured** belongs to [configuration.md](configuration.md). Playbook paths
are relative to `playbooks/nodes/` unless otherwise noted, `<zone>` stands in for
the internal DNS zone, and no real addresses appear below.

## Run order

Most playbooks are independent and idempotent. These are the cases where order
genuinely matters — running them out of sequence fails, or worse, half-succeeds.

A fresh cluster needs `ssh`, `network`, and `docker` from `infrastructure/`
installed on the nodes first (plus `nfs` if any service uses NFS-backed storage).
The cluster playbooks then run in this order, each via
`just deploy nodes cluster <playbook>`:

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
12. `agent`

Two dependencies inside that sequence are worth calling out, because the failure
they produce doesn't point back at the ordering:

- **`security` after `authentication`.** The security playbook patches the
  running kube-apiserver; doing it before Authentik exists leaves services
  briefly unable to authenticate.
- **`observability` before `security`.** Falcosidekick forwards alerts to
  Alertmanager, which `observability.yml` provides. Deploy Falco first and it has
  nowhere to send anything.

`agent` is listed last but depends on nothing beyond a reachable apiserver, so
it can run at any point after `bootstrap`. It creates a ServiceAccount and
ClusterRole and writes no credential; `just agent-kube-config` mints the token
the sandbox authenticates with.

### Service playbooks are self-contained

Once every cluster playbook has run, services under `service/` can be deployed in
any order, one at a time:

```bash
just deploy nodes service <SERVICE>
```

Each service playbook applies its own HTTPRoute, Traefik ForwardAuth Middleware,
and namespace hardening, so **adding a service never requires re-running a
cluster playbook**. This is deliberate: the alternative — a central list of
services that `network.yml` or `security.yml` iterates — would mean every new
service triggers a re-run of a playbook that touches the whole cluster.

The one exception is a genuine data dependency: **vLLM before Open WebUI**, since
Open WebUI reads the vLLM API key out of the `vllm-credentials` Secret and has no
model backend without it.

### Tailscale: shared ACL before per-host

`playbooks/shared/infrastructure/tailscale.yml` owns the tailnet ACL — tag
owners, the exit-node auto-approver, and the subnet-route auto-approver — and
must run **before** the per-host playbooks that assign those tags.

```bash
just deploy shared infrastructure tailscale
just deploy nodes infrastructure tailscale
just deploy ipkvm infrastructure tailscale
```

Out of order, the tags the per-host playbooks assign via the API aren't
recognized and advertised subnet routes sit pending in the admin console. This
is recoverable rather than fatal: pushing the shared playbook afterward
re-evaluates and approves them.

## One-time operator setup

These are the steps that live outside Ansible entirely, because they configure
the operator's own machine or depend on secrets that must exist before any
playbook runs.

### Initialize the pass store

Every cluster-level master key lives in the operator's `pass` store
(`~/.password-store/`), namespaced under `pass_namespace` so homelab entries
can't collide with anything else. **The store must be initialized before the
cluster playbooks run:**

```bash
pass init <PASS_GPG_KEY_ID>
```

Two playbooks populate it:

| Playbook | Writes |
|----------|--------|
| `cluster/bootstrap.yml` | `<pass_namespace>/kubernetes/etcd-encryption-key` |
| `cluster/secrets.yml` | `<pass_namespace>/openbao/unseal-key-1..5` and `<pass_namespace>/openbao/root-token` |

The practical consequence: **a backup of `~/.password-store/` covers the
cluster's entire master-key set.** Nothing else needs separate backup to recover
the cluster's secrets, and losing it means losing the ability to unseal OpenBao
or decrypt etcd.

### Trust the homelab CA

`cluster/network.yml` creates a private root CA that signs the wildcard
certificate every `*.<zone>` service uses. Until a device trusts that CA, every
service throws certificate warnings.

The playbook installs it automatically **on the machine running the playbook** —
a `localhost` play extracts the cert from the cluster's `wildcard-tls` Secret,
caches it under `~/.local/state/homelab/homelab-ca.crt`, and adds it to the macOS
System keychain or the Linux `update-ca-certificates` store.

Every *other* device needs it by hand. Extract the cert:

```bash
kubectl -n kube-system get secret wildcard-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > homelab-ca.crt
```

Then add it to that device's trust store. On iOS, install it as a Configuration
Profile via AirDrop or email, then enable it under Settings → General → About →
Certificate Trust Settings — the second step is separate and easy to miss, and
without it the profile is installed but inert.

Worth understanding before you install it anywhere: this CA is **unconstrained**,
so any device trusting it will accept a certificate it signs for *any* domain,
not just `<zone>`. That is a meaningful amount of trust to grant a key living in
a homelab cluster, and it can be narrowed with a `nameConstraints` extension
limiting the CA to the internal zone.

### Point the resolver at Bind9

Cluster nodes and the IP KVM are configured automatically. Other client machines
need their resolver pointed at Bind9's LoadBalancer IP for the internal zone —
split-DNS, so only `<zone>` queries go to Bind9 and a Bind9 outage can't strand
the device's general name resolution.

macOS:

```bash
sudo mkdir -p /etc/resolver && echo "nameserver <BIND9_LB_IP>" | sudo tee /etc/resolver/<zone>
```

Linux (`systemd-resolved`):

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d && printf '[Resolve]\nDNS=<BIND9_LB_IP>\nDomains=~<zone>\n' | sudo tee /etc/systemd/resolved.conf.d/<zone>.conf
```

Then restart `systemd-resolved`.

## Recurring procedures

### Unseal OpenBao after a reboot

**OpenBao comes up sealed after every cluster reboot.** Re-running the secrets
playbook unseals it, reading the unseal keys from the pass store:

```bash
just deploy nodes cluster secrets
```

The playbook only touches the pass store when OpenBao is actually sealed (or when
`openbao_force_reconfigure=true` is passed), so on a healthy cluster it is a fast
no-op and safe to re-run.

For ad-hoc CLI work:

```bash
just bao-shell
```

That opens a subshell with `BAO_ADDR`, `BAO_SKIP_VERIFY`, and `BAO_TOKEN`
preset. `just bao-token` prints the root token on its own, for the UI's Token
auth method. Local tooling required: `bao`, `kubectl`, `helm`, `jq`, and `curl`,
with the host resolver pointed at Bind9.

### Flush the local DNS cache

When a service is unreachable or resolves to a stale address after a cluster
change — a new service, a changed LoadBalancer IP, a redeployed Bind9:

```bash
just flush-dns
```

### Upgrade the Tailscale clients

Routine Tailscale runs never change the installed version — `tailscale_upgrade`
is `false` in `group_vars/all.yml`, so both playbooks install the client if it is
missing and otherwise leave it alone. Upgrade deliberately, from home, with both
groups in one sitting:

```bash
just deploy ipkvm infrastructure tailscale -e tailscale_upgrade=true
just deploy nodes infrastructure tailscale -e tailscale_upgrade=true
```

Neither source can be pinned to a chosen version. The IP KVM installs from Arch
Linux ARM, which carries only the current version of a package and has no
official archive, so it cannot be told to install a named version; the nodes
install from Tailscale's APT repository, which accepts a named version but prunes
old `.deb`s. A single `tailscale_version` pin is therefore unusable across the
two groups, and upgrading in step stands in for one.

That does not produce identical versions. Arch Linux ARM packages Tailscale well
behind Tailscale's own APT repository, so the IP KVM normally trails the nodes by
a stable release or two even immediately after both playbooks run. Upgrading
together bounds the gap rather than closing it; `tailscale_min_version` below is
what actually guarantees no host sits on a version you have not accepted.

Upgrading is gated rather than automatic because the IP KVM is the only exit node
that is always powered on — the two cluster-node exit nodes are shut down on a
schedule and woken by WoL — so a regression on it costs remote access while away.
That is not hypothetical: Tailscale 1.92.3 shipped a routing regression, and
upstream pulled 1.86.0 across every platform for the same reason. Tailscale's own
auto-updater soaks a release for roughly a week before rolling it out; a playbook
run offers no soak at all, which is why the freshest release is the wrong default
for this host.

Both playbooks assert the installed client is at or above `tailscale_min_version`
before joining the tailnet. That floor is a security bound, not a freshness
check: Tailscale publishes no support window or minimum version, and old clients
keep working against the coordination server indefinitely, so the only floors
that ever bind are the retroactive ones an advisory creates. Raise the value in
`group_vars/all.yml` when an advisory raises the bar. A failure on a host you
have not upgraded in a long while is the assert doing its job — re-run that group
with `tailscale_upgrade=true`.

### Rotate the etcd encryption key

`cluster/bootstrap.yml` encrypts all Kubernetes Secret resources at rest with
AES-CBC. The key is generated on the Ansible host on first install and stored in
the pass store; it never goes to git.

To rotate, edit `/etc/kubernetes/encryption/encryption-config.yaml` on the
control plane by hand, adding the new key as the **first** entry under `keys:`
and leaving the old one second — the first key encrypts, and every key in the
list can decrypt, so removing the old one before everything is re-encrypted makes
existing Secrets unreadable. Update the pass entry to match
(`pass edit kubernetes/etcd-encryption-key`), then re-run `bootstrap.yml`, which
re-encrypts every existing Secret with a `kubectl get secrets -A -o json |
kubectl replace -f -` pass.

**Recovering a lost config file is not a rotation.** If the control-plane file is
deleted, re-running `bootstrap.yml` reads the existing key back out of the pass
store and rewrites the file — no ciphertext changes and no re-encryption needed.

### Trigger a Falco test detection

To confirm Falco is watching syscalls and its alerts reach Alertmanager:

```bash
kubectl -n default run falco-test --image=alpine --restart=Never --rm -it -- sh
```

Opening a shell in a container matches a default rule and should produce an
alert within seconds.

## Adding a new service

Two cluster-wide concerns are worth knowing about before deploying something new,
because both are designed so that you *don't* have to touch cluster playbooks.

**Pod Security Admission.** The cluster default is `restricted`, applied at the
apiserver so every namespace is protected the moment it exists. Only genuine
infrastructure namespaces are exempted at the apiserver level. A service that
needs more privilege opts down by applying a
`pod-security.kubernetes.io/enforce` label to **its own** namespace from its own
playbook — `vllm` does this for hostPath GPU access. Adding a service therefore
never means editing `cluster/security.yml`.

**Firewall rules for host ports.** A service that listens on a host port and must
be reachable *from inside the cluster* needs two UFW rules, not one: the LAN rule
plus a rule admitting the pod CIDR. Cilium's masquerading is asymmetric for
pod-to-host traffic, so a pod arrives with a pod source address that the
LAN-scoped rule doesn't match. The symptom of forgetting the second rule is a
target that works from the LAN and times out from inside the cluster. See
[configuration.md](configuration.md) for which ports currently carry both.

## Tearing down the cluster

To reset a node's Kubernetes state so the cluster can be rebuilt from the run
order above, run on **each** node:

```bash
kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock
```

The `--cri-socket` flag names the runtime explicitly rather than letting kubeadm
probe for one. Probing picks the first socket it finds from a built-in list, and
a node that still has a stale socket file from a previous runtime can be matched
to a runtime that is not running the containers, which then survive the reset.
