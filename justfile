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

# Verify that a subset of machines are reachable via Ansible
ping subset="homelab":
    #!/usr/bin/env sh
    set -euxo pipefail
    uv run ansible {{ subset }} -m ping -i inventory.yml

# Run a specific Ansible playbook on a subset of machines
install category playbook subset="homelab":
    #!/usr/bin/env sh
    set -euxo pipefail
    uv run ansible-playbook \
        --ask-become-pass \
        --limit {{ subset }} \
        -i inventory.yml \
        "playbooks/{{ category }}/{{ playbook }}.yml"
