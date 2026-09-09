#!/bin/sh
# docker-entrypoint.sh — start ompweb inside the container.
#
# The upstream launcher (bin/omp-web.js) refuses to bind to a non-loopback
# interface unless --password is supplied. We re-implement that guard here
# so the failure mode is clean and discoverable before Next.js boots.

set -eu

HOST="${OMP_WEB_HOSTNAME:-0.0.0.0}"
PORT="${PORT:-30177}"
PASS="${OMP_WEB_PASSWORD:-}"
AGENT_DIR="${PI_CODING_AGENT_DIR:-/data/omp}"

if [ "$HOST" != "127.0.0.1" ] && [ -z "$PASS" ]; then
    echo "ERROR: OMP_WEB_PASSWORD must be set when OMP_WEB_HOSTNAME is not 127.0.0.1." >&2
    echo "       Set OMP_WEB_PASSWORD in your .env file (or bind to 127.0.0.1)." >&2
    exit 1
fi

# Ensure the persistent agent directory exists; omp refuses to start otherwise.
mkdir -p "$AGENT_DIR"

echo "Starting ompweb on ${HOST}:${PORT} (agent dir: ${AGENT_DIR})"

# shellcheck disable=SC2086
exec node ./node_modules/@kahme247/ompweb/bin/omp-web.js \
    --hostname "$HOST" \
    --port "$PORT" \
    --no-open \
    ${PASS:+--password "$PASS"} \
    "$@"