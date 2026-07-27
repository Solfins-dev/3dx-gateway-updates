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
#   2. Writes /etc/systemd/system/<slug>-certwatch.{service,timer}, namespaced
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
#                               [--min-hours 2]
#
# Also honours COMPOSE_DIR (like install-helper.sh) as the install dir.
# ---------------------------------------------------------------------------

set -euo pipefail

PUBLIC_REPO_BASE="https://raw.githubusercontent.com/Solfins-dev/3dx-gateway-updates/main"

INSTALL_DIR="${COMPOSE_DIR:-/opt/3dx-gateway}"
INTERVAL="4h"
MIN_HOURS=2

while [ $# -gt 0 ]; do
    case "$1" in
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --interval)    INTERVAL="$2"; shift 2 ;;
        --min-hours)   MIN_HOURS="$2"; shift 2 ;;
        -h|--help)     sed -n '2,/^# ----/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)." >&2; exit 1; }
[ -d "$INSTALL_DIR" ] || { echo "Install dir not found: $INSTALL_DIR" >&2; exit 1; }

# Slug + container name derived exactly as install.sh derives them.
SLUG=$(basename "$INSTALL_DIR" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' | sed 's/-\+/-/g; s/^-\|-$//g')
[ -n "$SLUG" ] || SLUG="3dx-gateway"
CADDY_CONTAINER="${SLUG}-caddy"

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
# Ordered After=<slug>.service so a boot run happens once the stack is up.
# Failure of the check must not mark the boot degraded beyond this unit, hence
# no Restart= and a plain oneshot.
cat > "/etc/systemd/system/${SLUG}-certwatch.service" <<EOF
[Unit]
Description=3DX Gateway (${SLUG}) TLS certificate watchdog
Requires=docker.service
After=docker.service ${SLUG}.service

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash ${CHECK_DST} --install-dir ${INSTALL_DIR} --container ${CADDY_CONTAINER} --min-hours ${MIN_HOURS}
TimeoutStartSec=300
EOF

# OnBootSec covers the reboot that caused the damage in the first place;
# OnUnitActiveSec is the steady-state cadence. Persistent=true makes a missed
# run (host powered off) fire once after the next boot.
cat > "/etc/systemd/system/${SLUG}-certwatch.timer" <<EOF
[Unit]
Description=Run the 3DX Gateway (${SLUG}) TLS certificate watchdog every ${INTERVAL}

[Timer]
OnBootSec=5min
OnUnitActiveSec=${INTERVAL}
AccuracySec=1min
Persistent=true
Unit=${SLUG}-certwatch.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now "${SLUG}-certwatch.timer" >/dev/null
echo "Enabled ${SLUG}-certwatch.timer (every ${INTERVAL} + 5 min after boot)"

# --- 3. One inline read-only pass so the operator sees the current state ------
# --check-only never restarts, so this is safe mid-install. It exits 1 when
# something is already wrong: report it, but do not fail the setup over it.
echo ''
echo 'Current certificate state:'
set +e
bash "$CHECK_DST" --install-dir "$INSTALL_DIR" --container "$CADDY_CONTAINER" \
    --min-hours "$MIN_HOURS" --check-only
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
echo "Run on demand:      systemctl start ${SLUG}-certwatch.service"
echo "Next run:           systemctl list-timers ${SLUG}-certwatch.timer"
echo "Log:                journalctl -u ${SLUG}-certwatch.service -n 30"
echo "                    ${INSTALL_DIR}/certwatch.log"
echo "Remove later with:  systemctl disable --now ${SLUG}-certwatch.timer && rm /etc/systemd/system/${SLUG}-certwatch.{service,timer} && systemctl daemon-reload"
