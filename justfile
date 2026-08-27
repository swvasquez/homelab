# -x traces every command, so recipes handling a secret `set +x` first
set shell := ["bash", "-euxo", "pipefail", "-c"]
set unstable
set script-interpreter := ["bash", "-eu"]

# +----------------------------------------------------------------------------+
# | Setup — create and configure the local Python virtual environment        |
# +----------------------------------------------------------------------------+

# VIRTUAL_ENV keeps a sandbox's Linux environment out of the host's .venv
# Create a virtual environment and install dependencies
venv path=env_var_or_default("VIRTUAL_ENV", ".venv"):
    uv venv "{{ path }}"
    uv pip install --python "{{ path }}/bin/python" ansible-dev-tools

# +----------------------------------------------------------------------------+
# | Sandbox — run tooling inside a Docker Sandboxes microVM                  |
# +----------------------------------------------------------------------------+

sbx_name := "homelab"

# Recreated rather than reused, since a kit takes effect only at creation
# Build and start the sandbox; pass "cluster" to let the agent reach kubectl
[script]
sbx-up access="sealed":
    sbx rm --force {{ sbx_name }} || true
    cfg=$(.sbx/config.py)
    args=(--name {{ sbx_name }} --kit ./.sbx/kit)
    # -e: an unknown access mode must fail, not yield an empty deny list
    denies=$(jq -er '.deny_ranges["{{ access }}"][]' <<<"$cfg")
    while read -r resource; do
        args+=(--deny-network "$resource")
    done <<<"$denies"
    sbx create "${args[@]}" claude "{{ justfile_directory() }}"

# sbx keeps the OAuth token in the host keychain and seeds each new sandbox
# with a stand-in credential, so the agent starts signed in. If Claude ever
# prompts anyway, sign in at that prompt, from within the sandbox.

# .sbx/env (uncommitted KEY=VALUE lines) reaches this shell, not the agent
# Open a shell in the running sandbox
[script]
sbx-shell:
    args=(-it)
    if [ -f .sbx/env ]; then
        args+=(--env-file .sbx/env)
    fi
    sbx exec "${args[@]}" {{ sbx_name }} bash -l

# +----------------------------------------------------------------------------+
# | Deploy — run Ansible playbooks against inventory hosts                   |
# +----------------------------------------------------------------------------+

# Trailing arguments pass through to ansible-playbook, e.g. -e key=value
# Run a specific Ansible playbook on a subset of machines
deploy group category playbook *extra:
    uv run ansible-playbook \
        --ask-become-pass \
        -i inventory.yml \
        "playbooks/{{ group }}/{{ category }}/{{ playbook }}.yml" \
        {{ extra }}

# +----------------------------------------------------------------------------+
# | Lint — validate Ansible playbooks with ansible-lint                      |
# +----------------------------------------------------------------------------+

# Lint Ansible playbooks using ansible-lint
lint target="playbooks":
    uv run ansible-lint "{{ target }}"

# +----------------------------------------------------------------------------+
# | Nodes — manage connectivity and power state of inventory nodes           |
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

# Wake all nodes in a group via Wake-on-LAN (addresses from inventory.yml)
wake subset="nodes":
    uv run ansible-inventory -i inventory.yml --list \
        | jq -r '.{{ subset }}.hosts[] as $h | ._meta.hostvars[$h] \
            | "wakeonlan -i \(.lan_broadcast) \(.mac_address)"' \
        | sh

# Uses the unlock-<host> aliases from initramfs.yml. Their forced
# cryptroot-unlock reads piped stdin byte-for-byte, hence no trailing newline.
# An already-unlocked node keeps retrying like a failure: nothing listens on
# the Dropbear port once the real OS is up.
# Unlock the LUKS root of every node in a group (assumes `just wake` was run)
[script]
unlock subset="nodes":
    set +x
    read -rsp 'LUKS passphrase: ' pw
    printf '\nRetrying each node until it unlocks; press Ctrl-C to stop.\n'
    # Backgrounded jobs ignore SIGINT, so Ctrl-C alone leaves them retrying;
    # SIGTERM to the whole process group is not ignored and stops them. The
    # trap first sets both signals to ignored: kill 0 TERMs this shell too
    # (re-entering the trap recurses until bash segfaults), and a repeated
    # Ctrl-C between the two commands would otherwise kill this shell before
    # kill 0 reaches the jobs
    trap 'trap "" INT TERM; kill 0; exit 130' INT TERM
    for host in $(uv run ansible-inventory -i inventory.yml --list \
            | jq -r '.{{ subset }}.hosts[]'); do
        until printf '%s' "$pw" | ssh -T -o ConnectTimeout=5 "unlock-$host"; do
            sleep 15
        done && echo "Unlocked $host" &
    done
    wait

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
# | Kubernetes — manage the Kubernetes cluster                               |
# +----------------------------------------------------------------------------+

# Needs the agent ServiceAccount that `just deploy nodes cluster agent` creates
# Write the agent kubeconfig the sandbox reads, holding a freshly minted token
[script]
agent-kube-config duration="8h":
    set +x
    config=.sbx/agent.kubeconfig
    ca=$(mktemp)
    trap 'rm -f "$ca"' EXIT
    cluster=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
    api=$(.sbx/config.py | jq -r .api_endpoint)
    kubectl config view --raw --minify \
        -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
        | base64 -d > "$ca"
    rm -f "$config"
    kubectl config --kubeconfig="$config" set-cluster "$cluster" \
        --server="https://$api" \
        --certificate-authority="$ca" --embed-certs
    kubectl config --kubeconfig="$config" set-credentials agent \
        --token="$(kubectl create token agent --namespace agent \
                   --duration {{ duration }})"
    kubectl config --kubeconfig="$config" set-context "agent@$cluster" \
        --cluster="$cluster" --user=agent
    kubectl config --kubeconfig="$config" use-context "agent@$cluster"
    chmod 600 "$config"
    echo "Wrote $config, valid {{ duration }}."

# Destroy the Kubernetes cluster on all nodes — IRREVERSIBLE, deletes all data
[script]
destroy-cluster subset="nodes":
    printf 'WARNING: destroys the cluster and all data on "%s".\n' \
        '{{ subset }}'
    printf 'Type "destroy" to confirm: '
    read -r confirmation
    if [ "$confirmation" != "destroy" ]; then
        echo "Aborted."
        exit 1
    fi
    sock=unix:///run/containerd/containerd.sock
    uv run ansible "{{ subset }}" \
        --ask-become-pass \
        -i inventory.yml \
        -m ansible.builtin.shell \
        -a "kubeadm reset -f --cri-socket $sock" \
        --become \
        -e ansible_become_exe=sudo.ws \
        -B 1 -P 0

# +----------------------------------------------------------------------------+
# | Secrets — store and retrieve credentials from the pass store             |
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
    update_key 'Tailscale auth key (tskey-auth-...)' \
        '{{ pass_namespace }}/tailscale/auth-key'
    update_key 'Tailscale API key (tskey-api-...)' \
        '{{ pass_namespace }}/tailscale/api-key'

# Print the OpenBao root token from the pass store (for the UI Token method)
bao-token pass_namespace=env_var('PASS_NAMESPACE'):
    @pass show "{{ pass_namespace }}/openbao/root-token"

# Drop into a subshell with BAO_ADDR, BAO_SKIP_VERIFY and BAO_TOKEN set
[script]
bao-shell openbao_hostname="openbao.homelab.internal" \
        pass_namespace=env_var('PASS_NAMESPACE'):
    set +x
    export BAO_ADDR="https://{{ openbao_hostname }}"
    export BAO_SKIP_VERIFY=true
    BAO_TOKEN="$(pass show "{{ pass_namespace }}/openbao/root-token")"
    export BAO_TOKEN
    exec bash

# +----------------------------------------------------------------------------+
# | Utilities — miscellaneous local machine helpers                          |
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
