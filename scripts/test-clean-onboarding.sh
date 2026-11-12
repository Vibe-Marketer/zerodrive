#!/usr/bin/env bash
set -e

echo "==> Preparing clean test environment for ZeroDrive..."

# 1. Ensure live backup exists
mkdir -p "$HOME/.zerodrive-live-backup"
if [ -d "$HOME/.config/rclone" ]; then
    cp -a "$HOME/.config/rclone" "$HOME/.zerodrive-live-backup/"
fi

# 2. Unmount existing drive and terminate running app
/sbin/umount -f "$HOME/.zerodrive" 2>/dev/null || true
/sbin/umount -f "$HOME/.zerodrive-mount" 2>/dev/null || true
pkill -9 ZeroDrive 2>/dev/null || true
pkill -9 -f "rclone serve nfs" 2>/dev/null || true
sleep 1

# 3. Swap live config to safe staging location
if [ -d "$HOME/.config/rclone" ]; then
    rm -rf "$HOME/.config/rclone-saved-live"
    mv "$HOME/.config/rclone" "$HOME/.config/rclone-saved-live"
fi
mkdir -p "$HOME/.config/rclone"

echo "==> Launching ZeroDrive in 100% clean-room onboarding state..."
open /Applications/ZeroDrive.app
echo "✓ ZeroDrive is open! Test the brand-new onboarding, 1-click Cloudflare signup, and permissions."
echo "When finished testing, run: bash scripts/restore-live-account.sh"
