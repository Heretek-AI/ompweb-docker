# syntax=docker/dockerfile:1.7
#
# omp-sandbox — turnkey oh-my-pi (omp) agent engine + ompweb web UI.
#
# Layout:
#   ompweb-builder  node:22-bookworm-slim  → clone + `next build` ompweb
#   omp-release     node:22-bookworm-slim  → download the platform release binary
#   omp-source      rust:1.86-slim-bookworm→ clone + cargo/napi-build omp from source
#   omp-artifacts   selector: omp-${OMP_BUILD}
#   runtime         node:22-bookworm-slim  → both payloads, unprivileged user, entrypoint
#
# Every build arg is declared before the first FROM so it is usable in FROM
# lines; each stage that reads an arg re-declares it (an arg declared before
# the first FROM is empty inside a stage until re-declared).
ARG NODE_VERSION=22-bookworm-slim
ARG BUN_VERSION=1.4.2
ARG UV_VERSION=0.12.17
ARG OMP_REPO=can1357/oh-my-pi
ARG OMP_REF=main
ARG OMP_BUILD=release
ARG OMP_VERSION=latest
ARG OMPWEB_REPO=kahme247/ompweb
ARG OMPWEB_REF=main

# ---- Stage: ompweb-builder ----
FROM node:${NODE_VERSION} AS ompweb-builder
ARG OMPWEB_REPO
ARG OMPWEB_REF

RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# Shared clone recipe: branch, tag, and bare SHA all work (a shallow
# `--branch` clone cannot check out a bare SHA, so we init + fetch by ref).
# The optional `github_token` secret keeps private forks reachable without a
# token ever landing in image history.
RUN --mount=type=secret,id=github_token \
    set -eux; \
    mkdir -p /src/ompweb; cd /src/ompweb; \
    git init -q; \
    git remote add origin "https://github.com/${OMPWEB_REPO}.git"; \
    if [ -s /run/secrets/github_token ]; then \
      git config --local credential.helper \
        '!f() { printf "username=x-access-token\npassword=%s\n" "$(cat /run/secrets/github_token)"; }; f'; \
    fi; \
    git fetch -q --depth 1 origin "${OMPWEB_REF}"; \
    git checkout -q FETCH_HEAD; \
    git rev-parse HEAD > .git-resolved; \
    rm -rf .git

WORKDIR /src/ompweb
# dev deps are required: Tailwind v4 / postcss / TypeScript are build-time only.
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --no-fund
# `next build --webpack`; next/font/google needs egress to fonts.googleapis.com.
RUN npm run build
# Drop the build toolchain but keep every production dep (next, react,
# undici, yaml, mammoth, mermaid, katex, react-markdown, dbus-next, ...).
RUN npm prune --omit=dev

# ---- Stage: omp-release (download a published release binary) ----
FROM node:${NODE_VERSION} AS omp-release
ARG OMP_REPO
ARG OMP_REF
ARG OMP_VERSION

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) arch=x64 ;; \
      arm64) arch=arm64 ;; \
      *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    if [ "${OMP_VERSION}" != "latest" ]; then \
      tag="${OMP_VERSION}"; \
    elif printf '%s' "${OMP_REF}" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+$'; then \
      tag="${OMP_REF}"; \
    else \
      tag="$(curl -fsSL "https://api.github.com/repos/${OMP_REPO}/releases/latest" \
             | grep -o '"tag_name": *"[^"]*"' | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')"; \
      echo "WARNING: OMP_BUILD=release ignores OMP_REF; using latest release ${tag}" >&2; \
    fi; \
    test -n "${tag}"; \
    base="https://github.com/${OMP_REPO}/releases/download/${tag}"; \
    mkdir -p /opt/omp; \
    curl -fsSL "${base}/omp-linux-${arch}" -o /opt/omp/omp; \
    curl -fsSL "${base}/SHA256SUMS.txt" -o /tmp/SHA256SUMS.txt; \
    expect="$(grep " omp-linux-${arch}\$" /tmp/SHA256SUMS.txt | awk '{print $1}')"; \
    test -n "${expect}"; \
    actual="$(sha256sum /opt/omp/omp | awk '{print $1}')"; \
    if [ "${expect}" != "${actual}" ]; then \
      echo "sha256 mismatch for omp-linux-${arch}: expected ${expect}, got ${actual}" >&2; exit 1; \
    fi; \
    rm -f /tmp/SHA256SUMS.txt; \
    chmod 0755 /opt/omp/omp; \
    /opt/omp/omp --version; \
    printf '%s\n' "${tag}" > /opt/omp/VERSION

# ---- Stage: omp-source (clone + build the natives addon) ----
FROM rust:1.86-slim-bookworm AS omp-source
ARG OMP_REPO
ARG OMP_REF
ARG BUN_VERSION

# clang/libclang-dev for bindgen over pipewire-sys/libspa-sys; cmake/make/
# ninja for opusic-sys's bundled Opus.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git curl ca-certificates unzip pkg-config libssl-dev build-essential \
        clang libclang-dev cmake make ninja-build \
    && rm -rf /var/lib/apt/lists/*

ARG BUN_VERSION
RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/opt/bun bash -s "bun-v${BUN_VERSION}"
ENV PATH=/opt/bun/bin:/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin

RUN --mount=type=secret,id=github_token \
    set -eux; \
    mkdir -p /pi; cd /pi; \
    git init -q; \
    git remote add origin "https://github.com/${OMP_REPO}.git"; \
    if [ -s /run/secrets/github_token ]; then \
      git config --local credential.helper \
        '!f() { printf "username=x-access-token\npassword=%s\n" "$(cat /run/secrets/github_token)"; }; f'; \
    fi; \
    git fetch -q --depth 1 origin "${OMP_REF}"; \
    git checkout -q FETCH_HEAD; \
    git rev-parse HEAD > .git-resolved; \
    rm -rf .git

WORKDIR /pi
# Reads the clone's rust-toolchain.toml (nightly-2026-08-12) and installs it.
RUN rustup show

# Hoisted workspace install; --ignore-scripts skips the root `prepare` hook
# that generates tool-views.generated.js (regenerated explicitly below).
RUN --mount=type=cache,target=/root/.bun/install/cache \
    bun install --frozen-lockfile --ignore-scripts

# Host natives build via the cargo/napi backend (Bazel is only for cross
# targets). Profile `ci` = release codegen, thin LTO, stripped.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/pi/target \
    OMP_NATIVE_CARGO_PROFILE=ci bun --cwd=packages/natives run build

# Mandatory: export/html/index.ts statically imports tool-views.generated.js
# and its absence breaks both interactive and rpc-ui launch.
RUN bun --cwd=packages/coding-agent run gen:tool-views

# Prune build-only trees; docs/ is kept because omp:// URLs resolve
# ../../../../docs from the coding-agent source tree.
RUN rm -rf /pi/.git /pi/target /pi/crates /pi/python /pi/bazel \
           /pi/BUILD.bazel /pi/MODULE.bazel /pi/MODULE.bazel.lock \
           /pi/.bazelrc /pi/.bazelversion /pi/.bazelignore \
           /pi/flake.lock /pi/flake.nix /pi/nix /pi/assets \
           /pi/Dockerfile /pi/.github /pi/node_modules/.cache

RUN set -eux; \
    mkdir -p /opt/omp; \
    cp -a /pi /opt/omp/pi; \
    { \
      printf '%s\n' '#!/usr/bin/env bash'; \
      printf '%s\n' 'set -euo pipefail'; \
      printf '%s\n' 'export PI_ROOT=/opt/omp/pi'; \
      printf '%s\n' 'exec /usr/local/bin/bun "$PI_ROOT/packages/coding-agent/src/cli.ts" "$@"'; \
    } > /opt/omp/omp; \
    chmod 0755 /opt/omp/omp; \
    printf 'source:%s@%s\n' "${OMP_REF}" "$(cat /pi/.git-resolved)" > /opt/omp/VERSION

# ---- Stage: omp-artifacts (selector) ----
# An unknown OMP_BUILD fails loudly with Docker's "invalid reference format".
FROM omp-${OMP_BUILD} AS omp-artifacts

# ---- Stage: runtime ----
FROM node:${NODE_VERSION} AS runtime
ARG BUN_VERSION
ARG UV_VERSION
ARG OMP_BUILD

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg jq unzip xz-utils less procps sqlite3 \
        tini gosu git git-lfs openssh-client \
        python3 python3-venv python3-pip \
        build-essential g++ make cmake pkg-config \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI from its apt repo.
RUN set -eux; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    rm -rf /var/lib/apt/lists/*

# Docker CLI only — the daemon lives on the host, reached via the mounted socket.
RUN set -eux; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc; \
    chmod a+r /etc/apt/keyrings/docker.asc; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends docker-ce-cli; \
    rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash -s "bun-v${BUN_VERSION}" \
    && test "$(bun --version)" = "${BUN_VERSION}"

RUN curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" \
      | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh \
    && uv --version

# The node base image ships a `node` user at UID/GID 1000; drop it so the
# sandbox user owns 1000. The entrypoint remaps both for other hosts.
RUN userdel -r node 2>/dev/null || true; \
    groupdel node 2>/dev/null || true; \
    groupadd -g 1000 omp \
    && useradd -u 1000 -g 1000 -M -d /home/omp -s /bin/bash omp \
    && mkdir -p /home/omp/.omp /home/omp/.config /home/omp/.ssh /workspace

# Engine + frontend payloads (root-owned read-only).
COPY --from=omp-artifacts /opt/omp /opt/omp
COPY --from=ompweb-builder /src/ompweb /app/ompweb
RUN install -m 0755 /opt/omp/omp /usr/local/bin/omp \
    && omp --version

ENV HOME=/home/omp \
    NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    OMP_WEB_HOSTNAME=0.0.0.0 \
    OMP_WEB_NO_OPEN=1 \
    OMP_WEB_OMP_BIN=/usr/local/bin/omp \
    OMP_SKIP_SETUP=1 \
    UV_SYSTEM_PYTHON=1 \
    BUN_INSTALL=/usr/local \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# docker exec lands in the workspace, and process.cwd() fallbacks point here
# rather than at /app/ompweb.
WORKDIR /workspace
RUN chown -R omp:omp /home/omp /workspace

COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

LABEL org.opencontainers.image.title="ompweb-docker" \
      org.opencontainers.image.description="Turnkey sandbox: oh-my-pi (omp) agent engine + ompweb web UI" \
      org.opencontainers.image.source=https://github.com/Heretek-AI/ompweb-docker \
      org.opencontainers.image.licenses=MIT \
      com.heretek.omp.build=${OMP_BUILD}

EXPOSE 3000
# Shell form so the runtime PORT is honored; 4xx/5xx fails, a 307 to /login is healthy.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -fsS -o /dev/null "http://127.0.0.1:${PORT:-3000}/" || exit 1

# No USER directive: the entrypoint must start as root to chown volumes and
# drop privileges to `omp` with gosu before any user code runs.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
