#!/bin/sh
# docker-entrypoint.sh — start ompweb inside the container.
#
# Runs as UID 1001 (the Dockerfile sets USER 1001:1001; the container
# never runs as root). The persistent volume is pre-owned by UID 1001
# because the image ships /data/omp owned by 1001 and Docker copies it
# into a fresh named volume on first mount — so no chown/gosu needed
# and no special capabilities are required at runtime.

set -eu

# Force group-readable dirs in case a file got a restrictive mode.
umask 0022

HOST="${OMP_WEB_HOSTNAME:-0.0.0.0}"
PORT="${PORT:-30177}"
PASS="${OMP_WEB_PASSWORD:-}"
AGENT_DIR="${PI_CODING_AGENT_DIR:-/data/omp}"

if [ "$HOST" != "127.0.0.1" ] && [ -z "$PASS" ]; then
    echo "ERROR: OMP_WEB_PASSWORD must be set when OMP_WEB_HOSTNAME is not 127.0.0.1." >&2
    echo "       Set OMP_WEB_PASSWORD in your .env file (or bind to 127.0.0.1)." >&2
    exit 1
fi

# Ensure the agent dir exists (no-op if the volume was seeded from the
# image). UID 1001 owns it, so this always succeeds.
mkdir -p "$AGENT_DIR"

# Seed custom OpenAI-compatible provider config from OMP_PROVIDER_* env
# vars, if all required fields are set. Idempotent: never clobbers an
# existing models.yml or config.yml (manual edits survive restarts).
# Use ${VAR:-} defaults throughout so set -u doesn't abort on the unset
# case (the [ -n ] checks below still short-circuit correctly).
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
        echo "Seeded $MODELS_FILE for custom provider '${OMP_PROVIDER_LABEL}'"
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<EOF
modelRoles:
  default: ${DEFAULT_MODEL}
EOF
        echo "Seeded $CONFIG_FILE with default model '${DEFAULT_MODEL}'"
    fi
fi

echo "Starting ompweb on ${HOST}:${PORT} (agent dir: ${AGENT_DIR})"

# shellcheck disable=SC2086
exec node ./node_modules/@kahme247/ompweb/bin/omp-web.js \
    --hostname "$HOST" \
    --port "$PORT" \
    --no-open \
    ${PASS:+--password "$PASS"} \
    "$@"