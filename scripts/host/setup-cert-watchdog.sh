#!/usr/bin/env bash
# setup-cert-watchdog.sh
# ---------------------------------------------------------------------------
# Install the 3DX Gateway TLS certificate watchdog as a systemd timer (Linux).
#
# Linux counterpart of scripts/host/setup-cert-watchdog.ps1. Same job, native
# mechanism: a oneshot .service driven by a .timer instead of a Scheduled Task.
#
# What it does:
#   1. Installs check-tls-cert.sh into <install-dir>/host/ (copies the sibling
#      if present, else fetches it from the public update repo -- the same
#      pattern install-helper.sh uses; unlike the Windows script it does not
#      embed a copy, because on Linux the installer always has network access
#      to the mirror it was itself fetched from).
#   2. Writes /etc/systemd/system/<name>-certwatch.{service,timer}, namespaced
#      by install slug exactly like <slug>.service, so parallel installs do not
#      collide.
#   3. Enables + starts the timer, then runs one --check-only pass so the
#      operator sees the current certificate state immediately.
#
# Why: Caddy's `tls internal` leaves live 12h and renew themselves, but only
# while Caddy can read its storage volume. A hard power cut can strand that
# storage -- Caddy then keeps serving a cached certificate it can no longer
# renew (site up, app 200) until it expires and every browser shows
# "Not secure". See docs/wiki/reference/deployment.md.
#
# Usage (root, on the gateway host):
#   bash setup-cert-watchdog.sh [--install-dir DIR] [--interval 4h]
#                               [--min-hours 2] [--container NAME] [--name NAME]
#                               [--hostname HOST] [--port N] [--log-file PATH]
#
# Also honours COMPOSE_DIR (like install-helper.sh) as the install dir.
#
# Defaults assume an install.sh-created stack: container <slug>-caddy, units
# <slug>-certwatch.*, hostname/port from <install-dir>/.env. For a stack it did
# not create, name them yourself -- e.g. the dev/staging deployment on dev01,
# which runs as compose project `bom-explorer` out of a git checkout:
#
#   bash setup-cert-watchdog.sh \
#     --install-dir /var/lib/3dx-certwatch/bom-explorer \
#     --container bom-explorer-caddy --name bom-explorer \
#     --hostname dev01.local.solfins.com --port 443
#
# Point --install-dir at a dedicated state dir there, not at the checkout: the
# script keeps its copy of check-tls-cert.sh and its log under it, and neither
# belongs in a working tree.
# ---------------------------------------------------------------------------

set -euo pipefail

PUBLIC_REPO_BASE="https://raw.githubusercontent.com/Solfins-dev/3dx-gateway-updates/main"

INSTALL_DIR="${COMPOSE_DIR:-/opt/3dx-gateway}"
INTERVAL="4h"
MIN_HOURS=2
CADDY_CONTAINER=""
UNIT_NAME=""
GATEWAY_HOST=""
PORT=""
LOG_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --interval)    INTERVAL="$2"; shift 2 ;;
        --min-hours)   MIN_HOURS="$2"; shift 2 ;;
        --container)   CADDY_CONTAINER="$2"; shift 2 ;;
        --name)        UNIT_NAME="$2"; shift 2 ;;
        --hostname)    GATEWAY_HOST="$2"; shift 2 ;;
        --port)        PORT="$2"; shift 2 ;;
        --log-file)    LOG_FILE="$2"; shift 2 ;;
        -h|--help)     sed -n '2,/^# ----/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)." >&2; exit 1; }
# A stack install.sh did not create has no install dir of its own; point
# --install-dir at a dedicated state dir (the check script keeps its copy and
# its log there) rather than at a git checkout you would rather not litter.
if [ ! -d "$INSTALL_DIR" ]; then
    mkdir -p "$INSTALL_DIR" || { echo "Could not create $INSTALL_DIR" >&2; exit 1; }
    echo "Created state dir $INSTALL_DIR"
fi

# Slug + container name derived exactly as install.sh derives them. Both are
# overridable because a stack install.sh did not create does not follow that
# convention: the dev/staging deployment on dev01 lives in a git checkout named
# `3dx-gateway` but runs under compose project `bom-explorer`, so the derived
# name would point at the wrong container -- or, worse, at another stack's.
SLUG=$(basename "$INSTALL_DIR" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' | sed 's/-\+/-/g; s/^-\|-$//g')
[ -n "$SLUG" ] || SLUG="3dx-gateway"
[ -n "$UNIT_NAME" ] || UNIT_NAME="$SLUG"
[ -n "$CADDY_CONTAINER" ] || CADDY_CONTAINER="${SLUG}-caddy"

if ! docker inspect "$CADDY_CONTAINER" >/dev/null 2>&1; then
    echo "Container '$CADDY_CONTAINER' not found. Pass --container with the right name." >&2
    docker ps --format '  running: {{.Names}}' | grep -i caddy >&2 || true
    exit 1
fi

# --- 1. Land the check script ------------------------------------------------
HOST_DIR="${INSTALL_DIR}/host"
mkdir -p "$HOST_DIR"
CHECK_DST="${HOST_DIR}/check-tls-cert.sh"
SIBLING="$(cd "$(dirname "$0")" && pwd)/check-tls-cert.sh"

if [ -f "$SIBLING" ] && [ "$SIBLING" != "$CHECK_DST" ]; then
    cp "$SIBLING" "$CHECK_DST"
    echo "Copied check script from $SIBLING"
else
    curl -fsSL "${PUBLIC_REPO_BASE}/scripts/host/check-tls-cert.sh" -o "$CHECK_DST" ||
        { echo "Failed to fetch check-tls-cert.sh from $PUBLIC_REPO_BASE" >&2; exit 1; }
    echo "Fetched check script into $CHECK_DST"
fi
chmod +x "$CHECK_DST"

# --- 2. systemd units --------------------------------------------------------
# Ordered after the stack's own unit when there is one, so a boot run happens
# once the stack is up. A compose-only deployment has no such unit; ordering on
# a non-existent unit is a silent no-op, but leaving it out keeps the unit
# honest about what it actually depends on.
after_units="docker.service"
if systemctl list-unit-files "${SLUG}.service" --no-legend 2>/dev/null | grep -q "${SLUG}.service"; then
    after_units="$after_units ${SLUG}.service"
fi

# Only pass what was explicitly given; anything omitted keeps the check
# script's own .env-driven defaults. Kept in BOTH forms deliberately: a string
# for the unit file, and an array for the inline pass below -- which must run
# with exactly the same arguments as the unit, or it would validate a different
# target than the one being installed.
extra_args=""
extra=()
if [ -n "$GATEWAY_HOST" ]; then extra_args="$extra_args --hostname ${GATEWAY_HOST}"; extra+=(--hostname "$GATEWAY_HOST"); fi
if [ -n "$PORT" ];         then extra_args="$extra_args --port ${PORT}";             extra+=(--port "$PORT"); fi
if [ -n "$LOG_FILE" ];     then extra_args="$extra_args --log-file ${LOG_FILE}";     extra+=(--log-file "$LOG_FILE"); fi

cat > "/etc/systemd/system/${UNIT_NAME}-certwatch.service" <<EOF
[Unit]
Description=3DX Gateway (${UNIT_NAME}) TLS certificate watchdog
Requires=docker.service
After=${after_units}

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash ${CHECK_DST} --install-dir ${INSTALL_DIR} --container ${CADDY_CONTAINER} --min-hours ${MIN_HOURS}${extra_args}
TimeoutStartSec=300
EOF

# OnBootSec covers the reboot that caused the damage in the first place;
# OnUnitActiveSec is the steady-state cadence. Persistent=true makes a missed
# run (host powered off) fire once after the next boot.
cat > "/etc/systemd/system/${UNIT_NAME}-certwatch.timer" <<EOF
[Unit]
Description=Run the 3DX Gateway (${UNIT_NAME}) TLS certificate watchdog every ${INTERVAL}

[Timer]
OnBootSec=5min
OnUnitActiveSec=${INTERVAL}
AccuracySec=1min
Persistent=true
Unit=${UNIT_NAME}-certwatch.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now "${UNIT_NAME}-certwatch.timer" >/dev/null
echo "Enabled ${UNIT_NAME}-certwatch.timer (every ${INTERVAL} + 5 min after boot)"

# --- 3. One inline read-only pass so the operator sees the current state ------
# --check-only never restarts, so this is safe mid-install. It exits 1 when
# something is already wrong: report it, but do not fail the setup over it.
echo ''
echo 'Current certificate state:'
set +e
bash "$CHECK_DST" --install-dir "$INSTALL_DIR" --container "$CADDY_CONTAINER" \
    --min-hours "$MIN_HOURS" ${extra[@]+"${extra[@]}"} --check-only
check_exit=$?
set -e

echo ''
if [ "$check_exit" -eq 0 ]; then
    echo "Done. The certificate is healthy and will be watched every ${INTERVAL}."
else
    echo "Done -- but the check above reported a problem."
    echo "Fix it now with:  docker restart ${CADDY_CONTAINER}"
    echo "(or let the timer do it at its next run)"
fi
echo ''
echo "Run on demand:      systemctl start ${UNIT_NAME}-certwatch.service"
echo "Next run:           systemctl list-timers ${UNIT_NAME}-certwatch.timer"
echo "Log:                journalctl -u ${UNIT_NAME}-certwatch.service -n 30"
echo "                    ${LOG_FILE:-${INSTALL_DIR}/certwatch.log}"
echo "Remove later with:  systemctl disable --now ${UNIT_NAME}-certwatch.timer && rm /etc/systemd/system/${UNIT_NAME}-certwatch.{service,timer} && systemctl daemon-reload"
