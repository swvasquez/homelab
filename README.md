# Homelab

Ansible Playbooks to configure Ubuntu machines.

## Prerequisites

- [just](https://github.com/casey/just)
- [uv](https://github.com/astral-sh/uv)

## Setup

1.  Create a virtual environment with required dependencies:

    ```sh
    just venv
    ```

2.  Create an `inventory.ini` file with the following structure:

    ```ini
    [homelab]
    <HOSTNAME> ansible_user=<USER> private_ip=<IP> network_interface=<INTERFACE> mac_address=<MAC>
    ```

3.  Create a `group_vars/homelab.yml` file for group-level variables:

    ```yaml
    dropbear_port: <DROPBEAR_PORT>
    router_private_ip: <ROUTER_IP>
    ```

## Usage

### Run a Playbook

To run a specific playbook on a subset of machines:

```sh
just install <playbook> <subset>
```

**Example:**

```sh
just install docker homelab
```

### Verify Connectivity

To ping a subset of machines:

```sh
just ping <subset>
```

### Linting

To lint the playbooks:

```sh
just lint
```

## Notes

- **`become_exe` configuration**: `become_exe` must be set to `sudo.ws` to resolve an issue with Ansible. See [Ansible Issue #85837](https://github.com/ansible/ansible/issues/85837) for details.

## Acknowledgements

This code was generated with AI assistance.
