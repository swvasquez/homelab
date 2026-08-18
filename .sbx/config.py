#!/usr/bin/env python3
"""Print everything the sbx recipes need, as one JSON object.

Usage: .sbx/config.py

    {
      "api_endpoint": "<IP>:<PORT>",
      "deny_ranges": {"sealed": [...], "cluster": [...]}
    }

Every value is derived from inventory.yml and group_vars, so the sandbox tooling
depends on the repository's configuration and on nothing a playbook has to have
run first. `ansible-inventory` resolves them rather than a YAML parser here:
Ansible is the canonical reader of those files, so its answer cannot drift from
what the playbooks see. It also means this script needs no dependencies beyond
the standard library.

`ansible-inventory` dumps variables without rendering them, so a value that is
itself a Jinja template would come back unexpanded. Everything read here is a
literal.

deny_ranges holds two lists, and `just sbx-up` picks one. "sealed" denies the
LAN whole; "cluster" subtracts the API server so the agent can reach kubectl.
Both are emitted unconditionally so the choice lives in the recipe rather than
in an argument to this script, which stays a pure function of the repository.

The subtraction is necessary because sbx resolves deny before allow: permitting
the API server explicitly would lose to any deny still covering it, so the only
way to reach it is for no deny to match. address_exclude yields the minimal
covering set -- 16 CIDRs for 192.168.0.0/16 alone, which is why this is not
written out by hand.

The DNS zone is denied whole, with no exception. The sandbox addresses the
control plane by IP precisely so it does not depend on Bind9, which runs inside
the cluster it is used to debug.

The unit of subtraction is an address, not an address and port, so the exclusion
exposes every port on the control plane node rather than 6443 alone. UFW on the
node is what still bounds that: kubelet, etcd, and node_exporter are all marked
node_only in ufw_allowed_ports and refuse a non-node source.
"""

import ipaddress
import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# Ranges the sandbox is kept off regardless of what the inventory says: the
# three RFC 1918 blocks, RFC 3927 link-local (where metadata endpoints such as
# 169.254.169.254 sit), and the RFC 6598 space Tailscale assigns from.
RESERVED_RANGES = [
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "169.254.0.0/16",
    "100.64.0.0/10",
]


def control_plane_vars():
    """Return the merged variables of the host flagged as the bootstrap node."""
    dump = subprocess.run(
        ["uv", "run", "ansible-inventory", "-i", str(REPO / "inventory.yml"),
         "--list"],
        cwd=REPO, capture_output=True, text=True, check=True,
    )
    hosts = json.loads(dump.stdout)["_meta"]["hostvars"]
    for host in hosts.values():
        if host.get("bootstrap_node"):
            return host
    sys.exit("no host in inventory.yml has bootstrap_node: true")


def deny_ranges(ranges, keep):
    """Yield each range, with `keep` subtracted from any CIDR containing it.

    The caller passes overlapping ranges -- the LAN CIDR sits inside the RFC
    1918 block that also covers it -- so subtracting from both yields the same
    remainders twice. Deduplicated so the list is what reaches sbx, in order.
    """
    seen = set()
    for entry in ranges:
        try:
            network = ipaddress.ip_network(entry)
        except ValueError:
            resources = [entry]  # a wildcard domain, nothing to subtract from
        else:
            if keep.subnet_of(network):
                remainder = network.address_exclude(keep)
                resources = [str(n) for n in sorted(remainder)]
            else:
                resources = [str(network)]
        for resource in resources:
            if resource not in seen:
                seen.add(resource)
                yield resource


def main():
    host = control_plane_vars()
    api_host = host["private_ip"]
    api_port = host["ufw_allowed_ports"]["kubernetes_api"]["port"]
    dns_zone = host["dns_zone"]
    lan_cidr = host["lan_cidr"]

    ranges = RESERVED_RANGES + [lan_cidr, f"*.{dns_zone}"]
    keep = ipaddress.ip_network(api_host)
    unreachable = ipaddress.ip_network("255.255.255.255/32")

    print(json.dumps({
        "api_endpoint": f"{api_host}:{api_port}",
        "deny_ranges": {
            # Excluding an address outside every range leaves them all intact.
            "sealed": list(deny_ranges(ranges, unreachable)),
            "cluster": list(deny_ranges(ranges, keep)),
        },
    }, indent=2))


if __name__ == "__main__":
    main()
