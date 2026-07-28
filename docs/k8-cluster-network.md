# Kubernetes Cluster Networking

This document explains how the cluster's networking stack fits together: pod
networking, LoadBalancer addressing on the LAN, ingress and TLS termination,
authentication gating, and DNS resolution. It focuses on how the networking
components interact, rather than cataloging each one individually.

Almost everything described here is installed by `cluster/network.yml` and its
templates (with the identity piece coming from `cluster/authentication.yml`);
playbook paths are relative to `playbooks/nodes/`. Throughout, `<zone>` stands in
for the internal DNS zone and no real addresses are shown. The physical machines
this runs on are described in [architecture.md](architecture.md).

## The big picture

The network is built in four cooperating planes:

1. **Pod networking (CNI)** — Cilium provides pod-to-pod connectivity, service
   routing, and network policy using eBPF, replacing kube-proxy entirely.
2. **LAN exposure (LoadBalancer + L2)** — Cilium hands out LAN IPs to
   LoadBalancer services and announces them via ARP, so services are reachable
   from other devices on the network without a cloud load balancer or BGP.
3. **Ingress + TLS (Gateway API)** — A single Traefik Gateway is the front door
   for HTTP/HTTPS. It terminates TLS with a wildcard certificate and routes each
   hostname to the right backend, optionally gating it behind single sign-on.
4. **DNS** — Bind9 is the authoritative server for the internal zone;
   ExternalDNS keeps its records in sync with what's exposed; and each consumer
   (pods, nodes, LAN clients) is pointed at Bind9 through a path that actually
   works from where it sits.

A recurring constraint ties these together: **LoadBalancer IPs are announced at
L2 on the LAN but are not routable from inside the pod network overlay.** Several
design choices below exist specifically to work around that asymmetry.

---

## 1. Pod networking — Cilium (CNI)

Cilium is installed via Helm as the cluster's Container Network Interface and is
responsible for all pod networking.

- **eBPF kube-proxy replacement.** kube-proxy is deleted and Cilium handles
  ClusterIP and NodePort service routing in eBPF rather than iptables. Because
  the kube-proxy that would normally program ClusterIP routing is gone, Cilium
  agents are told the control plane's address directly (`k8sServiceHost`) so
  they can reach the API server to bootstrap before service routing exists.
- **Node-init taint.** A nodeinit DaemonSet applies a
  `node.cilium.io/agent-not-ready:NoExecute` taint every time a Cilium agent
  starts, which keeps application pods from being scheduled onto a node before
  its eBPF dataplane is fully programmed.
- **Hubble.** Cilium's observability layer (relay + UI) is enabled for network
  flow visibility. The Hubble UI is exposed through the ingress path like any
  other service (see below).
- **Cilium CLI.** Installed on every node for inspecting dataplane state and
  running connectivity tests.

Pods reach in-cluster services by ClusterIP, which Cilium's eBPF datapath
resolves on every node. This is the only service path that works from inside the
pod overlay — which is why intra-cluster traffic always targets ClusterIPs, never
LAN LoadBalancer IPs.

---

## 2. LAN exposure — LoadBalancer IPAM + L2 announcement

To make selected services reachable from the rest of the LAN, Cilium provides
its own LoadBalancer implementation (no MetalLB, no cloud provider):

- **`CiliumLoadBalancerIPPool`** reserves a CIDR block on the LAN for external
  IP assignment. Any `Service` of type LoadBalancer draws a stable IP from this
  pool. The range must not overlap with DHCP or static assignments on the
  network.
- **`CiliumL2AnnouncementPolicy`** makes Cilium answer ARP for those IPs on each
  node's primary network interface, so other LAN devices route to them directly.

This is a *single* load-balancing mechanism (there is no MetalLB and no second
implementation), but it hands out several distinct LAN IPs. Every service
reaches the LAN through exactly one of two patterns.

### Pattern A — Shared L7 ingress (behind the Traefik Gateway)

The service exposes a `ClusterIP` and attaches an `HTTPRoute` to the Traefik
Gateway. It shares one LAN IP (the gateway's) and the wildcard certificate with
every other web app. **This is the default** for anything that speaks HTTP(S).

- **Members:** the Traefik dashboard, the Hubble UI, and essentially every
  application web UI (Firefly III, Immich, Jellyfin, Open WebUI, Vaultwarden,
  Home Assistant, Zotero, and the web UIs of Gitea and Syncthing).
- **Why:** one IP, one certificate, and one place to enforce authentication for
  the whole fleet — adding a service costs only a `ClusterIP` and an `HTTPRoute`.

**SSO gating is a separate, per-route choice.** Sharing the gateway does not
imply being gated: the ForwardAuth middleware is attached route by route, so
Home Assistant and Zotero sit behind the same gateway IP and certificate as
everything else while deliberately omitting the middleware, because their
clients cannot follow a login redirect. Pattern A is about *where the traffic
enters*; [k8-cluster-authentication.md](k8-cluster-authentication.md) covers
*who is allowed through*.

### Pattern B — Dedicated LoadBalancer IP (bypassing Traefik)

The service gets its own `type: LoadBalancer` Service and its own LAN IP
straight from the Cilium pool. Needed whenever the service **cannot** live behind
an L7 HTTP proxy. Two things force this:

- **B1 — Non-HTTP wire protocol.** The Traefik Gateway only speaks HTTP/HTTPS, so
  anything on another protocol needs a raw L4 IP:
  - **Bind9** — DNS over TCP/UDP. Pinned to a fixed IP so pods, nodes, and LAN
    clients can all hardcode the same resolver address.
  - **Gitea (SSH)** — git-over-SSH for pushing and pulling repositories.
  - **Syncthing (sync)** — the peer block-exchange (TCP+UDP) and discovery (UDP)
    protocol. Sets `externalTrafficPolicy: Local` to preserve the client source
    IP that the sync protocol relies on.
- **B2 — HTTP that can't traverse the SSO front door.** The service speaks HTTP,
  but its clients can't follow the ForwardAuth login redirect, so gating it at
  the gateway would break them:
  - **vLLM** — an OpenAI-compatible inference API authenticated by bearer token.
    Its API clients get a direct IP and authenticate against the backend
    themselves.

### The split-service pattern

**Gitea** and **Syncthing** use *both* patterns at once: their browser UI is
Pattern A (a `ClusterIP` behind Traefik, SSO-gated), while their non-HTTP
protocol port is Pattern B1 (its own LoadBalancer IP). One app, two front doors —
the UI through the shared gateway, the protocol port direct.

### DNS for the two patterns

The distinction carries into DNS (section 4). Pattern A hostnames resolve to the
**gateway's** LAN IP. Each Pattern B service instead carries an
`external-dns.alpha.kubernetes.io/hostname` annotation, so ExternalDNS publishes
an A record pointing straight at **that service's own** LoadBalancer IP.

### Quick reference

| Service | Pattern | Exposure | Reason |
|---------|---------|----------|--------|
| Application & platform web UIs | A | Shared gateway IP | Speaks HTTP(S) |
| Traefik Gateway | — | Own LB IP | *Is* the shared gateway |
| Bind9 | B1 | Own LB IP | DNS (non-HTTP) |
| Gitea — web UI | A | Shared gateway IP | Speaks HTTP(S) |
| Gitea — SSH | B1 | Own LB IP | git-over-SSH (non-HTTP) |
| Syncthing — web UI | A | Shared gateway IP | Speaks HTTP(S) |
| Syncthing — sync/discovery | B1 | Own LB IP | Peer sync protocol (non-HTTP) |
| vLLM API | B2 | Own LB IP | HTTP bearer-token API, can't follow SSO redirect |

Note the asymmetry between the two SSO-incapable HTTP cases: vLLM gets its own
LAN IP (B2) because it is *only* an API, whereas Home Assistant and Zotero keep
the shared gateway (A) and simply drop the middleware, because they also serve a
browser UI that benefits from the shared certificate.

---

## 3. Ingress + TLS — Gateway API, Traefik, cert-manager

### Traefik as the Gateway controller

Traefik is installed as the Gateway API controller (it owns the `traefik`
GatewayClass). A single `Gateway` resource, `traefik-gateway`, lives in
`kube-system` and provisions the LoadBalancer service that receives the ingress
LAN IP. It defines two listeners, both scoped to `*.<zone>` and open to
HTTPRoutes from any namespace:

| Listener | Internal port | External port | Role |
|----------|--------------|--------------|------|
| `http`   | 8000 | 80  | Accepts plain HTTP, immediately redirected to HTTPS by the Traefik entrypoint redirect. |
| `https`  | 8443 | 443 | Terminates TLS with the wildcard certificate, then routes to backends. |

### Routing with HTTPRoutes

Each exposed service attaches an `HTTPRoute` to the Gateway's `https` listener.
A route matches a hostname (and optionally a path prefix, enabling
longest-prefix matching so different prefixes on the same host can carry
different filters) and forwards to a backend Service. When a route's backend
lives in a different namespace than the route, a `ReferenceGrant` is emitted in
the backend namespace to permit the cross-namespace reference. Because every
service reuses this one Gateway and the shared wildcard certificate, exposing a
new app requires no new listener, IP, or per-service certificate.

### TLS trust chain (cert-manager)

cert-manager issues certificates through a deliberately two-tier chain so the
wildcard cert carries a real issuer and can be installed as a trust anchor in OS
keychains and mobile profiles:

```
selfsigned-issuer (ClusterIssuer, selfSigned)
   └─ signs → homelab-ca (Certificate, isCA:true)
                └─ backs → homelab-ca-issuer (ClusterIssuer, CA type)
                             └─ signs → wildcard-tls (*.<zone>)
```

The `wildcard-tls` secret is referenced by the Gateway's HTTPS listener, so
every service exposed via an HTTPRoute gets TLS automatically with no per-route
annotations. The root CA certificate (the `ca.crt` field of that same secret) is
installed once into operator devices' OS trust stores — `cluster/network.yml`
does this automatically for the machine running the playbook (macOS keychain or
Linux `update-ca-certificates`) — after which every `*.<zone>` hostname is
trusted without warnings.

### Authentication gating (ForwardAuth → Authentik)

Routes that should require login apply a Traefik `authentik-forward-auth`
Middleware via an `ExtensionRef` filter. For each request, Traefik calls out to
Authentik's embedded outpost:

- **Not authenticated** → Authentik redirects the browser to its login page.
- **Authenticated** → the request proceeds, and Authentik returns identity
  headers (username, groups, email, name, uid) that Traefik forwards to the
  backend.

This is the SSO layer for cluster web UIs. Some clients that cannot follow SSO
redirects (native/mobile apps, bearer-token APIs, WebDAV basic-auth) deliberately
skip the middleware and authenticate against the backend directly. The
middleware only becomes functional once `cluster/authentication.yml` has
deployed Authentik; the middleware object itself can exist before then.

### Putting a request together

An external browser hitting `app.<zone>` over HTTPS follows this path:

```
Browser
  → DNS: app.<zone> resolves to the ingress LoadBalancer IP  (see section 4)
  → ARP: Cilium L2 announces that IP on the LAN
  → Traefik Gateway (https listener :8443, external :443)
      → terminates TLS with wildcard-tls
      → matches the HTTPRoute for app.<zone>
      → [optional] ForwardAuth check against Authentik
  → backend Service (ClusterIP, routed by Cilium eBPF)
  → application pod
```

---

## 4. DNS

Internal name resolution is served by **Bind9**, the authoritative server for
`<zone>`, running in-cluster on a pinned LoadBalancer IP. It stores zone data on
a small PersistentVolume and accepts authenticated dynamic updates (RFC 2136,
via a TSIG key that is generated once and reused).

Records get into Bind9 two ways:

- **ExternalDNS** watches Gateway API HTTPRoute resources and automatically
  creates/updates A records for their hostnames using RFC 2136 with the shared
  TSIG key. It only touches records it owns (tracked via a TXT registry marker),
  so it leaves manually-managed records alone.
- **Static records** are written directly with `nsupdate` — notably the
  Kubernetes API hostname's A record, since the API server is not exposed
  through an HTTPRoute.

Because a LoadBalancer IP is reachable on the LAN but not from inside the pod
overlay, each class of consumer is pointed at Bind9 through a path that works
from where it runs:

| Consumer | How it resolves `<zone>` | Why |
|----------|--------------------------|-----|
| **Pods** | CoreDNS is patched with a forward block sending `<zone>` queries to **Bind9's ClusterIP** (reachable via Cilium eBPF). A `hosts` override maps the identity provider's hostname to **Traefik's ClusterIP**. | LoadBalancer IPs aren't routable from the pod overlay, so pods must use ClusterIPs. The default zone forwards to explicit upstream DNS IPs (not the node stub resolver, which pods can't reach). |
| **Nodes** | `systemd-resolved` gets a split-DNS drop-in routing only `~<zone>` queries to **Bind9's LoadBalancer IP**; all other queries stay on the node's existing upstreams. | Routing-domain syntax means a Bind9 outage only affects the internal zone and never strands the node's general DNS. |
| **IP KVM** | The same `systemd-resolved` split-DNS drop-in as the nodes, routing only `~<zone>` to **Bind9's LoadBalancer IP**. | The KVM is the tool used to recover the cluster, so it must never depend on the cluster for general resolution. |
| **LAN clients** (workstation, phones, etc.) | Point their resolver at **Bind9's LoadBalancer IP** for the zone. | Same L2-reachable IP the nodes use; set up per-device (see [architecture.md](architecture.md)). |

### Kubernetes API addressing

The API server is given a stable name in the zone: an A record for the API
hostname points at the control plane IP, and the local kubeconfig is rewritten
to address the API by that hostname (matching the SAN on the API server's
serving certificate). This keeps `kubectl` working by name rather than by a
hardcoded IP.

---

## Component-to-role summary

| Component | Plane | Role |
|-----------|-------|------|
| **Cilium** | Pod networking | eBPF CNI, kube-proxy replacement, network policy |
| **Hubble** | Pod networking | Flow observability + UI |
| **CiliumLoadBalancerIPPool** | LAN exposure | Reserves the LAN CIDR for LoadBalancer IPs |
| **CiliumL2AnnouncementPolicy** | LAN exposure | ARP-announces those IPs on the LAN |
| **Traefik + Gateway API** | Ingress | Single HTTP/HTTPS front door, TLS termination, routing |
| **cert-manager** | TLS | Two-tier CA issuing the wildcard cert used by the Gateway |
| **Authentik + ForwardAuth Middleware** | AuthN | SSO gating for web UIs at the ingress edge |
| **Bind9** | DNS | Authoritative server for the internal zone (RFC 2136) |
| **ExternalDNS** | DNS | Syncs HTTPRoute hostnames into Bind9 |
| **CoreDNS** | DNS | In-cluster resolver; forwards the zone to Bind9's ClusterIP |
| **systemd-resolved** | DNS | Node-level split-DNS to Bind9's LoadBalancer IP |
