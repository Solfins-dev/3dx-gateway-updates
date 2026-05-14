#!/usr/bin/env bash
# Install the 3DX Gateway updater helper — ADR-015 Phase 2(a).
#
# Run on the host (NOT inside the gateway container) as root:
#   sudo bash scripts/host/install-helper.sh
#
# After this, the gateway container can apply updates one-click from the
# Settings → Updates card (admin role). Without the helper installed the
# Apply Update endpoint returns 503 and the UI falls back to the
# copy-SSH-command path.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Re-running with sudo..."
    exec sudo bash "$0" "$@"
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-/opt/3dx-gateway}"

echo "[1/5] Validating compose directory..."
if [[ ! -d "$COMPOSE_DIR" ]]; then
    echo "ERROR: \$COMPOSE_DIR ($COMPOSE_DIR) does not exist."
    echo "Set COMPOSE_DIR to the directory containing docker-compose.prod.yml and retry:"
    echo "  sudo COMPOSE_DIR=/path/to/3dx-gateway bash $0"
    exit 1
fi
if [[ ! -f "$COMPOSE_DIR/docker-compose.prod.yml" ]]; then
    echo "WARNING: $COMPOSE_DIR/docker-compose.prod.yml not found."
    echo "The helper will fail at apply time if this file is missing. Proceeding anyway."
fi

echo "[2/5] Installing helper script to /usr/local/bin..."
install -m 0755 -o root -g root \
    "$HERE/3dx-gateway-helper.sh" \
    /usr/local/bin/3dx-gateway-helper.sh

echo "[3/5] Installing systemd units..."
install -m 0644 -o root -g root \
    "$HERE/3dx-gateway-helper.socket" \
    /etc/systemd/system/3dx-gateway-helper.socket
install -m 0644 -o root -g root \
    "$HERE/3dx-gateway-helper@.service" \
    /etc/systemd/system/3dx-gateway-helper@.service

# Write a drop-in so the per-connection service inherits COMPOSE_DIR + (if
# the operator overrode them) COMPOSE_FILES from whatever was set at install
# time. Without this, the helper defaults to /opt/3dx-gateway and
# docker-compose.prod.yml.
NEED_DROPIN=0
[[ "$COMPOSE_DIR" != "/opt/3dx-gateway" ]] && NEED_DROPIN=1
[[ -n "${COMPOSE_FILES:-}" ]] && NEED_DROPIN=1
[[ -n "${COMPOSE_FILE:-}" ]] && NEED_DROPIN=1

if [[ "$NEED_DROPIN" -eq 1 ]]; then
    mkdir -p /etc/systemd/system/3dx-gateway-helper@.service.d
    {
        echo "[Service]"
        # systemd's Environment= parser space-splits the right-hand side
        # into multiple assignments unless the whole KEY=VALUE is quoted.
        # That bites COMPOSE_FILES specifically since the value is itself
        # space-separated. Always wrap in double quotes — harmless for
        # single-token values, essential for multi-token ones.
        echo "Environment=\"COMPOSE_DIR=$COMPOSE_DIR\""
        [[ -n "${COMPOSE_FILES:-}" ]] && echo "Environment=\"COMPOSE_FILES=$COMPOSE_FILES\""
        [[ -n "${COMPOSE_FILE:-}" ]]  && echo "Environment=\"COMPOSE_FILE=$COMPOSE_FILE\""
    } > /etc/systemd/system/3dx-gateway-helper@.service.d/override.conf
fi

echo "[4/5] Creating state directory /var/lib/3dx-gateway-helper..."
install -d -m 0755 -o root -g root /var/lib/3dx-gateway-helper

echo "[5/5] Enabling socket activation..."
systemctl daemon-reload
systemctl enable --now 3dx-gateway-helper.socket

echo
echo "✓ Helper installed."
echo
echo "Smoke test (should print {\"ok\":true,...}):"
echo "  printf 'PING\\n' | sudo socat - UNIX-CONNECT:/run/3dx-gateway-helper.sock"
echo
echo "Compose directory: $COMPOSE_DIR"
echo "Compose files:     ${COMPOSE_FILES:-${COMPOSE_FILE:-docker-compose.prod.yml (default)}}"
echo "State directory:   /var/lib/3dx-gateway-helper"
echo "Socket:            /run/3dx-gateway-helper.sock (0666, root:root)"
echo
echo "To wire the gateway container to this socket, layer the overlay file"
echo "shipped alongside docker-compose.prod.yml:"
echo
echo "  cd $COMPOSE_DIR"
echo "  docker compose -f docker-compose.prod.yml -f docker-compose.helper.yml up -d"
echo
echo "Settings → Updates → Apply Update will then be one-click for admins."
