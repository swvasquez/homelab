#!/bin/bash
#
# Blocks the container from reaching the LAN. Egress to the internet is open, so
# the agent can research freely; nothing on the homelab network is reachable, so
# it cannot touch the cluster, the nodes, or any LAN-hosted service.
#
# This inverts the reference firewall in anthropics/claude-code, which allowlists
# destinations and denies the rest. An allowlist also bounds exfiltration, which
# this does not — the tradeoff is deliberate: open egress buys working web
# research, and the operator remains the only channel to the homelab.
#
# Idempotent — safe to re-run.

set -euo pipefail
IFS=$'\n\t'

# Private ranges, plus link-local (cloud metadata endpoints) and the carrier-grade
# NAT range that Tailscale assigns from — reaching a node over the tailnet would
# otherwise sidestep every rule below.
readonly PRIVATE_RANGES=(
    10.0.0.0/8
    172.16.0.0/12
    192.168.0.0/16
    169.254.0.0/16
    100.64.0.0/10
)

# Docker's embedded resolver is wired up with nat rules that the flush below
# would remove, breaking all name resolution.
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Egress is closed before the flush and reopened only once the reject rules are
# in place, so a failure anywhere in between leaves the container isolated rather
# than able to reach the LAN.
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Nothing here needs IPv6, and leaving it open would mean maintaining a second
# copy of the rules below for a set of ranges that is easy to get wrong.
if ip6tables -S >/dev/null 2>&1; then
    ip6tables -F
    ip6tables -X
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT DROP
    ip6tables -A INPUT -i lo -j ACCEPT
    ip6tables -A OUTPUT -o lo -j ACCEPT
    ip6tables -A OUTPUT -j REJECT --reject-with icmp6-adm-prohibited
else
    echo "WARNING: ip6tables unavailable — IPv6 is not filtered"
fi

# Ahead of the rejects, since the resolver is often a LAN address and blocking it
# would break name resolution for everything. Scoped to DNS itself.
while read -r ns; do
    echo "Allowing DNS to $ns"
    iptables -A OUTPUT -d "$ns" -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -d "$ns" -p tcp --dport 53 -j ACCEPT
done < <(awk '/^nameserver/ && $2 ~ /^[0-9.]+$/ {print $2}' /etc/resolv.conf)

# REJECT, not DROP, so a blocked command fails immediately instead of hanging.
for range in "${PRIVATE_RANGES[@]}"; do
    echo "Blocking $range"
    iptables -A OUTPUT -d "$range" -j REJECT --reject-with icmp-admin-prohibited
done

# Inbound stays closed.
iptables -P OUTPUT ACCEPT

echo "Firewall configuration complete"
echo "Verifying firewall rules..."

reject_args=(-j REJECT --reject-with icmp-admin-prohibited)
for range in "${PRIVATE_RANGES[@]}"; do
    if ! iptables -C OUTPUT -d "$range" "${reject_args[@]}" 2>/dev/null; then
        echo "ERROR: Firewall verification failed - no reject rule for $range"
        exit 1
    fi
done
echo "Verified: private ranges are blocked"

if ! curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - could not reach https://example.com"
    exit 1
fi
echo "Verified: internet egress is open"
