# syntax=docker/dockerfile:1
#
# Multi-stage build for ompweb + oh-my-pi (omp).
#
# Stage 1 (ompweb-deps): clone upstream ompweb and install full deps (incl. devDeps).
# Stage 2 (ompweb-build): run `next build` and prune devDeps so the runtime layer is small.
# Stage 3 (omp-bin):     download the static musl omp binary for linux/amd64.
# Stage 4 (runtime):     minimal node:22.19.0-alpine + tini + non-root app user.
#
# Build args:
#   OMPWEB_REF  Git ref (branch/tag/sha) of kahme247/ompweb to pin. Default: main.
#   OMP_VERSION Release tag of can1357/oh-my-pi to bundle. Default: latest (resolved at build time).
#   NODE_VERSION  Node.js runtime version (must match ompweb's .nvmrc pin). Default: 22.19.0.

ARG NODE_VERSION=22.19.0

# ---- Stage 1: install ompweb deps ----
FROM node:${NODE_VERSION}-alpine AS ompweb-deps
ARG OMPWEB_REF=main
WORKDIR /src

# git is needed to clone ompweb. ca-certificates for TLS to GitHub.
RUN apk add --no-cache git ca-certificates

# Shallow clone to keep the layer small.
RUN git clone --depth 1 --branch "${OMPWEB_REF}" --no-tags \
        https://github.com/kahme247/ompweb.git /src

# Run npm ci with BuildKit cache mount for faster rebuilds.
RUN --mount=type=cache,target=/root/.npm \
    --mount=type=cache,target=/src/.npm \
    npm ci --no-audit --no-fund

# ---- Stage 2: build ompweb ----
FROM node:${NODE_VERSION}-alpine AS ompweb-build
ARG OMPWEB_REF=main
WORKDIR /src

# Pull in the cloned source from stage 1.
COPY --from=ompweb-deps /src /src

ENV NEXT_TELEMETRY_DISABLED=1
ENV NODE_ENV=production

# Build the Next.js app, then strip devDependencies so the runtime layer is small.
RUN --mount=type=cache,target=/root/.npm \
    --mount=type=cache,target=/src/.next \
    npm run build \
    && npm prune --omit=dev --no-audit --no-fund

# ---- Stage 3: download the omp binary ----
FROM alpine:3.20 AS omp-bin
ARG OMP_VERSION=latest

RUN apk add --no-cache curl ca-certificates

# Resolve "latest" to the current release tag (strip the leading 'v' that GitHub uses).
RUN set -eux; \
    if [ "$OMP_VERSION" = "latest" ]; then \
        OMP_VERSION=$(curl -fsSL https://api.github.com/repos/can1357/oh-my-pi/releases/latest \
            | sed -nE 's/.*"tag_name":\s*"v?([^"]+)".*/\1/p' | head -n1); \
    fi; \
    echo "Resolved OMP_VERSION=${OMP_VERSION}"; \
    curl -fsSL -o /usr/local/bin/omp \
        "https://github.com/can1357/oh-my-pi/releases/download/v${OMP_VERSION}/omp-linux-musl-x64"; \
    chmod +x /usr/local/bin/omp; \
    /usr/local/bin/omp --version

# ---- Stage 4: runtime ----
FROM node:${NODE_VERSION}-alpine AS runtime

# tini for proper signal forwarding as PID 1; wget for the healthcheck.
RUN apk add --no-cache tini wget ca-certificates \
    && addgroup -g 1001 -S app \
    && adduser -S app -u 1001 -G app

WORKDIR /app

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=30177 \
    OMP_WEB_HOSTNAME=0.0.0.0 \
    PI_CODING_AGENT_DIR=/data/omp \
    OMP_WEB_OMP_BIN=/usr/local/bin/omp \
    OMP_WEB_NO_OPEN=1

# ompweb runtime artifacts.
COPY --from=ompweb-build --chown=app:app /src/node_modules ./node_modules
COPY --from=ompweb-build --chown=app:app /src/.next       ./.next
COPY --from=ompweb-build --chown=app:app /src/public       ./public
COPY --from=ompweb-build --chown=app:app /src/bin          ./bin
COPY --from=ompweb-build --chown=app:app /src/package.json ./package.json
COPY --from=ompweb-build --chown=app:app /src/next.config.ts ./next.config.ts

# omp binary.
COPY --from=omp-bin /usr/local/bin/omp /usr/local/bin/omp

# Entrypoint.
COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

USER app
EXPOSE 30177

# wget --spider succeeds on any HTTP response (200/404/etc.) so it's a robust
# liveness probe for the Next.js server, not a deep content check.
HEALTHCHECK --interval=30s --timeout=3s --start-period=30s --retries=3 \
  CMD wget --spider -q http://127.0.0.1:30177/ || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]