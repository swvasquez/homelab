set shell := ["bash", "-euxo", "pipefail", "-c"]
set unstable

# +----------------------------------------------------------------------------+
# | Setup — create and configure the local Python virtual environment          |
# +----------------------------------------------------------------------------+

# Create a virtual environment and install dependencies
venv:
    uv venv
    uv pip install ansible-dev-tools pre-commit

# +----------------------------------------------------------------------------+
# | Deploy — run Ansible playbooks against inventory hosts                     |
# +----------------------------------------------------------------------------+

# Run a specific Ansible playbook on a subset of machines
deploy group category playbook:
    uv run ansible-playbook \
        --ask-become-pass \
        -i inventory.yml \
        "playbooks/{{ group }}/{{ category }}/{{ playbook }}.yml"

# +----------------------------------------------------------------------------+
# | Lint — validate Ansible playbooks with ansible-lint                        |
# +----------------------------------------------------------------------------+

# Lint Ansible playbooks using ansible-lint
lint target="playbooks":
    uv run ansible-lint {{ target }}

# +----------------------------------------------------------------------------+
# | Nodes — manage connectivity and power state of inventory nodes             |
# +----------------------------------------------------------------------------+

# Verify that a subset of machines are reachable via Ansible
ping subset="nodes":
    uv run ansible {{ subset }} -m ping -i inventory.yml

# Reboot all nodes in the inventory (non-blocking)
reboot subset="nodes":
    uv run ansible {{ subset }} \
        --ask-become-pass \
        -i inventory.yml \
        -m ansible.builtin.command \
        -a 'reboot' \
        --become \
        -e ansible_become_exe=sudo.ws \
        -B 1 -P 0

# Wake all nodes in a group via Wake-on-LAN magic packet (MAC addresses read from inventory.yml)
wake subset="nodes":
    uv run ansible-inventory -i inventory.yml --list \
        | jq -r '.{{ subset }}.hosts[] as $h | ._meta.hostvars[$h].mac_address' \
        | xargs -I{} wakeonlan {}

# Suspend all nodes in the inventory to S3 (non-blocking)
suspend subset="nodes":
    uv run ansible {{ subset }} \
        --ask-become-pass \
        -i inventory.yml \
        -m ansible.builtin.command \
        -a 'systemd-run --on-active=5 systemctl suspend' \
        --become \
        -e ansible_become_exe=sudo.ws

# Shutdown all nodes in the inventory (non-blocking)
shutdown subset="nodes":
    uv run ansible {{ subset }} \
        --ask-become-pass \
        -i inventory.yml \
        -m ansible.builtin.command \
        -a 'shutdown now' \
        --become \
        -e ansible_become_exe=sudo.ws \
        -B 1 -P 0

# +----------------------------------------------------------------------------+
# | Kubernetes — manage the Kubernetes cluster                                 |
# +----------------------------------------------------------------------------+

# Destroy the Kubernetes cluster on all nodes — IRREVERSIBLE, deletes all data
[script]
destroy-cluster subset="nodes":
    printf 'WARNING: This will permanently destroy the Kubernetes cluster and all data on "%s".\nType "destroy" to confirm: ' '{{ subset }}'
    read -r confirmation
    if [ "$confirmation" != "destroy" ]; then
        echo "Aborted."
        exit 1
    fi
    uv run ansible {{ subset }} \
        --ask-become-pass \
        -i inventory.yml \
        -m ansible.builtin.shell \
        -a 'kubeadm reset -f --cri-socket unix:///var/run/cri-dockerd.sock' \
        --become \
        -e ansible_become_exe=sudo.ws \
        -B 1 -P 0

# +----------------------------------------------------------------------------+
# | Secrets — store and retrieve credentials from the pass store               |
# +----------------------------------------------------------------------------+

# Store the Tailscale auth key and API key in the pass store
# (press Enter without typing to keep existing values)
[script]
tailscale-set-keys pass_namespace=env_var('PASS_NAMESPACE'):
    set +x
    update_key() {
        name="$1"
        path="$2"
        if pass show "$path" >/dev/null 2>&1; then
            printf '%s (Enter to keep existing): ' "$name"
        else
            printf '%s: ' "$name"
        fi
        read -rs value
        printf '\n'
        if [ -n "$value" ]; then
            printf '%s\n' "$value" | pass insert --echo --force "$path"
        fi
    }
    update_key 'Tailscale auth key (tskey-auth-...)' '{{ pass_namespace }}/tailscale/auth-key'
    update_key 'Tailscale API key (tskey-api-...)' '{{ pass_namespace }}/tailscale/api-key'

# Print the OpenBao root token from the pass store (paste into the UI Token method)
# Reads PASS_NAMESPACE from the environment; override with: just bao-token pass_namespace=<name>
bao-token pass_namespace=env_var('PASS_NAMESPACE'):
    @pass show {{ pass_namespace }}/openbao/root-token

# Drop into a subshell with BAO_ADDR + BAO_SKIP_VERIFY + BAO_TOKEN set for ad-hoc bao CLI work
# Reads PASS_NAMESPACE from the environment; override with: just bao-shell pass_namespace=<name>
[script]
bao-shell openbao_hostname="openbao.homelab.internal" pass_namespace=env_var('PASS_NAMESPACE'):
    set +x
    export BAO_ADDR="https://{{ openbao_hostname }}"
    export BAO_SKIP_VERIFY=true
    BAO_TOKEN="$(pass show {{ pass_namespace }}/openbao/root-token)"
    export BAO_TOKEN
    exec bash

# +----------------------------------------------------------------------------+
# | Utilities — miscellaneous local machine helpers                            |
# +----------------------------------------------------------------------------+

# Flush the local DNS cache
[script]
flush-dns:
    if [ "$(uname)" = "Darwin" ]; then
        sudo dscacheutil -flushcache
        sudo killall -HUP mDNSResponder
    else
        sudo resolvectl flush-caches
    fi
