set shell := ["bash", "-euxo", "pipefail", "-c"]
set unstable
set script-interpreter := ["bash", "-eu"]

# +----------------------------------------------------------------------------+
# | Setup — create and configure the local Python virtual environment          |
# +----------------------------------------------------------------------------+

# Create a virtual environment and install dependencies
venv:
    uv venv
    uv pip install ansible-dev-tools pre-commit

# +----------------------------------------------------------------------------+
# | Devcontainer — run tooling inside an isolated container                    |
# +----------------------------------------------------------------------------+

devcontainer_cli := "npx --yes @devcontainers/cli@0.88.0"

# Must match `workspaceFolder` in devcontainer.json
devcontainer_workspace := "/workspaces/homelab"

# Build and start the devcontainer, replacing any existing one
devcontainer-up:
    {{ devcontainer_cli }} up --workspace-folder . --remove-existing-container

# Open a shell in the running devcontainer
[script]
devcontainer-shell:
    filter="label=devcontainer.local_folder={{ justfile_directory() }}"
    container="$(docker ps -q --filter "$filter")"
    if [ -z "$container" ]; then
        echo "No running devcontainer for this repository. Run 'just devcontainer-up' first." >&2
        exit 1
    fi
    docker exec -it -u vscode -w "{{ devcontainer_workspace }}" "$container" bash

# +----------------------------------------------------------------------------+
# | Deploy — run Ansible playbooks against inventory hosts                     |
# +----------------------------------------------------------------------------+

# Trailing arguments are passed through to ansible-playbook, e.g.
#   just deploy ipkvm infrastructure tailscale -e tailscale_upgrade=true
# Run a specific Ansible playbook on a subset of machines
deploy group category playbook *extra:
    uv run ansible-playbook \
        --ask-become-pass \
        -i inventory.yml \
        "playbooks/{{ group }}/{{ category }}/{{ playbook }}.yml" \
        {{ extra }}

# +----------------------------------------------------------------------------+
# | Lint — validate Ansible playbooks with ansible-lint                        |
# +----------------------------------------------------------------------------+

# Lint Ansible playbooks using ansible-lint
lint target="playbooks":
    uv run ansible-lint "{{ target }}"

# +----------------------------------------------------------------------------+
# | Nodes — manage connectivity and power state of inventory nodes             |
# +----------------------------------------------------------------------------+

# Verify that a subset of machines are reachable via Ansible
ping subset="nodes":
    uv run ansible "{{ subset }}" -m ping -i inventory.yml

# Reboot all nodes in the inventory (non-blocking)
reboot subset="nodes":
    uv run ansible "{{ subset }}" \
        --ask-become-pass \
        -i inventory.yml \
        -m ansible.builtin.command \
        -a 'reboot' \
        --become \
        -e ansible_become_exe=sudo.ws \
        -B 1 -P 0

# Wake all nodes in a group via Wake-on-LAN (MAC and broadcast addresses read from inventory.yml)
wake subset="nodes":
    uv run ansible-inventory -i inventory.yml --list \
        | jq -r '.{{ subset }}.hosts[] as $h | ._meta.hostvars[$h] \
            | "wakeonlan -i \(.lan_broadcast) \(.mac_address)"' \
        | sh

# Suspend all nodes in the inventory to S3 (non-blocking)
suspend subset="nodes":
    uv run ansible "{{ subset }}" \
        --ask-become-pass \
        -i inventory.yml \
        -m ansible.builtin.command \
        -a 'systemd-run --on-active=5 systemctl suspend' \
        --become \
        -e ansible_become_exe=sudo.ws

# Shutdown all nodes in the inventory (non-blocking)
shutdown subset="nodes":
    uv run ansible "{{ subset }}" \
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
    printf 'WARNING: This will permanently destroy the Kubernetes cluster and all data on "%s".\n' \
        '{{ subset }}'
    printf 'Type "destroy" to confirm: '
    read -r confirmation
    if [ "$confirmation" != "destroy" ]; then
        echo "Aborted."
        exit 1
    fi
    uv run ansible "{{ subset }}" \
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

# Press Enter without typing to keep existing values
# Store the Tailscale auth key and API key in the pass store
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

# Reads PASS_NAMESPACE from the environment; override with: just bao-token pass_namespace=<name>
# Print the OpenBao root token from the pass store (paste into the UI Token method)
bao-token pass_namespace=env_var('PASS_NAMESPACE'):
    @pass show "{{ pass_namespace }}/openbao/root-token"

# Reads PASS_NAMESPACE from the environment; override with: just bao-shell pass_namespace=<name>
# Drop into a subshell with BAO_ADDR + BAO_SKIP_VERIFY + BAO_TOKEN set for ad-hoc bao CLI work
[script]
bao-shell openbao_hostname="openbao.homelab.internal" pass_namespace=env_var('PASS_NAMESPACE'):
    set +x
    export BAO_ADDR="https://{{ openbao_hostname }}"
    export BAO_SKIP_VERIFY=true
    BAO_TOKEN="$(pass show "{{ pass_namespace }}/openbao/root-token")"
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
