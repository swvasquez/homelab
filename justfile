set shell := ["bash", "-euxo", "pipefail", "-c"]
set unstable
set script-interpreter := ["bash", "-eu"]

# +----------------------------------------------------------------------------+
# | Setup — create and configure the local Python virtual environment          |
# +----------------------------------------------------------------------------+

# VIRTUAL_ENV keeps the environment out of the repository when the repository is
# mounted into a sandbox, where a shared .venv would mix Darwin and Linux binaries
# Create a virtual environment and install dependencies
venv path=env_var_or_default("VIRTUAL_ENV", ".venv"):
    uv venv "{{ path }}"
    uv pip install --python "{{ path }}/bin/python" ansible-dev-tools

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
# | Sandbox — run tooling inside a Docker Sandboxes microVM                    |
# +----------------------------------------------------------------------------+

sbx_name := "homelab"

# Reserved ranges the sandbox is kept off regardless of what the inventory says.
# The three RFC 1918 blocks every LAN is numbered from:
private_10 := "10.0.0.0/8"
private_172 := "172.16.0.0/12"
private_192 := "192.168.0.0/16"

# RFC 3927 link-local, where cloud metadata endpoints such as 169.254.169.254 sit
link_local := "169.254.0.0/16"

# RFC 6598 shared address space, which Tailscale assigns tailnet addresses from
tailscale_cgnat := "100.64.0.0/10"

# Recreated rather than reused because a kit only takes effect at creation; the
# session history and uv cache the kit puts under .sbx/ are on the host and outlive
# it. With a branch, the agent works in a worktree under .sbx/, not the working tree
# Build and start the sandbox, replacing any existing one
[script]
sbx-up branch="":
    sbx rm --force {{ sbx_name }} || true
    args=(--name {{ sbx_name }} --kit ./.sbx/kit)
    # Narrows the kit's open egress back off the LAN. CIDR is enforced here but not
    # in a kit; the zone and LAN follow group_vars so they cannot drift from it
    dns_zone=$(awk '/^dns_zone:/ {print $2}' group_vars/all.yml)
    lan_cidr=$(awk '/^lan_cidr:/ {print $2}' group_vars/all.yml)
    : "${dns_zone:?not found in group_vars/all.yml}"
    : "${lan_cidr:?not found in group_vars/all.yml}"
    ranges=({{ private_10 }} {{ private_172 }} {{ private_192 }} {{ link_local }} {{ tailscale_cgnat }})
    ranges+=("$lan_cidr" "*.$dns_zone")
    for range in "${ranges[@]}"; do
        args+=(--deny-network "$range")
    done
    if [ -n "{{ branch }}" ]; then
        args+=(--branch="{{ branch }}")
    fi
    sbx create "${args[@]}" claude "{{ justfile_directory() }}"
    # The service name appears in the empty-result message, so match on that
    if sbx secret ls --service anthropic | grep -q "No secrets found"; then
        sbx run --name {{ sbx_name }} -- auth login
    fi

# Creating here would miss the deny rules sbx-up passes at creation
# Authenticate Claude Code and store the token in the sbx keychain
[script]
sbx-login:
    if ! sbx ls --quiet | grep -qx "{{ sbx_name }}"; then
        echo "No sandbox for this repository. Run 'just sbx-up' first." >&2
        exit 1
    fi
    sbx run --name {{ sbx_name }} -- auth login

# .sbx/env holds KEY=VALUE lines and stays uncommitted, the .gitignore allowlist
# ignoring anything it does not name. Reaches this shell only, never the agent
# Open a shell in the running sandbox
[script]
sbx-shell:
    args=(-it)
    if [ -f .sbx/env ]; then
        args+=(--env-file .sbx/env)
    fi
    sbx exec "${args[@]}" {{ sbx_name }} bash -l

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
