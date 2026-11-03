#!/usr/bin/env bash
# ==============================================================================
# ZeroDrive Terminal Mount Script
# macOS Kernel NFSv3 Loopback Mount
# ==============================================================================
set -euo pipefail

RCLONE_BIN="/Applications/ZeroDrive.app/Contents/Resources/rclone"
MOUNT_POINT="${HOME}/ZeroDrive"
CACHE_DIR="${HOME}/.zerodrive-cache"

echo "==> Cleaning stale NFS mounts..."
/usr/sbin/diskutil unmount force "${MOUNT_POINT}" 2>/dev/null || true
/sbin/umount -f "${MOUNT_POINT}" 2>/dev/null || true

mkdir -p "${MOUNT_POINT}"
mkdir -p "${CACHE_DIR}"
touch "${MOUNT_POINT}/.metadata_never_index"

echo "==> Spawning rclone nfsmount on ZeroDriveUnified: -> ${MOUNT_POINT}"
exec "${RCLONE_BIN}" nfsmount ZeroDriveUnified: "${MOUNT_POINT}" \
  --volname="ZeroDrive" \
  --vfs-cache-mode=writes \
  --cache-dir="${CACHE_DIR}" \
  --vfs-cache-max-size=50G \
  --vfs-write-back=15s \
  --vfs-cache-max-age=1m \
  --vfs-read-chunk-size=8M \
  --vfs-read-chunk-size-limit=128M \
  --buffer-size=32M \
  --vfs-read-ahead=64M \
  --dir-cache-time=9999h \
  --attr-timeout=24h \
  --allow-non-empty \
  --noappledouble=true \
  --noapplexattr=true \
  --exclude="**/node_modules/**" \
  --exclude="**/target/**" \
  --exclude="**/.venv/**" \
  --exclude="**/.git/objects/pack/**" \
  --exclude="**/.DS_Store" \
  --exclude=".metadata_never_index" \
  --rc \
  --rc-addr="127.0.0.1:55729" \
  --rc-no-auth
