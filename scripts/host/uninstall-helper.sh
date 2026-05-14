#!/usr/bin/env bash
# Uninstall the 3DX Gateway updater helper.
#   sudo bash scripts/host/uninstall-helper.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi

echo "Disabling socket..."
systemctl disable --now 3dx-gateway-helper.socket 2>/dev/null || true

echo "Removing units..."
rm -f /etc/systemd/system/3dx-gateway-helper.socket
rm -f /etc/systemd/system/3dx-gateway-helper@.service
rm -rf /etc/systemd/system/3dx-gateway-helper@.service.d
systemctl daemon-reload

echo "Removing script..."
rm -f /usr/local/bin/3dx-gateway-helper.sh

echo "Removing state (logs + status file)..."
rm -rf /var/lib/3dx-gateway-helper

echo "✓ Helper uninstalled. The socket bind-mount in docker-compose.prod.yml"
echo "  is harmless if left in place (the mount target just doesn't exist),"
echo "  but you can clean it up too."
