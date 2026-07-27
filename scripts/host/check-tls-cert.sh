#!/usr/bin/env bash
# check-tls-cert.sh
# ---------------------------------------------------------------------------
# TLS certificate watchdog for the 3DX Gateway Caddy container (Linux).
#
# Linux port of scripts/host/check-tls-cert.ps1. Same contract, same two
# checks; systemd timer instead of a Scheduled Task, openssl instead of
# SslStream.
#
# Why it exists (delmiaworks04, Windows, 2026-07-03 -> 2026-07-27): an unclean
# shutdown lost the leaf's PRIVATE KEY out of the caddy_data volume. Caddy did
# not crash -- it kept serving the certificate already in its in-memory cache,
# so the site stayed up and the app answered 200, while every renewal failed
# with "open /data/caddy/certificates/local/<host>/<host>.key: no such file or
# directory" every 600s. ~8h later the cached leaf expired and every browser
# showed "Not secure" -- unnoticed for 23 days, because the only signal was a
# log line. `docker restart` rebuilt the store and issued a fresh leaf.
#
# On Linux the trigger is rarer than on Windows (volumes sit directly on the
# host filesystem, and `systemctl stop docker` SIGTERMs containers on a normal
# reboot -- no WSL2 VHDX that Windows Update can tear down), but a hard power
# cut can strand the same state. The cost of watching is one TLS handshake and
# one `docker exec ls` every few hours.
#
# Checks BOTH the symptom and the cause:
#   1. Expiry  -- the leaf actually served on the wire, i.e. exactly what a
#                 browser sees. Restart when less than --min-hours remains.
#   2. Storage -- the private key backing that leaf still exists in the volume.
#                 The leading indicator: catches the corruption hours BEFORE
#                 the cached certificate expires, so the repair lands while the
#                 site is still healthy and nobody sees a warning.
#
# Output goes to stdout (captured by the journal when run from the timer) and
# is appended to <install-dir>/certwatch.log.
#
# Usage:
#   check-tls-cert.sh [--install-dir DIR] [--container NAME] [--min-hours N]
#                     [--hostname HOST] [--port N] [--log-file PATH]
#                     [--check-only]
#
# --hostname/--port default to HOSTNAME/APP_PORT in <install-dir>/.env, which is
# what install.sh writes. Pass them explicitly for a stack it did not create
# (a plain compose deployment): there is no .env to read them from, and
# `hostname -f` is not a safe guess -- on dev01 it returns the short name.
# ---------------------------------------------------------------------------

# NOT `set -e`: every failure here is handled explicitly and must still reach
# the logging + exit-code logic below.
set -uo pipefail

INSTALL_DIR="${COMPOSE_DIR:-/opt/3dx-gateway}"
CADDY_CONTAINER=""
MIN_HOURS=2
CHECK_ONLY=0
GATEWAY_HOST=""
PORT=""
LOG_FILE=""
# Whether host/port came from flags. When BOTH did, .env is not needed at all
# and its absence must not produce a warning on every single run -- that is the
# normal case for a stack that install.sh did not create (a compose deployment
# out of a git checkout, say).
HOST_FROM_FLAG=0
PORT_FROM_FLAG=0

while [ $# -gt 0 ]; do
    case "$1" in
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --container)   CADDY_CONTAINER="$2"; shift 2 ;;
        --min-hours)   MIN_HOURS="$2"; shift 2 ;;
        --hostname)    GATEWAY_HOST="$2"; HOST_FROM_FLAG=1; shift 2 ;;
        --port)        PORT="$2"; PORT_FROM_FLAG=1; shift 2 ;;
        --log-file)    LOG_FILE="$2"; shift 2 ;;
        --check-only)  CHECK_ONLY=1; shift ;;
        -h|--help)     sed -n '2,/^# ----/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

# Default alongside the install dir; --log-file exists because that dir is not
# always a place you want to write into (e.g. a git checkout, where a stray
# certwatch.log shows up as an untracked file).
[ -n "$LOG_FILE" ] || LOG_FILE="${INSTALL_DIR}/certwatch.log"

log() {
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S')  [tls-watchdog] $*"
    echo "$line"
    # The redirect must be inside the group: a FAILED redirect is reported by
    # the shell itself before the command runs, so `>> file 2>/dev/null` still
    # prints "Permission denied" and `|| true` cannot suppress it. That happens
    # on every manual run by a non-root operator (the log lives in the install
    # dir, which is root-owned) and made a working check look broken.
    { echo "$line" >> "$LOG_FILE"; } 2>/dev/null || true
}

# --- Read the install's own settings out of .env -----------------------------
# Parsed line by line on purpose -- NEVER `source` it: it holds
# POSTGRES_PASSWORD / CONFIG_PROTECTOR_SEED, and its HOSTNAME key would clobber
# the shell's own HOSTNAME.
TLS_MODE="auto"
ENV_FILE="${INSTALL_DIR}/.env"
NEED_ENV=1
if [ "$HOST_FROM_FLAG" -eq 1 ] && [ "$PORT_FROM_FLAG" -eq 1 ]; then NEED_ENV=0; fi
if [ -r "$ENV_FILE" ]; then
    [ -n "$GATEWAY_HOST" ] || GATEWAY_HOST=$(sed -n 's/^[[:space:]]*HOSTNAME[[:space:]]*=[[:space:]]*\(.*\)$/\1/p' "$ENV_FILE" | head -n 1)
    [ -n "$PORT" ]         || PORT=$(sed -n 's/^[[:space:]]*APP_PORT[[:space:]]*=[[:space:]]*\([0-9]\+\).*$/\1/p' "$ENV_FILE" | head -n 1)
    tls_from_env=$(sed -n 's/^[[:space:]]*TLS_MODE[[:space:]]*=[[:space:]]*\([^[:space:]]\+\).*$/\1/p' "$ENV_FILE" | head -n 1)
    [ -n "$tls_from_env" ] && TLS_MODE="$tls_from_env"
elif [ "$NEED_ENV" -eq 1 ] && [ -f "$ENV_FILE" ]; then
    # .env is 0600 root-owned (it holds POSTGRES_PASSWORD). The timer runs as
    # root and reads it fine; a manual run by an operator does not, so say so
    # plainly instead of leaking a raw `sed: Permission denied` to stderr.
    log "WARN: $ENV_FILE is not readable as $(id -un); pass --hostname/--port (or re-run with sudo)."
elif [ "$NEED_ENV" -eq 1 ]; then
    log "WARN: $ENV_FILE not found; relying on flags/defaults."
fi
[ -n "$GATEWAY_HOST" ] || GATEWAY_HOST=$(hostname -f 2>/dev/null || hostname)
[ -n "$PORT" ] || PORT=443
if [ -z "$CADDY_CONTAINER" ]; then
    # Same namespacing install.sh uses: <slug>-caddy, slug = basename(install dir).
    CADDY_CONTAINER="$(basename "$INSTALL_DIR")-caddy"
fi

if [ "$TLS_MODE" = "none" ]; then
    log "TLS_MODE=none (no Caddy certificate to watch). Nothing to do."
    exit 0
fi

if ! command -v openssl >/dev/null 2>&1; then
    log "ERROR: openssl not found -- cannot inspect the served certificate. Install openssl."
    exit 1
fi

log "=== check begin (host=$GATEWAY_HOST port=$PORT container=$CADDY_CONTAINER minHours=$MIN_HOURS) ==="

# --- 1. What is actually served on the wire ----------------------------------
# Connect over loopback but send the real hostname as SNI (-servername), so
# Caddy hands back the same leaf a LAN browser gets. Validation is irrelevant
# here: we want to INSPECT the certificate, expired or not.
served_not_after() {
    echo | timeout 15 openssl s_client -connect "127.0.0.1:${PORT}" \
        -servername "$GATEWAY_HOST" 2>/dev/null |
        openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2-
}

not_after=$(served_not_after)
if [ -z "$not_after" ]; then
    log "ERROR: cannot complete a TLS handshake on 127.0.0.1:${PORT}."
    log "       Caddy is not listening -- check 'systemctl status $(basename "$INSTALL_DIR")' and"
    log "       'docker ps'. No restart attempted."
    exit 1
fi

not_after_epoch=$(date -d "$not_after" +%s 2>/dev/null)
if [ -z "$not_after_epoch" ]; then
    log "ERROR: could not parse the certificate end date '$not_after'."
    exit 1
fi
now_epoch=$(date +%s)
remaining_h=$(( (not_after_epoch - now_epoch) / 3600 ))
log "served leaf: NotAfter='${not_after}' remaining=${remaining_h}h"

expiry_bad=0
if [ "$remaining_h" -lt "$MIN_HOURS" ]; then
    expiry_bad=1
    if [ "$remaining_h" -lt 0 ]; then
        log "PROBLEM: certificate EXPIRED $(( -remaining_h ))h ago -- browsers are showing 'Not secure'."
    else
        log "PROBLEM: certificate expires in ${remaining_h}h (threshold ${MIN_HOURS}h) and has not been renewed."
    fi
fi

# --- 2. Is the key that backs it still in the volume? ------------------------
# The leading indicator. Issuer-agnostic glob: 'local' for `tls internal`, an
# acme-v02 directory for Let's Encrypt.
store_bad=0
docker_ok=1
if ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
    docker_ok=0
    log "WARN: cannot reach the Docker engine as $(id -un) -- skipping the key-file check."
else
    key_glob="/data/caddy/certificates/*/${GATEWAY_HOST}/${GATEWAY_HOST}.key"
    found=$(docker exec "$CADDY_CONTAINER" sh -c "ls ${key_glob} 2>/dev/null | head -n 1" 2>/dev/null)
    if [ -z "$found" ]; then
        store_bad=1
        log "PROBLEM: private key missing from the volume (${key_glob})."
        log "         Caddy is serving a cached certificate it can no longer renew -- this is the"
        log "         2026-07 delmiaworks04 failure, caught before the cached cert expires."
    else
        log "stored key present: $found"
    fi
fi

if [ "$expiry_bad" -eq 0 ] && [ "$store_bad" -eq 0 ]; then
    log "OK: certificate healthy and backed by the volume. No action."
    log "=== check end ==="
    exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    log "--check-only: a restart of '$CADDY_CONTAINER' is what would fix this. Not restarting."
    log "=== check end ==="
    exit 1
fi

# --- 3. Repair: restart Caddy ------------------------------------------------
# On startup Caddy re-reads its storage and runs certificate maintenance
# immediately, reissuing anything expired or missing. Cost is a few seconds of
# refused connections on :443 -- far cheaper than the alternative.
if [ "$docker_ok" -eq 0 ]; then
    log "ERROR: repair needed but the Docker engine is unreachable from this account. Run manually:"
    log "       docker restart $CADDY_CONTAINER"
    log "=== check end ==="
    exit 1
fi

log "restarting $CADDY_CONTAINER ..."
if ! docker restart "$CADDY_CONTAINER" >/dev/null 2>&1; then
    log "ERROR: 'docker restart $CADDY_CONTAINER' failed. Manual intervention required."
    log "=== check end ==="
    exit 1
fi

# Wait for the listener to come back, then re-inspect. Verifying the FIX is the
# point: a restart that silently produced another bad cert must still be loud.
new_not_after=""
for _ in $(seq 1 30); do
    sleep 3
    new_not_after=$(served_not_after)
    [ -n "$new_not_after" ] && break
done
if [ -z "$new_not_after" ]; then
    log "ERROR: :${PORT} did not answer within 90s after the restart. Check 'docker logs $CADDY_CONTAINER'."
    log "=== check end ==="
    exit 1
fi

new_epoch=$(date -d "$new_not_after" +%s 2>/dev/null)
new_remaining_h=$(( (new_epoch - $(date +%s)) / 3600 ))
log "new leaf: NotAfter='${new_not_after}' remaining=${new_remaining_h}h"

if [ "$new_remaining_h" -lt "$MIN_HOURS" ]; then
    log "ERROR: still below the threshold after a restart. Caddy cannot issue a certificate --"
    log "       inspect 'docker logs $CADDY_CONTAINER' (disk full, read-only volume, bad Caddyfile)."
    log "=== check end ==="
    exit 1
fi

log "FIXED: fresh certificate issued and served."
log "=== check end ==="
exit 0
