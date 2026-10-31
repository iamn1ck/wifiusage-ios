#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <iphone-ip-or-host> [ssh-port]"
    echo "Example: $0 192.168.1.50 22"
    exit 1
fi

DEVICE_HOST="$1"
DEVICE_PORT="${2:-22}"
SSH_USER="${SSH_USER:-mobile}"
REMOTE_DIR="/var/jb/var/mobile/wifi-usage"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Copying project to ${SSH_USER}@${DEVICE_HOST}:${REMOTE_DIR} ..."
ssh -p "$DEVICE_PORT" "${SSH_USER}@${DEVICE_HOST}" "mkdir -p ${REMOTE_DIR}"
scp -P "$DEVICE_PORT" -r \
    "${PROJECT_DIR}/Makefile" \
    "${PROJECT_DIR}/control" \
    "${PROJECT_DIR}/layout" \
    "${PROJECT_DIR}/wifiusaged" \
    "${PROJECT_DIR}/WiFiUsagePrefs" \
    "${SSH_USER}@${DEVICE_HOST}:${REMOTE_DIR}/"

echo "==> Building package on device..."
ssh -p "$DEVICE_PORT" "${SSH_USER}@${DEVICE_HOST}" "export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:\$PATH; \
    export THEOS=\${THEOS:-/var/jb/theos}; \
    cd ${REMOTE_DIR} && \
    make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless"

echo "==> Build complete! To install on the device, run:"
echo "    ssh -p ${DEVICE_PORT} root@${DEVICE_HOST} 'dpkg -i ${REMOTE_DIR}/packages/*.deb && killall Preferences 2>/dev/null || true'"

