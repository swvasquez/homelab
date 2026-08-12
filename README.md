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
| [docker](https://www.docker.com/) | Container runtime that hosts the dev container |
| [npm](https://www.npmjs.com/) | Node package manager; `just devcontainer-up` uses `npx` to run the `devcontainer` CLI |
| [sbx](https://docs.docker.com/ai/sandboxes/) | Docker Sandboxes CLI; `just sbx-up` uses it to run the agent sandbox |

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

## Devcontainer

`.devcontainer/` defines a sandboxed container where Claude Code can access source code and run tasks. The dev container does not have access to the LAN or Kubernetes cluster, but does have access to the WAN. The assumption is that the user will interact with the agent, run commands on its behalf, and share the output for it to assess.

Dev containers are long-running containers. You start the dev container via

```sh
just devcontainer-up
```

You then connect to the running container for development via

```sh
just devcontainer-shell
```

| Input | Source |
|-------|--------|
| Repository | Bind-mounted from the host at `/workspaces/homelab` |
| Ansible | Installed on first start by `just venv`, into a volume separate from the host's `.venv` |
| Agent credentials | Entered once on first use and kept in a volume |
| Egress rules | The reserved ranges named in `.devcontainer/firewall.sh`, reapplied on every start |

The `.venv`, the uv cache, and the agent's credentials are persisted in named volumes keyed to `${devcontainerId}`, which is stable across rebuilds; everything else in the container is not.

Note that `just devcontainer-up` rebuilds the dev container image and terminates any existing dev containers.

## Sandbox

`.sbx/` defines a Docker Sandboxes microVM serving the same purpose as the dev container, kept alongside it for comparison. The sandbox does not have access to the LAN, the Kubernetes cluster, or the tailnet, but does have access to the WAN. It carries no SSH keys and no cluster credentials, so the operator remains the only path to the homelab.

Sandboxes are long-running microVMs. You build and start one via

```sh
just sbx-up
```

You then connect to the running sandbox for development via

```sh
just sbx-shell
```

| Input | Source |
|-------|--------|
| Repository | Bind-mounted from the host |
| Ansible | Installed at creation by `just venv`, into `/opt/venv` outside the mount |
| Agent credentials | Entered once via `just sbx-login` and held in the host's credential store, never inside the sandbox |
| Egress rules | Reserved ranges named in the `justfile`; the LAN and DNS zone read from `group_vars/all.yml` |

Claude's session history and the uv cache are persisted under `.sbx/` in the repository, which is bind-mounted and therefore on the host; credentials are persisted in the host's operating system credential store. Both are ignored by `.gitignore`. Everything else, `/opt/venv` included, lives in the sandbox and is rebuilt with it.

Note that `just sbx-up` replaces the sandbox and terminates any existing one.
