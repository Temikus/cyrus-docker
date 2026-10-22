# Unofficial container image for cyrusagents/cyrus.
#
# Upstream ships Cyrus only as the `cyrus-ai` npm package, so this installs it
# on a Node base. Versions are pinned ARGs that Renovate bumps; see README.md.

# renovate: datasource=docker depName=node
ARG NODE_TAG=24.22.0-trixie-slim

FROM node:${NODE_TAG}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# renovate: datasource=npm depName=cyrus-ai
ARG CYRUS_VERSION=0.2.73
# renovate: datasource=github-releases depName=cli/cli extractVersion=^v(?<version>.*)$
ARG GH_VERSION=2.103.0
ARG TARGETARCH
ARG BUILD_DATE
ARG VCS_REF

LABEL maintainer="temikus" \
    org.opencontainers.image.created=$BUILD_DATE \
    org.opencontainers.image.title="cyrus" \
    org.opencontainers.image.description="Unofficial image for Cyrus - Linear/GitHub coding agent powered by Claude Code" \
    org.opencontainers.image.version=$CYRUS_VERSION \
    org.opencontainers.image.revision=$VCS_REF \
    org.opencontainers.image.source="https://github.com/temikus/cyrus-docker" \
    org.opencontainers.image.url="https://github.com/cyrusagents/cyrus" \
    org.opencontainers.image.licenses="Apache-2.0"

# tini reaps the agent subprocesses that Claude sessions spawn. bubblewrap and
# socat back Claude Code's Linux sandbox, which Cyrus's `sandbox` option uses.
# Package versions follow the pinned base image; exact apt pins break on every
# Debian point release.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bubblewrap ca-certificates curl git jq openssh-client socat tini \
    && rm -rf /var/lib/apt/lists/*

# Debian's gh lags upstream by a year or more.
RUN arch="${TARGETARCH:-$(dpkg --print-architecture)}" \
    && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${arch}.tar.gz" \
        -o /tmp/gh.tar.gz \
    && tar -xzf /tmp/gh.tar.gz -C /tmp \
    && install -m0755 "/tmp/gh_${GH_VERSION}_linux_${arch}/bin/gh" /usr/local/bin/gh \
    && rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION}_linux_${arch}"

# The Claude Agent SDK pulls in a native `claude` binary, so no separate install.
# Cyrus finds it on its own; the symlink is for `claude setup-token` and the
# like. The build fails here if the SDK stops shipping the binary.
RUN npm install -g "cyrus-ai@${CYRUS_VERSION}" && npm cache clean --force \
    && claude_bin="$(find /usr/local/lib/node_modules -path '*/claude-agent-sdk-linux-*/claude' -type f | grep -v musl | head -1)" \
    && test -n "${claude_bin}" \
    && ln -s "${claude_bin}" /usr/local/bin/claude

# Git over HTTPS authenticates with $GITHUB_TOKEN through gh.
RUN git config --system credential.https://github.com.helper '!gh auth git-credential'

COPY --chmod=0755 cyrus-entrypoint.sh /usr/local/bin/cyrus-entrypoint.sh

USER node
WORKDIR /home/node
# Without CYRUS_HOST_EXTERNAL the server binds localhost and is unreachable
# from outside the container.
ENV CYRUS_HOST_EXTERNAL=true \
    CYRUS_SERVER_PORT=3456
EXPOSE 3456
VOLUME ["/home/node"]

ENTRYPOINT ["tini", "--", "cyrus-entrypoint.sh"]
CMD ["cyrus"]
