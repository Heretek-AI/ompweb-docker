# syntax=docker/dockerfile:1
#
# Multi-stage build for ompweb + oh-my-pi (omp).
#
# Stage 1 (ompweb-install): `npm install @kahme247/ompweb` — its published tarball
#                           ships .next/ pre-built (see the package's `prepack` script),
#                           so we skip next build entirely.
# Stage 2 (runtime):        node:26-slim + Bun + tini + gosu + the omp binary
#                           installed via `bun install -g @oh-my-pi/pi-coding-agent`.
#                           Bun is required because the omp wrapper is Bun-compiled.
#
# Build args:
#   OMPWEB_VERSION  @kahme247/ompweb version. Default: latest.
#   OMP_VERSION     @oh-my-pi/pi-coding-agent version. Default: 18.1.15.
#   BUN_VERSION     Bun runtime version. Default: 1.3.14 (omp requires >=1.3.14).
#   NODE_VERSION    Node.js runtime version. Default: 26-slim.

ARG NODE_VERSION=26-slim
ARG OMP_VERSION=18.1.15

# ---- Stage 1: install ompweb from npm ----
FROM node:${NODE_VERSION} AS ompweb-install
ARG OMPWEB_VERSION=latest
WORKDIR /app

# The npm tarball already contains a pre-built .next/ bundle (verified:
# tarball includes .next/BUILD_ID, .next/server, .next/static, etc.) so we
# just install the package + its runtime dependencies. --omit=dev skips the
# Next.js compilation toolchain that we no longer need.
RUN --mount=type=cache,target=/root/.npm \
    npm install --omit=dev --no-audit --no-fund \
        @kahme247/ompweb@${OMPWEB_VERSION}

# ---- Stage 2: runtime ----
FROM node:${NODE_VERSION} AS runtime

# tini for proper signal forwarding as PID 1; wget for the healthcheck;
# gosu for privilege drop in the entrypoint script; curl + unzip for Bun install.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        tini wget ca-certificates gosu curl unzip \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 1001 -r app \
    && useradd -u 1001 -r -g app -d /app -s /sbin/nologin app

# Install Bun — omp and the @oh-my-pi/pi-coding-agent package are
# Bun-compiled (uses bun:ffi, Bun.hash, Bun.inspect) and require the
# Bun runtime, not Node. The package's prepack script bundles cli.js;
# the binary at /usr/local/bin/omp is a Bun shim that calls into it.
ARG BUN_VERSION=1.3.14
ENV BUN_INSTALL=/usr/local/bun
RUN curl -fsSL "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-x64.zip" -o /tmp/bun.zip \
    && unzip -j /tmp/bun.zip 'bun-linux-x64/bun' -d /tmp/bun-extract \
    && mv /tmp/bun-extract/bun /usr/local/bin/bun \
    && chmod +x /usr/local/bin/bun \
    && rm -rf /tmp/bun.zip /tmp/bun-extract \
    && /usr/local/bin/bun --version
ENV PATH="/usr/local/bin:${PATH}"

# Install omp via Bun global. The `@oh-my-pi/pi-coding-agent` package
# bundles its own cli.js (prebuilt by the package's `prepack` script)
# and pulls in `@oh-my-pi/pi-natives-linux-x64` (the platform-specific
# native addons). `bun install -g` puts the wrapper at
# /usr/local/bun/bin/omp; we symlink to /usr/local/bin/omp for the
# OMP_WEB_OMP_BIN env var. --trust-all allows the natives package's
# postinstall script to extract its prebuilt .node files.
ARG OMP_VERSION
RUN --mount=type=cache,target=/root/.bun/install/cache \
    bun install --global --trust-all \
        @oh-my-pi/pi-coding-agent@${OMP_VERSION} \
    && ln -sf /usr/local/bun/bin/omp /usr/local/bin/omp \
    && test -x /usr/local/bin/omp || { echo "omp binary missing after bun install"; exit 1; } \
    && /usr/local/bin/omp --version

WORKDIR /app

# ompweb install (node_modules/ includes the prebuilt .next/ and bin/).
COPY --from=ompweb-install --chown=app:app /app/node_modules ./node_modules
COPY --from=ompweb-install --chown=app:app /app/package.json ./package.json
COPY --from=ompweb-install --chown=app:app /app/package-lock.json ./package-lock.json

# Entrypoint.
COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=30177 \
    OMP_WEB_HOSTNAME=0.0.0.0 \
    # Redirect omp's HOME-relative writes (~/.omp, ~/.local/share) into
    # the persistent volume. Without this, omp tries to mkdir /app/.omp
    # which is root-owned and EACCES for the app user.
    HOME=/data/omp \
    PI_CODING_AGENT_DIR=/data/omp \
    OMP_WEB_OMP_BIN=/usr/local/bin/omp \
    OMP_WEB_NO_OPEN=1 \
    OMP_PINNED_VERSION=${OMP_VERSION}

# NOTE: No `USER app` here. The entrypoint script runs as root (PID 1
# = tini, default root user) so it can mkdir /data/omp and chown it
# before dropping privileges via gosu. The compose file uses
# cap_drop: [ALL] + no-new-privileges to keep that root window safe.
EXPOSE 30177

# wget --spider succeeds on any HTTP response (200/404/etc.) so it's a robust
# liveness probe for the Next.js server, not a deep content check.
HEALTHCHECK --interval=30s --timeout=3s --start-period=30s --retries=3 \
  CMD wget --spider -q http://127.0.0.1:30177/ || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]