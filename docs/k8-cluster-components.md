# Kubernetes Cluster Components

This document catalogs every service, tool, operator, and component installed on
the Kubernetes cluster by the Ansible playbooks under `playbooks/nodes/`.

Rather than list components by playbook, this catalog is organized as a **layered
platform stack**. Each layer depends on the ones beneath it and provides a
foundation for the ones above, so the document reads bottom-up — from turning
bare hosts into cluster members, up to the end-user applications. This ordering
also roughly matches the order in which the playbooks are run.

The hardware and operating systems underneath Layer 0 are described in
[architecture.md](architecture.md). Playbook paths below are relative to
`playbooks/nodes/`.

## Overview

| Layer | Purpose | Components |
|-------|---------|-----------|
| **0 — Node foundation** | Turn bare hosts into cluster members | kubelet, kubeadm, kubectl, containerd, Docker Engine, crictl, Helm, k9s, chrony |
| **1 — Cluster core** | Make the cluster schedulable and safe by default | Metrics Server, Pod Security Admission |
| **2 — Infrastructure** | Networking, storage, and the ingress front door | Cilium, Hubble, Cilium CLI, Gateway API CRDs, Traefik, cert-manager, Bind9, ExternalDNS, Longhorn, open-iscsi, nfs-common |
| **3 — Platform services** | Shared backends that applications consume | CloudNativePG, OpenBao, External Secrets Operator, Stakater Reloader, Authentik, Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics |
| **4 — Delivery & governance** | How workloads are deployed and kept honest | Gitea, Argo CD, Kyverno, Falco, Falcosidekick |
| **5 — Applications** | End-user workloads | Firefly III, Home Assistant, Immich, Jellyfin, Open WebUI, Syncthing, Thread/Matter stack, Vaultwarden, vLLM, Zotero |

---

## Layer 0 — Node Foundation

The base tooling that turns each bare host into a Kubernetes cluster member: the
node agent, the container runtime, and the CLIs used to build and operate the
cluster. Installed by
`cluster/kubernetes.yml`, except containerd and Docker Engine, which come from
`infrastructure/docker.yml`.

### kubelet
The primary Kubernetes node agent, installed as a system package on every node.
It registers the node with the control plane and manages the lifecycle of pods
and their containers, reporting status back to the API server.

### kubeadm
The command-line tool for bootstrapping and administering a Kubernetes cluster.
It initializes the control plane, joins additional nodes, and manages cluster
certificates and join tokens.

### kubectl
The standard Kubernetes command-line client for interacting with the cluster
API. It is used for inspecting, creating, and managing all cluster resources.

### containerd
The container runtime that actually runs every container on the node. It pulls
and stores images, unpacks their layers, and supervises container processes
through runc. It arrives as a dependency of the `containerd.io` package but is
not Docker's private component: Docker and Kubernetes both run their containers
through this one daemon, kept apart by containerd namespaces — Docker works in
`moby`, Kubernetes in `k8s.io`. Because containerd's garbage collection only
considers references within a single namespace, `docker system prune` cannot
reach cluster images. Placing an image where the kubelet can see it therefore
means targeting that namespace explicitly, with `ctr -n k8s.io`.

The kubelet reaches it through containerd's CRI plugin. The `containerd.io`
package ships `/etc/containerd/config.toml` containing
`disabled_plugins = ["cri"]`, which `cluster/kubernetes.yml` replaces with a
config that leaves the plugin enabled and sets `SystemdCgroup = true` to match
the kubelet's `--cgroup-driver=systemd`.

A containerd restart does not stop running containers. Each is held by its own
`containerd-shim-runc-v2` process, which is not a child of the daemon and
re-attaches when it returns.

### Docker Engine
The container platform comprising the `dockerd` daemon, the `docker` CLI, and
the Buildx and Compose plugins. Kubernetes does not use it — the kubelet
connects to containerd directly — and it is kept on the nodes for direct use
and for building images. Its image store is containerd-backed (`docker info`
reports the `overlayfs` driver), so a `docker build` writes into containerd's
`moby` namespace. Moving an image to where the kubelet reads it is
`docker save … | ctr -n k8s.io images import -`, which is how the locally built
OTBR image reaches the cluster. It runs with `live-restore` enabled, so
upgrading the Docker package does not stop its running containers.

### crictl
The CRI client, from the `cri-tools` package. It lists and inspects what the
kubelet is running — `crictl ps`, `crictl images`, `crictl logs` — against the
same socket the kubelet uses. `docker ps` does not substitute for it: Docker
sees only the `moby` namespace, so it shows none of the cluster's containers.
`/etc/crictl.yaml` names the endpoint so crictl does not fall back to probing.

### Helm
The package manager for Kubernetes, installed as a system package. It is used to
install and upgrade the charts that make up most of the cluster's platform and
application components.

### k9s
A terminal-based UI for interacting with Kubernetes clusters. It provides
real-time visibility into cluster resources and simplifies navigating,
inspecting, and managing workloads directly from the terminal.

### chrony
An NTP time-synchronization daemon that keeps node clocks aligned. Consistent
time across nodes prevents certificate-validation failures and leader-election
problems in the distributed control plane.

---

## Layer 1 — Cluster Core

Cluster-wide capabilities that make the cluster schedulable and safe by default,
established right after the control plane is bootstrapped. Installed by
`cluster/bootstrap.yml` and `cluster/security.yml`.

### Metrics Server
A cluster add-on that scrapes CPU and memory metrics from each node's kubelet
and exposes them through the Kubernetes Resource Metrics API. It backs the
`kubectl top` command and provides the data source for the Horizontal Pod
Autoscaler.

### Pod Security Admission
The built-in Kubernetes admission controller for pod security standards,
configured cluster-wide with a fail-closed `restricted` default. It rejects pods
that request excessive privileges unless their namespace opts down — either
through an explicit exemption in the admission configuration (reserved for
infrastructure namespaces) or through a per-namespace
`pod-security.kubernetes.io/enforce` label.

---

## Layer 2 — Infrastructure

The networking, storage, and ingress plumbing that every workload relies on:
pod networking, the ingress front door, TLS, internal DNS, and persistent
volumes. Installed by `cluster/network.yml` and `cluster/storage.yml`.

### Cilium
An eBPF-based Container Network Interface (CNI) plugin that provides the
cluster's pod networking. It also delivers network policy enforcement, a
kube-proxy replacement, LoadBalancer IP address management with L2 announcement,
and Gateway API support. The standard kube-proxy component is removed in favor
of Cilium's eBPF implementation.

### Hubble
The network observability layer bundled with Cilium. It provides visibility into
service-to-service traffic flows and a web UI for exploring the eBPF dataplane.

### Cilium CLI
A command-line tool installed on the nodes for inspecting and troubleshooting
the Cilium installation. It reports connectivity status and helps diagnose
networking issues.

### Gateway API CRDs
The upstream Kubernetes Gateway API custom resource definitions (GatewayClass,
Gateway, HTTPRoute, and related types). They are a prerequisite that the CNI and
ingress controller build on to route external traffic into the cluster.

### Traefik
A cloud-native L7 reverse proxy and ingress controller that acts as the cluster's
Gateway API controller. It terminates TLS and routes external HTTP/HTTPS traffic
to in-cluster services, and provides the ForwardAuth integration used to gate
services behind single sign-on.

### cert-manager
A Kubernetes controller that automates the issuance and renewal of X.509 TLS
certificates. It is configured with an internal certificate authority that signs
a wildcard certificate used across cluster services.

### Bind9
An authoritative DNS server for the internal cluster zone, deployed via native
manifests. It supports authenticated dynamic updates so that DNS records can be
managed automatically as services come and go.

### ExternalDNS
A controller that watches Gateway API route resources and automatically
synchronizes matching DNS records into the internal DNS server. It keeps
hostname records for cluster services up to date without manual editing.

### Longhorn
A distributed block-storage system for Kubernetes that provides replicated
persistent volumes as the cluster's default StorageClass. Volumes are backed by
node disks and replicated across nodes for resilience, and it ships with its own
management UI.

### open-iscsi
The iSCSI initiator package installed on each node as a Longhorn dependency. It
provides the iSCSI client machinery Longhorn uses to attach block volumes to
pods.

### nfs-common
The NFS client support package installed on each node. It provides the NFS
mounting capability used both by Longhorn's backup and shared-volume features
and by the host-level NFS share that backs the cluster's ReadWriteMany
PersistentVolumes.

---

## Layer 3 — Platform Services

Shared backends that applications consume rather than run themselves: managed
databases, the secrets pipeline, identity, and the metrics stack. Installed by
`cluster/database.yml`, `cluster/secrets.yml`, `cluster/authentication.yml`, and
`cluster/observability.yml`.

### CloudNativePG
A Kubernetes operator that manages the full lifecycle of PostgreSQL clusters as
first-class custom resources, including provisioning, failover, and scheduled
backups. Other services consume it to obtain a managed PostgreSQL database
rather than bundling their own Postgres subchart.

### OpenBao
An open-source secrets manager (a fork of HashiCorp Vault) run as a StatefulSet.
It provides a KV secrets engine, a Kubernetes authentication method, and
policy-based access control for storing and serving credentials to workloads.

### External Secrets Operator
A controller that reads secrets from an external store and materializes them as
native Kubernetes Secrets in application namespaces. It connects to OpenBao so
that applications consume standard Secret objects without embedding secret
material in Git.

### Stakater Reloader
A controller that watches referenced ConfigMaps and Secrets and automatically
triggers rolling restarts of annotated workloads when those objects change. It
completes the secret-rotation pipeline by ensuring pods pick up updated values.

### Authentik
An open-source identity provider that supplies single sign-on with OAuth2/OIDC,
SAML, and LDAP. It serves as the central authentication backend for cluster
services and powers the reverse proxy's ForwardAuth access gating. It uses a
CloudNativePG database and a bundled Redis cache for sessions.

### Prometheus
A time-series metrics collection, storage, and query engine, installed as part
of the kube-prometheus-stack. It scrapes metrics from cluster components and
workloads and evaluates recording and alerting rules against them.

### Alertmanager
The alert-routing companion to Prometheus. It deduplicates, groups, and routes
firing alerts to notification destinations.

### Grafana
A visualization and dashboarding platform. It renders metrics from Prometheus
into dashboards and auto-provisions dashboards defined in labeled ConfigMaps.

### node-exporter
A per-node exporter that publishes host-level hardware and operating-system
metrics such as CPU, memory, disk, and network statistics for Prometheus to
scrape.

### kube-state-metrics
A service that generates metrics about the state of Kubernetes API objects such
as deployments, pods, and nodes. It gives Prometheus visibility into the health
and counts of cluster objects.

---

## Layer 4 — Delivery & Governance

How workloads get into the cluster and are kept honest: source hosting, GitOps
delivery, admission policy, and runtime threat detection. Installed by
`cluster/git.yml`, `cluster/gitops.yml`, and `cluster/security.yml`.

### Gitea
A self-hosted Git service providing repository hosting, issue tracking, and a
built-in CI/CD system. It includes a dedicated SSH server for Git operations and
uses the CloudNativePG operator for its PostgreSQL database.

### Argo CD
A declarative GitOps continuous-delivery controller. It continuously
synchronizes the live cluster state to manifests stored in a Git repository, and
is the mechanism by which the end-user services are deployed and kept in sync.

### Kyverno
A Kubernetes-native admission policy engine that enforces workload-hygiene
policies. Cluster policies here disallow mutable image tags, disallow
NodePort/ExternalName services, and prevent ServiceAccount token overrides.

### Falco
A runtime-security tool deployed as a DaemonSet. It watches kernel system calls
through an eBPF driver and evaluates them against rulesets to detect suspicious
or anomalous behavior at runtime.

### Falcosidekick
A companion component deployed alongside Falco that fans out and forwards Falco
alerts to external sinks. It provides a web UI and routes security events into
the cluster's alerting pipeline.

---

## Layer 5 — Applications

The end-user workloads deployed onto the cluster through GitOps by the service
playbooks under `service/`. Most web UIs are gated behind single sign-on via the
reverse proxy's ForwardAuth integration, except where an application's clients
cannot follow SSO redirects — see
[k8-cluster-authentication.md](k8-cluster-authentication.md) for which services
are exceptions and why.

### Firefly III
Deployed by `service/firefly.yml`. A self-hosted personal finance manager that
lets users track income, expenses, budgets, bills, and accounts through a web
UI. It runs scheduled cron tasks for recurring bookkeeping and stores its data
in a CloudNativePG-provisioned PostgreSQL database.

### Home Assistant
Deployed by `service/home-assistant.yml`. An open-source home-automation
platform that integrates and controls smart-home devices, sensors, and services
from a single dashboard. It supports mobile companion apps via long-lived tokens
and communicates with a separate Thread border router and Matter server to reach
smart-home devices.

### Immich
Deployed by `service/immich.yml`. A self-hosted photo and video management
solution and Google Photos alternative, offering upload, timeline browsing,
albums, and mobile backup with OIDC single sign-on. It ships with a companion
machine-learning service for facial recognition and smart search, a PostgreSQL
database with the pgvector extension for similarity search, and a
Redis-compatible Valkey store for caching and job queues.

### Jellyfin
Deployed by `service/jellyfin.yml`. A free, self-hosted media server for
organizing and streaming personal movies, TV, music, and other media to client
apps and browsers. It supports per-user library permissions.

### Open WebUI
Deployed by `service/openwebui.yml`. A web-based chat interface for interacting
with large language models. It connects to an OpenAI-compatible inference
backend rather than running its own model, with its bundled local-model
components disabled.

### Syncthing
Deployed by `service/syncthing.yml`. A continuous, peer-to-peer file
synchronization application that keeps folders in sync across multiple devices
without a central cloud service. It exposes a web management UI alongside a
dedicated port for peer sync traffic.

### Thread / Matter Stack
Deployed by `service/thread.yml`. A stack that lets the home-automation platform
reach low-power mesh smart-home devices. It comprises an **OpenThread Border
Router** that bridges a Thread (IPv6 low-power mesh) network to the LAN by
driving a USB Thread radio, a **Matter server** that commissions and controls
Matter-over-Thread devices over a websocket API, and a **generic-device-plugin**
DaemonSet that advertises the USB radio and TUN device to the kubelet so the
border router can access the hardware with least-privilege capabilities instead
of a privileged container.

### Vaultwarden
Deployed by `service/vaultwarden.yml`. A lightweight, self-hosted,
Bitwarden-compatible password and secrets manager that works with the official
Bitwarden client apps and browser extensions. It supports OIDC single sign-on
for the web vault, backs its data with a CloudNativePG PostgreSQL database, and
uses a small scheduled job to keep its OIDC client credentials aligned with the
identity provider.

### vLLM
Deployed by `service/vllm.yml`. A high-throughput inference server for large
language models that exposes an OpenAI-compatible API. It serves model
completions and chat to API clients (including Open WebUI), authenticates callers
with a bearer token, and runs on GPU-capable nodes.

### Zotero WebDAV Server
Deployed by `service/zotero.yml`. A self-hosted WebDAV endpoint that Zotero
desktop and mobile clients use to sync file attachments such as PDFs and web
snapshots, while library metadata continues to sync through Zotero's own cloud
service. It is served by an Apache HTTP Server acting as the WebDAV frontend and
enforcing HTTP Basic authentication.
