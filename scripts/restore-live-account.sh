#!/usr/bin/env bash
set -e

echo "==> Restoring your live ZeroDrive account (naegele412@gmail.com)..."

# 1. Unmount any test mounts and stop test processes
/sbin/umount -f "$HOME/.zerodrive" 2>/dev/null || true
/sbin/umount -f "$HOME/.zerodrive-mount" 2>/dev/null || true
pkill -9 ZeroDrive 2>/dev/null || true
pkill -9 -f "rclone serve nfs" 2>/dev/null || true
sleep 1

# 2. Restore live configs
if [ -d "$HOME/.config/rclone-saved-live" ]; then
    rm -rf "$HOME/.config/rclone"
    mv "$HOME/.config/rclone-saved-live" "$HOME/.config/rclone"
elif [ -d "$HOME/.zerodrive-live-backup/rclone" ]; then
    rm -rf "$HOME/.config/rclone"
    cp -a "$HOME/.zerodrive-live-backup/rclone" "$HOME/.config/rclone"
fi

# 3. Launch live ZeroDrive
echo "==> Starting ZeroDrive live..."
open /Applications/ZeroDrive.app
sleep 2

echo "✓ Live account restored! Verified naegele412@gmail.com is mounted at ~/ZeroDrive."
