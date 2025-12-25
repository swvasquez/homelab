# Create a virtual environment and install dependencies
venv:
    #!/usr/bin/env sh
    set -euxo pipefail
    uv venv
    uv pip install ansible-dev-tools pre-commit

# Lint Ansible playbooks using ansible-lint
lint:
    #!/usr/bin/env sh
    set -euxo pipefail
    uv run ansible-lint playbooks

# Verify that a subset of machines are reachable via Ansible
ping subset="homelab":
    #!/usr/bin/env sh
    set -euxo pipefail
    uv run ansible {{ subset }} -m ping -i inventory.ini

# Run a specific Ansible playbook on a subset of machines
install playbook subset="homelab":
    #!/usr/bin/env sh
    set -euxo pipefail
    uv run ansible-playbook \
        --ask-become-pass \
        --limit {{ subset }} \
        -i inventory.ini \
        "playbooks/{{ playbook }}.yml"
