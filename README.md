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
    ```

3.  Create a `group_vars/homelab.yml` file for group-level variables:

    ```yaml
    dns_zone: <DNS_ZONE>
    lb_ip_pool_cidr: <CIDR>
    router_private_ip: <ROUTER_IP>
    dropbear_port: <DROPBEAR_PORT>
    shutdown_schedule: <SHUTDOWN_SCHEDULE>
    admin_email: <ADMIN_EMAIL>
    bootstrap_admin_password: <BOOTSTRAP_ADMIN_PASSWORD>
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

- **`become_exe` configuration**: `become_exe` must be set to `sudo.ws` to resolve an issue
  with Ansible. See [Ansible Issue #85837](https://github.com/ansible/ansible/issues/85837)
  for details.
- **Service playbook run order**: Some Playbooks have dependencies on others. For example, the authentication Playbook must be (re)deployed after adding a new Kubernetes service:
  ```sh
  just install services <SERVICE>
  just install cluster authentication
  ```
- **Local DNS Resolution**: To resolve homelab services (e.g., `*.homelab.internal`) from your local machine, configure your OS to use the cluster's Bind9 LoadBalancer IP as its nameserver. Note that Syncthing sync traffic uses a **dedicated LoadBalancer IP** (separate from the web GUI) to ensure high-performance data transfer.
  - **macOS Setup**:
    ```sh
    sudo mkdir -p /etc/resolver
    echo "nameserver <BIND9_LB_IP>" | sudo tee /etc/resolver/<DNS_ZONE>
    ```
