# Image for running Claude Code against this repository.
#
# The container has no cluster credentials and no LAN access: the agent reads and
# edits code, and anything that touches the cluster is run by the operator.
#
# Ansible is deliberately not installed here — `just venv` installs it at
# container-create time, so every rebuild exercises the repository's documented
# setup path instead of a parallel one that can drift.

ARG UV_VERSION=0.12.3

FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

# Matches the OS on the cluster nodes.
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG JUST_VERSION=1.58.0

# The legacy iptables backend is selected because the container shares the host
# kernel's netfilter tables, and nft-mode rules written from two namespaces can
# collide on Docker Desktop.
#
# libonig-dev is here for `just venv`: ansible-dev-tools pulls in onigurumacffi,
# which publishes no wheel for this Python on arm64 and so compiles against
# oniguruma.h. Supplying the header keeps the recipe itself unmodified, which is
# the point of installing Ansible through it.
# git-crypt is required by the filters .gitattributes declares on the sshd
# hardening templates. Without the binary, git refuses to run those filters and
# ordinary commands like `git status` fail. The container has no decryption key,
# so those two files stay encrypted — which is the intent.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        dnsutils \
        git-crypt \
        iptables \
        jq \
        libonig-dev \
    && update-alternatives --set iptables /usr/sbin/iptables-legacy \
    && rm -rf /var/lib/apt/lists/*

# just names its release tarballs by Rust target triple, so the Debian
# architecture has to be translated — the container is arm64 on Apple Silicon.
RUN case "$(dpkg --print-architecture)" in \
        amd64) just_target=x86_64-unknown-linux-musl \
            just_sha256=4a5cc2f53e6f0f8c59092a6cc38291eb729d46a7dd95d3ae582008881b84931d ;; \
        arm64) just_target=aarch64-unknown-linux-musl \
            just_sha256=748237128c4c40cbdabc65e841d05ceba13cc23a91eaba395495894c1d9764df ;; \
        *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac \
    && just_url="https://github.com/casey/just/releases/download/${JUST_VERSION}" \
    && curl -fsSL -o /tmp/just.tar.gz \
        "${just_url}/just-${JUST_VERSION}-${just_target}.tar.gz" \
    && echo "${just_sha256}  /tmp/just.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/just.tar.gz -C /usr/local/bin just \
    && rm /tmp/just.tar.gz

COPY --from=uv /uv /uvx /usr/local/bin/

# Highest settings precedence, so a checked-out branch cannot edit it away.
RUN install -d -m 0755 /etc/claude-code
COPY managed-settings.json /etc/claude-code/managed-settings.json

COPY --chmod=0755 firewall.sh /usr/local/bin/
