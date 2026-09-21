#!/usr/bin/env bash
# docker-entrypoint.sh — remap UID/GID, authorize the Docker socket, seed
# persistent volumes, then drop privileges and run the ompweb launcher.
#
# Starts as root (the image has no USER directive) because PUID/PGID remapping
# and the socket group join need it. Every user-facing process is started via
# `gosu omp:omp`.

set -euo pipefail

OMP_USER=omp
OMP_HOME=/home/omp
DOCKER_SOCK=/var/run/docker.sock
LOG_PREFIX=ompweb:

log() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }
warn() { printf '%s %s\n' "$LOG_PREFIX" "WARNING: $*" >&2; }

WORKSPACE="${OMP_DEFAULT_CWD:-/workspace}"
AGENT_DIR="${PI_CODING_AGENT_DIR:-$OMP_HOME/.omp/agent}"
HOST="${OMP_WEB_HOSTNAME:-0.0.0.0}"
PORT="${PORT:-3000}"

# ---- 1. GID/PUID remap --------------------------------------------------
if [ -n "${PGID:-}" ] && [ "$PGID" != "$(id -g "$OMP_USER")" ]; then
    if getent group "$PGID" >/dev/null; then
        existing_group="$(getent group "$PGID" | cut -d: -f1)"
        log "PGID ${PGID} already exists as group '${existing_group}'; pointing ${OMP_USER} at it"
        usermod -g "$existing_group" "$OMP_USER"
    else
        log "remapping ${OMP_USER} group to GID ${PGID}"
        groupmod -g "$PGID" "$OMP_USER"
    fi
fi

if [ -n "${PUID:-}" ] && [ "$PUID" != "$(id -u "$OMP_USER")" ]; then
    if getent passwd "$PUID" >/dev/null; then
        warn "UID ${PUID} is already taken by user '$(getent passwd "$PUID" | cut -d: -f1)'; skipping PUID remap"
    else
        log "remapping ${OMP_USER} user to UID ${PUID}"
        usermod -u "$PUID" "$OMP_USER"
    fi
fi

# ---- 2. Docker socket group --------------------------------------------
if [ -S "$DOCKER_SOCK" ]; then
    SOCK_GID="$(stat -c '%g' "$DOCKER_SOCK")"
    if getent group "$SOCK_GID" >/dev/null; then
        sock_group="$(getent group "$SOCK_GID" | cut -d: -f1)"
    else
        sock_group=docker
        groupadd -g "$SOCK_GID" "$sock_group"
    fi
    usermod -aG "$sock_group" "$OMP_USER"
    log "joined group '${sock_group}' (gid ${SOCK_GID}) for ${DOCKER_SOCK}"
else
    log "docker socket not mounted; skipping docker group"
fi

# ---- 3. Directories + ownership ----------------------------------------
# /home/omp/.ssh is deliberately excluded: compose mounts it read-only and a
# recursive chown there would fail (and `set -e` would abort the start). The
# home directory itself is chowned non-recursively for the same reason.
mkdir -p "$WORKSPACE" "$OMP_HOME" "$OMP_HOME/.omp" "$OMP_HOME/.config" "$AGENT_DIR"
chown "$OMP_USER:$OMP_USER" "$OMP_HOME"
chown -R "$OMP_USER:$OMP_USER" "$WORKSPACE" "$OMP_HOME/.omp" "$OMP_HOME/.config"
chmod 0755 "$WORKSPACE"

# ---- 4. Seed the workspace registry ------------------------------------
# Exactly the ProjectRegistryFile shape lib/project-registry.ts parses; the
# bind-mounted volume makes this survive restarts and it never overwrites
# user edits.
PROJECTS_FILE="$AGENT_DIR/projects.json"
if [ ! -f "$PROJECTS_FILE" ]; then
    cat > "$PROJECTS_FILE" <<EOF
{
  "version": 1,
  "projects": [
    {
      "path": "${WORKSPACE}",
      "addedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
      "hidden": false,
      "alias": "workspace"
    }
  ]
}
EOF
    chown "$OMP_USER:$OMP_USER" "$PROJECTS_FILE"
    log "seeded workspace registry ${PROJECTS_FILE} → ${WORKSPACE}"
fi

# ---- 5. Seed a custom OpenAI-compatible provider ------------------------
# Idempotent: never clobbers existing models.yml / config.yml. Fields match
# docs/models.md (providers.<label>.baseUrl/api/apiKey/models[].id/name and
# config.yml modelRoles.default).
if [ -n "${OMP_PROVIDER_LABEL:-}" ] && [ -n "${OMP_PROVIDER_BASE_URL:-}" ] \
   && [ -n "${OMP_PROVIDER_API_KEY:-}" ] && [ -n "${OMP_PROVIDER_MODEL_ID:-}" ]; then
    MODELS_FILE="$AGENT_DIR/models.yml"
    CONFIG_FILE="$AGENT_DIR/config.yml"
    DISPLAY_NAME="${OMP_PROVIDER_MODEL_NAME:-${OMP_PROVIDER_MODEL_ID}}"
    DEFAULT_MODEL="${OMP_DEFAULT_MODEL:-${OMP_PROVIDER_LABEL}/${OMP_PROVIDER_MODEL_ID}}"
    API_TYPE="${OMP_PROVIDER_API:-openai-completions}"

    if [ ! -f "$MODELS_FILE" ]; then
        cat > "$MODELS_FILE" <<EOF
providers:
  ${OMP_PROVIDER_LABEL}:
    baseUrl: ${OMP_PROVIDER_BASE_URL}
    api: ${API_TYPE}
    apiKey: ${OMP_PROVIDER_API_KEY}
    models:
      - id: ${OMP_PROVIDER_MODEL_ID}
        name: ${DISPLAY_NAME}
EOF
        chown "$OMP_USER:$OMP_USER" "$MODELS_FILE"
        log "seeded ${MODELS_FILE} for custom provider '${OMP_PROVIDER_LABEL}'"
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<EOF
modelRoles:
  default: ${DEFAULT_MODEL}
EOF
        chown "$OMP_USER:$OMP_USER" "$CONFIG_FILE"
        log "seeded ${CONFIG_FILE} with default model '${DEFAULT_MODEL}'"
    fi
fi

# ---- 6. Engine probe ----------------------------------------------------
if [ -f /opt/omp/VERSION ]; then
    log "omp engine $(cat /opt/omp/VERSION)"
fi
if ! version_output="$(timeout 60 gosu "$OMP_USER:$OMP_USER" omp --version 2>&1)"; then
    warn "omp binary failed to run: ${version_output}"
    exit 1
fi
log "omp reports: ${version_output}"

# ---- 7. Optional sidecar -----------------------------------------------
# The password / non-loopback rule is intentionally not re-implemented here:
# bin/omp-web.js refuses on its own and exits 1.
SIDECAR_PID=""
if [ -n "${OMP_SIDECAR_CMD:-}" ]; then
    log "starting sidecar: ${OMP_SIDECAR_CMD}"
    HOME="$OMP_HOME" \
    PI_ROOT=/opt/omp/pi \
    OMP_WEB_OMP_BIN=/usr/local/bin/omp \
    PI_CODING_AGENT_DIR="$AGENT_DIR" \
    gosu "$OMP_USER:$OMP_USER" sh -lc "$OMP_SIDECAR_CMD" 2>&1 \
      | sed -u "s/^/sidecar | /" &
    SIDECAR_PID=$!
    trap 'if [ -n "$SIDECAR_PID" ]; then kill "$SIDECAR_PID" 2>/dev/null || true; fi' EXIT INT TERM
fi

# ---- 8. Drop and exec ---------------------------------------------------
cd /app/ompweb
log "starting ompweb on ${HOST}:${PORT}; workspace ${WORKSPACE}; agent dir ${AGENT_DIR}"
exec gosu "$OMP_USER:$OMP_USER" node bin/omp-web.js \
    --hostname "$HOST" \
    --port "$PORT" \
    --no-open
