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
mkdir -p "${CACHE_DIR}" "${CACHE_DIR}/nfs-handles"
rm -f "${CACHE_DIR}/vfs/ZeroDriveUnified/.metadata_never_index" "${CACHE_DIR}/vfsMeta/ZeroDriveUnified/.metadata_never_index"

echo "==> Spawning rclone nfsmount on ZeroDriveUnified: -> ${MOUNT_POINT}"
exec "${RCLONE_BIN}" nfsmount ZeroDriveUnified: "${MOUNT_POINT}" \
  --volname="ZeroDrive" \
  --nfs-cache-type=disk \
  --nfs-cache-dir="${CACHE_DIR}/nfs-handles" \
  --vfs-cache-mode=full \
  --cache-dir="${CACHE_DIR}" \
  --vfs-cache-max-size=50G \
  --vfs-write-back=5s \
  --vfs-cache-max-age=24h \
  --vfs-read-chunk-size=16M \
  --vfs-read-chunk-size-limit=256M \
  --buffer-size=32M \
  --dir-cache-time=20s \
  --use-server-modtime \
  --disable-http2 \
  --s3-disable-http2 \
  --transfers=4 \
  --s3-upload-cutoff=32M \
  --s3-chunk-size=8M \
  --s3-upload-concurrency=2 \
  --allow-non-empty \
  --noappledouble=true \
  --noapplexattr=true \
  --exclude="**/node_modules/**" \
  --exclude="**/target/**" \
  --exclude="**/.venv/**" \
  --exclude="**/.git/objects/pack/**" \
  --exclude="**/.DS_Store" \
  --exclude="**/._*" \
  --exclude="**/.nfs*" \
  --rc \
  --rc-addr="127.0.0.1:55729" \
  --rc-no-auth
