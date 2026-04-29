# Create a virtual environment and install dependencies
venv:
    #!/usr/bin/env sh
    set -euxo pipefail
    uv venv
    uv pip install ansible-dev-tools pre-commit

# Lint Ansible playbooks using ansible-lint
lint target="playbooks":
    #!/usr/bin/env sh
    set -euxo pipefail
    uv run ansible-lint {{ target }}

# Run a specific Ansible playbook on a subset of machines
install group category playbook:
    #!/usr/bin/env sh
    set -euxo pipefail
    uv run ansible-playbook \
        --ask-become-pass \
        -i inventory.yml \
        "playbooks/{{ group }}/{{ category }}/{{ playbook }}.yml"

# Verify that a subset of machines are reachable via Ansible
ping subset="homelab":
    #!/usr/bin/env sh
    set -euxo pipefail
    uv run ansible {{ subset }} -m ping -i inventory.yml

# Reboot all nodes in the inventory (non-blocking)
reboot subset="homelab":
    #!/usr/bin/env sh
    set -euxo pipefail
    uv run ansible {{ subset }} \
        --ask-become-pass \
        -i inventory.yml \
        -m ansible.builtin.command \
        -a 'reboot' \
        --become \
        -e ansible_become_exe=sudo.ws \
        -B 1 -P 0

# Wake all nodes in a group via Wake-on-LAN magic packet (MAC addresses read from inventory.yml)
wake subset="homelab":
    #!/usr/bin/env sh
    set -euxo pipefail
    uv run ansible-inventory -i inventory.yml --list \
        | jq -r '.{{ subset }}.hosts[] as $h | ._meta.hostvars[$h].mac_address' \
        | xargs -I{} wakeonlan {}

# Suspend all nodes in the inventory to S3 (non-blocking)
suspend subset="homelab":
    #!/usr/bin/env sh
    set -euxo pipefail
    uv run ansible {{ subset }} \
        --ask-become-pass \
        -i inventory.yml \
        -m ansible.builtin.command \
        -a 'systemd-run --on-active=5 systemctl suspend' \
        --become \
        -e ansible_become_exe=sudo.ws

# Shutdown all nodes in the inventory (non-blocking)
shutdown subset="homelab":
    #!/usr/bin/env sh
    set -euxo pipefail
    uv run ansible {{ subset }} \
        --ask-become-pass \
        -i inventory.yml \
        -m ansible.builtin.command \
        -a 'shutdown now' \
        --become \
        -e ansible_become_exe=sudo.ws \
        -B 1 -P 0

# Destroy the Kubernetes cluster on all nodes — IRREVERSIBLE, deletes all data
destroy-cluster subset="homelab":
    #!/usr/bin/env sh
    printf 'WARNING: This will permanently destroy the Kubernetes cluster and all data on "%s".\nType "destroy" to confirm: ' '{{ subset }}'
    read confirmation
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

# Print the OpenBao root token from the dedicated openbao macOS keychain (paste into the UI Token method)
bao-token openbao_keychain="openbao.keychain":
    @security find-generic-password -a root-token -s openbao -w "{{ openbao_keychain }}"

# Drop into a subshell with BAO_ADDR + BAO_SKIP_VERIFY + BAO_TOKEN set for ad-hoc bao CLI work
bao-shell openbao_hostname="openbao.homelab.internal" openbao_keychain="openbao.keychain":
    #!/usr/bin/env sh
    set -euo pipefail
    security unlock-keychain "{{ openbao_keychain }}"
    export BAO_ADDR="https://{{ openbao_hostname }}"
    export BAO_SKIP_VERIFY=true
    BAO_TOKEN="$(security find-generic-password -a root-token -s openbao -w "{{ openbao_keychain }}")"
    export BAO_TOKEN
    exec "${SHELL:-sh}"

# Flush the local DNS cache
flush-dns:
    #!/usr/bin/env sh
    set -euxo pipefail
    if [ "$(uname)" = "Darwin" ]; then
        sudo dscacheutil -flushcache
        sudo killall -HUP mDNSResponder
    else
        sudo resolvectl flush-caches
    fi
