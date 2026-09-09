# syntax=docker/dockerfile:1
#
# Multi-stage build for ompweb + oh-my-pi (omp).
#
# Stage 1 (ompweb-install): `npm install @kahme247/ompweb` — its published tarball
#                           ships .next/ pre-built (see the package's `prepack` script),
#                           so we skip next build entirely.
# Stage 2 (omp-bin):        Download the static glibc `omp` binary for linux/amd64
#                           from GitHub releases. The @oh-my-pi/pi-coding-agent npm
#                           package is Bun-required source code, not a CLI tarball.
# Stage 3 (runtime):        Minimal node:26-slim + tini + non-root app user.
#
# Build args:
#   OMPWEB_VERSION  @kahme247/ompweb version. Default: latest.
#   OMP_VERSION     can1357/oh-my-pi release tag. Default: latest (resolved at build time).
#   NODE_VERSION    Node.js runtime. Default: 26-slim (rolling latest 26.x).

ARG NODE_VERSION=26-slim

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

# ---- Stage 2: download the omp binary ----
FROM alpine:3.20 AS omp-bin
ARG OMP_VERSION=latest

RUN apk add --no-cache curl ca-certificates

# Resolve "latest" to the current release tag (strip the leading 'v' that GitHub
# uses), then download the glibc-compiled linux/amd64 binary. Validate via the
# ELF magic-byte check (not execution) — this stage never runs the binary, so
# the host libc doesn't matter. The Debian runtime stage is where omp runs.
RUN set -eux; \
    if [ "$OMP_VERSION" = "latest" ]; then \
        OMP_VERSION=$(curl -fsSL https://api.github.com/repos/can1357/oh-my-pi/releases/latest \
            | sed -nE 's/.*"tag_name":\s*"v?([^"]+)".*/\1/p' | head -n1); \
    fi; \
    echo "Resolved OMP_VERSION=${OMP_VERSION}"; \
    curl -fsSL -o /usr/local/bin/omp \
        "https://github.com/can1357/oh-my-pi/releases/download/v${OMP_VERSION}/omp-linux-x64"; \
    chmod +x /usr/local/bin/omp; \
    # Validate the file is a 64-bit ELF executable — catches 404 HTML pages,
    # empty responses, and partial downloads in one shot.
    head -c 4 /usr/local/bin/omp | grep -q "ELF" || { echo "omp binary failed ELF magic check"; exit 1; }; \
    SIZE=$(stat -c %s /usr/local/bin/omp); \
    echo "omp binary ready: ${SIZE} bytes"

# ---- Stage 3: runtime ----
FROM node:${NODE_VERSION} AS runtime

# tini for proper signal forwarding as PID 1; wget for the healthcheck;
# su-exec for privilege drop in the entrypoint script.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        tini wget ca-certificates su-exec \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 1001 -r app \
    && useradd -u 1001 -r -g app -d /app -s /sbin/nologin app

WORKDIR /app

# ompweb install (node_modules/ includes the prebuilt .next/ and bin/).
COPY --from=ompweb-install --chown=app:app /app/node_modules ./node_modules
COPY --from=ompweb-install --chown=app:app /app/package.json ./package.json
COPY --from=ompweb-install --chown=app:app /app/package-lock.json ./package-lock.json

# omp binary.
COPY --from=omp-bin /usr/local/bin/omp /usr/local/bin/omp

# Entrypoint.
COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=30177 \
    OMP_WEB_HOSTNAME=0.0.0.0 \
    PI_CODING_AGENT_DIR=/data/omp \
    OMP_WEB_OMP_BIN=/usr/local/bin/omp \
    OMP_WEB_NO_OPEN=1

USER app
EXPOSE 30177

# wget --spider succeeds on any HTTP response (200/404/etc.) so it's a robust
# liveness probe for the Next.js server, not a deep content check.
HEALTHCHECK --interval=30s --timeout=3s --start-period=30s --retries=3 \
  CMD wget --spider -q http://127.0.0.1:30177/ || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]