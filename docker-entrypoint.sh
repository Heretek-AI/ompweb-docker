#!/bin/sh
# docker-entrypoint.sh — start ompweb inside the container.
#
# Runs as root (PID 1 = tini, which execs this script). It performs
# setup work that requires root — primarily creating the persistent
# agent directory in the named volume, which Docker creates as
# root-owned — then drops privileges via su-exec and execs the actual
# ompweb launcher as the non-root app user (UID 1001).

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

# Named volumes mount root-owned on first use. omp (UID 1001) needs to
# write here at runtime, so we create the directory and chown it to
# the app user. Idempotent on subsequent runs.
mkdir -p "$AGENT_DIR"
chown -R 1001:1001 "$AGENT_DIR"

echo "Starting ompweb on ${HOST}:${PORT} (agent dir: ${AGENT_DIR})"

# Drop privileges and exec the launcher. `exec` is critical so signals
# reach Node, not this shell. su-exec is a minimal setuid wrapper (no
# PAM, no env-stripping) — lighter than gosu.
# shellcheck disable=SC2086
exec su-exec 1001:1001 node ./node_modules/@kahme247/ompweb/bin/omp-web.js \
    --hostname "$HOST" \
    --port "$PORT" \
    --no-open \
    ${PASS:+--password "$PASS"} \
    "$@"