# Homelab

This repository contains code to deploy and manage a homelab cluster consisting of compute nodes, client nodes, and an IP KVM.

As part of this homelab, a self-managed Kubernetes cluster hosts various services such as those for file syncing, Git repository hosting, media serving, and home automation. Client nodes can access these services from within the LAN or remotely via Tailscale.

Code is deployed to the cluster via Ansible Playbooks. Common management tasks are accessible via the project's `justfile`.

> [!NOTE]
> This code was generated with AI assistance.

## Prerequisites

The following tools should be installed before deploying any of the Playbooks

| Tool | Purpose |
|------|---------|
| [just](https://github.com/casey/just) | Task runner that wraps the deploy, lint, and helper commands |
| [uv](https://github.com/astral-sh/uv) | Python environment manager; `just venv` uses it to install Ansible |
| [bao](https://openbao.org/) | OpenBao CLI for secret management within the cluster |
| [gnupg](https://gnupg.org/) | GPG, which encrypts the `pass` store |
| [pass](https://www.passwordstore.org/) | Password store that holds various keys to access and manage cluster resources |

## Setup

1.  Create a virtual environment with required dependencies (namely Ansible)

    ```sh
    just venv
    ```

2.  Define cluster configuration via a top-level `inventory.yml` file and `group_vars/{all,nodes,ipkvm}.yml` files. These configuration files provide the Playbooks with information about the local setup (router IP, desired local DNS zone, etc.) and assign roles to certain nodes. The specification for these configuration files can be found at [`docs/configuration.md`](docs/configuration.md).

3. Ensure Ubuntu Server 24.04 LTS or newer is already installed on your compute nodes.

4. Ensure you can SSH into compute nodes from the machine that will run the Ansible Playbooks.

## Deploy

Use the provided Ansible Playbooks to deploy the homelab.

Playbooks live under `playbooks/`, organized by Ansible inventory group, then by category. Each category maintains its own `templates/` folder (if applicable) to keep Playbooks and their dependencies tightly coupled. Paths below are relative to `playbooks/`.

| Directory | Contains |
|-----------|----------|
| `nodes/infrastructure` | Host configuration applied to an already-installed OS (e.g. remote access, firewall rules, shared storage) |
| `nodes/cluster` | Kubernetes cluster bootstrapping and core platform components, including the Git server (`git.yml`) and GitOps controller (`gitops.yml`) |
| `nodes/development` | Language toolchains and common CLI utilities |
| `nodes/service` | Cluster-hosted user services (e.g. Syncthing, Jellyfin, Vaultwarden) |
| `ipkvm/infrastructure` | OS-level configurations for IP KVM devices |
| `shared/infrastructure` | Tailnet- and other cross-group config that targets `localhost` rather than a specific inventory group (e.g. the Tailscale ACL) |

To run a Playbook, specify the inventory group, category, and Playbook name

```sh
just deploy <GROUP> <CATEGORY> <PLAYBOOK> [ANSIBLE_ARGS...]
```

The structure of the commands should mirror the Playbook directory layout. Any
trailing arguments are passed through to `ansible-playbook`, which is how one-off
overrides are applied.

**Examples**

```sh
just deploy nodes infrastructure docker
just deploy nodes cluster observability
just deploy shared infrastructure tailscale
just deploy ipkvm infrastructure tailscale
just deploy ipkvm infrastructure tailscale -e tailscale_upgrade=true
```

## Documentation

The Playbooks themselves contain fine-grained commentary; refer to them when trying to understand if and why specific options are set.

For a high-level overview, refer to the documentation in `docs/`

| Document | Covers |
|----------|--------|
| [`architecture.md`](docs/architecture.md) | The physical machines, what each is responsible for, and how they relate |
| [`configuration.md`](docs/configuration.md) | The schema for `inventory.yml` and `group_vars/`, and the constraints coupling them |
| [`operations.md`](docs/operations.md) | Playbook run order, one-time operator setup, and recurring procedures |
| [`k8-cluster-components.md`](docs/k8-cluster-components.md) | Every component installed on the cluster, as a layered stack |
| [`k8-cluster-network.md`](docs/k8-cluster-network.md) | Pod networking, LAN exposure, ingress, TLS, and DNS |
| [`k8-cluster-authentication.md`](docs/k8-cluster-authentication.md) | The identity provider and how each service integrates with it |
| [`systemd.md`](docs/systemd.md) | Boot and shutdown ordering where systemd, NFS, and Kubernetes storage collide |
| [`home-automation.md`](docs/home-automation.md) | Working notes on the Home Assistant / Thread / Matter stack |

## Development

### Linting

To lint an Ansible Playbook, run

```sh
just lint [TARGET]
```

**Example**

```sh
just lint playbooks/nodes/cluster/bootstrap.yml
```

## AI Assistance

As noted, this codebase has been developed with AI assistance. Guidelines for the AI coding agents are provided in the following files

| Location | Contains |
|----------|----------|
| `CLAUDE.md` | Standing rules that apply to every session — conventions, working style, and what an agent may do directly versus what it must ask for |
| `.claude/rules/` | Conventions scoped to particular files through a `paths:` field in each rule's front matter. A rule loads only when a matching file is read, keeping file-specific guidance out of sessions that never touch those files |
| `.claude/skills/` | Procedures invoked on demand rather than applied continuously — `polish` cleans up a session's changes, and `finalize` prepares them for a commit |
