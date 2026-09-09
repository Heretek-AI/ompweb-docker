#!/bin/sh
# docker-entrypoint.sh — start ompweb inside the container.
#
# Runs as root (PID 1 = tini, which execs this script). It performs
# setup work that requires root — primarily creating the persistent
# agent directory in the named volume, which Docker creates as
# root-owned — then drops privileges via su-exec and execs the actual
# ompweb launcher as the non-root app user (UID 1001).

set -eu

# Force directories to be group-readable/writable so the app user can
# access them. Without this, the inherited umask 077 leaves dirs at
# mode 700 — which blocks even root from re-chowning on subsequent
# runs (cap_drop: ALL removes DAC_OVERRIDE).
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

# Named volumes mount root-owned on first use. omp (UID 1001) needs to
# write here at runtime, so we create the directory and chown it to
# the app user. Idempotent on subsequent runs.
mkdir -p "$AGENT_DIR"
chmod 0755 "$AGENT_DIR"  # ensure root can re-chown if omp sets 0700 inside
chown -R 1001:1001 "$AGENT_DIR"

echo "Starting ompweb on ${HOST}:${PORT} (agent dir: ${AGENT_DIR})"

# Drop privileges and exec the launcher. `exec` is critical so signals
# reach Node, not this shell. gosu is the standard Debian equivalent of
# su-exec (no PAM, no env-stripping).
# shellcheck disable=SC2086
exec gosu 1001:1001 node ./node_modules/@kahme247/ompweb/bin/omp-web.js \
    --hostname "$HOST" \
    --port "$PORT" \
    --no-open \
    ${PASS:+--password "$PASS"} \
    "$@"