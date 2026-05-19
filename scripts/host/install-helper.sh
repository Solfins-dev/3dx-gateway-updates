#!/usr/bin/env bash
# Install the 3DX Gateway updater helper (Apply Update one-click backend update).
#
# Run on the host (NOT inside the gateway container) as root:
#   sudo bash scripts/host/install-helper.sh
#
# After this, the gateway container can apply updates one-click from the
# Settings → Updates card (admin role). Without the helper installed the
# Apply Update endpoint returns 503 and the UI falls back to the
# copy-SSH-command path.
#
# Defaults to /opt/3dx-gateway (the canonical customer install location).
# To install against a different compose directory, set COMPOSE_DIR and
# (optionally) COMPOSE_FILES explicitly:
#
#   sudo COMPOSE_DIR=/opt/3dx-gateway-customerB \
#        COMPOSE_FILES="docker-compose.yml docker-compose.tls.yml docker-compose.helper.yml" \
#        bash install-helper.sh
#
# Refuses to install against a directory that does not look like a 3dx-gateway
# customer install (no docker-compose.yml, or compose.yml references a
# non-gateway image) unless --force is passed. This guard exists because the
# helper operates on a SINGLE global socket; pointing it at the wrong stack
# turns Apply Update into "destroy unrelated stack" (real incident 2026-05-18).

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Re-running with sudo..."
    exec sudo bash "$0" "$@"
fi

#─── Flags ──────────────────────────────────────────────────────────────────

FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -h|--help)
            sed -n '2,21p' "$0"
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $arg" >&2
            echo "Usage: sudo bash $0 [--force]" >&2
            exit 2
            ;;
    esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-/opt/3dx-gateway}"

#─── Validation ─────────────────────────────────────────────────────────────

echo "[1/6] Validating compose directory..."
if [[ ! -d "$COMPOSE_DIR" ]]; then
    cat >&2 <<EOF
ERROR: COMPOSE_DIR ($COMPOSE_DIR) does not exist.

The helper must be installed against an existing 3dx-gateway customer
install directory. Either:

  (a) Install the gateway first via 'install.sh' (creates /opt/3dx-gateway), then
      re-run this helper installer, OR
  (b) Set COMPOSE_DIR to point at an existing install:
        sudo COMPOSE_DIR=/path/to/3dx-gateway bash $0
EOF
    exit 1
fi

# install.sh writes docker-compose.yml. We also accept the legacy
# docker-compose.prod.yml for backwards compatibility with installs from
# before 2026-05-15. Bail loudly if neither is present.
COMPOSE_FILE_FOUND=""
for candidate in docker-compose.yml docker-compose.prod.yml; do
    if [[ -f "$COMPOSE_DIR/$candidate" ]]; then
        COMPOSE_FILE_FOUND="$candidate"
        break
    fi
done

if [[ -z "$COMPOSE_FILE_FOUND" ]] && [[ $FORCE -eq 0 ]]; then
    cat >&2 <<EOF
ERROR: $COMPOSE_DIR does not contain docker-compose.yml.

This does not look like a 3dx-gateway install directory. Refusing to wire
the global Apply Update helper to it -- the helper operates on a single
global socket, and pointing it at the wrong stack means "docker compose
pull + up" runs against the wrong containers (real incident 2026-05-18).

If you are sure this is intentional (e.g. dev environment with a non-
standard layout), re-run with --force.
EOF
    exit 1
fi

# Sniff for the gateway image reference. If COMPOSE_FILES is set, sniff
# each file; otherwise the single compose file we found.
if [[ -n "${COMPOSE_FILES:-}" ]]; then
    SNIFF_FILES="$COMPOSE_FILES"
else
    SNIFF_FILES="$COMPOSE_FILE_FOUND"
fi
GATEWAY_IMAGE_RE='solfins-dev/3dx-gateway'
LOOKS_LIKE_GATEWAY=0
for f in $SNIFF_FILES; do
    if [[ -f "$COMPOSE_DIR/$f" ]] && grep -q "$GATEWAY_IMAGE_RE" "$COMPOSE_DIR/$f" 2>/dev/null; then
        LOOKS_LIKE_GATEWAY=1
        break
    fi
done

if [[ $LOOKS_LIKE_GATEWAY -eq 0 ]] && [[ $FORCE -eq 0 ]]; then
    cat >&2 <<EOF
ERROR: $COMPOSE_DIR/$COMPOSE_FILE_FOUND does not reference the
ghcr.io/solfins-dev/3dx-gateway image.

This looks like a different project's compose stack (dev clone? unrelated
container set?). Refusing to install the Apply Update helper against it --
the helper would run "docker compose pull + up -d" against THIS stack on
every UI click. If a 3dx-gateway customer install elsewhere shares the
helper socket (unavoidable today, single /run/3dx-gateway-helper.sock per
host), an Apply Update click in that customer install would tear down
THIS stack as collateral damage.

If you understand the risk and want to proceed anyway, re-run with --force.
See [[reference-helper-single-socket-shared-stacks]] for the architectural
context.
EOF
    exit 1
fi

echo "    OK: $COMPOSE_DIR (compose=$COMPOSE_FILE_FOUND, gateway-image=$([[ $LOOKS_LIKE_GATEWAY -eq 1 ]] && echo yes || echo no/forced))"

#─── Install ────────────────────────────────────────────────────────────────

echo "[2/6] Installing helper script to /usr/local/bin..."
install -m 0755 -o root -g root \
    "$HERE/3dx-gateway-helper.sh" \
    /usr/local/bin/3dx-gateway-helper.sh

echo "[3/6] Installing systemd units..."
install -m 0644 -o root -g root \
    "$HERE/3dx-gateway-helper.socket" \
    /etc/systemd/system/3dx-gateway-helper.socket
install -m 0644 -o root -g root \
    "$HERE/3dx-gateway-helper@.service" \
    /etc/systemd/system/3dx-gateway-helper@.service

# Write a drop-in so the per-connection service inherits COMPOSE_DIR + (if
# the operator overrode them) COMPOSE_FILES from whatever was set at install
# time. We ALWAYS write a drop-in now (even for the canonical /opt path)
# because the helper's runtime default (docker-compose.yml, no overlays)
# would miss .tls.yml + .helper.yml on a TLS-enabled install.

# Derive COMPOSE_FILES if not set: pick up the standard overlay files that
# exist in COMPOSE_DIR, matching what install.sh writes.
if [[ -z "${COMPOSE_FILES:-}" ]] && [[ -z "${COMPOSE_FILE:-}" ]]; then
    DERIVED_FILES="$COMPOSE_FILE_FOUND"
    for overlay in docker-compose.tls.yml docker-compose.helper.yml; do
        [[ -f "$COMPOSE_DIR/$overlay" ]] && DERIVED_FILES="$DERIVED_FILES $overlay"
    done
    COMPOSE_FILES="$DERIVED_FILES"
    echo "    Derived COMPOSE_FILES=\"$COMPOSE_FILES\""
fi

echo "[4/6] Writing /etc/systemd/system/3dx-gateway-helper@.service.d/override.conf..."
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

echo "[5/6] Creating state directory /var/lib/3dx-gateway-helper..."
install -d -m 0755 -o root -g root /var/lib/3dx-gateway-helper

echo "[6/6] Enabling socket activation..."
systemctl daemon-reload
systemctl enable --now 3dx-gateway-helper.socket

echo
echo "✓ Helper installed."
echo
echo "Smoke test (should print {\"ok\":true,...}):"
echo "  printf 'PING\\n' | sudo socat - UNIX-CONNECT:/run/3dx-gateway-helper.sock"
echo
echo "Compose directory: $COMPOSE_DIR"
echo "Compose files:     ${COMPOSE_FILES:-${COMPOSE_FILE:-docker-compose.yml (default)}}"
echo "State directory:   /var/lib/3dx-gateway-helper"
echo "Socket:            /run/3dx-gateway-helper.sock (0666, root:root)"
echo
echo "To wire the gateway container to this socket, layer the helper overlay:"
echo
echo "  cd $COMPOSE_DIR"
echo "  docker compose -f $COMPOSE_FILE_FOUND -f docker-compose.helper.yml up -d"
echo
echo "Settings → Updates → Apply Update will then be one-click for admins."
