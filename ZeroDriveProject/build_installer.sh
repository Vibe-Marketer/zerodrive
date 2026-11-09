#!/usr/bin/env bash
# ==============================================================================
# ZeroDrive Build & DMG Installer Generation Script (v3.0 Production)
# Target OS: macOS 13.0 (Ventura) or newer (Universal Binary arm64 + x86_64)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

APP_NAME="ZeroDrive"
BUNDLE_ID="co.aisimple.zerodrive"
VERSION="3.0.0"
BUILD_DIR="${SCRIPT_DIR}/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DMG_NAME="ZeroDrive-Installer.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"
RCLONE_CACHE_DIR="${HOME}/.zerodrive-build-cache"
DEFAULT_DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
SIGN_IDENTITY="${SIGNING_IDENTITY:-${DEFAULT_DEV_ID:--}}"

echo "==> [1/6] Cleaning previous build artifacts..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

echo "==> [2/6] Acquiring official CGO-enabled rclone engine with nfsmount..."
mkdir -p "${RCLONE_CACHE_DIR}"
RCLONE_LOCAL_BIN="${RCLONE_CACHE_DIR}/rclone"

if [ ! -f "${RCLONE_LOCAL_BIN}" ]; then
  ARCH="$(uname -m)"
  if [ "${ARCH}" = "arm64" ]; then
    RCLONE_URL="https://downloads.rclone.org/rclone-current-osx-arm64.zip"
  else
    RCLONE_URL="https://downloads.rclone.org/rclone-current-osx-amd64.zip"
  fi
  echo "    Downloading official CGO rclone binary (${ARCH}) from ${RCLONE_URL}..."
  curl -fsSL "${RCLONE_URL}" -o "${RCLONE_CACHE_DIR}/rclone.zip"
  unzip -q -o "${RCLONE_CACHE_DIR}/rclone.zip" -d "${RCLONE_CACHE_DIR}"
  find "${RCLONE_CACHE_DIR}" -name "rclone" -type f -perm +111 -exec cp {} "${RCLONE_LOCAL_BIN}" \;
  chmod +x "${RCLONE_LOCAL_BIN}"
fi

# Verify bundled rclone supports nfsmount
echo "    Verifying bundled rclone binary supports 'nfsmount'..."
if ! "${RCLONE_LOCAL_BIN}" nfsmount --help >/dev/null 2>&1; then
  echo "ERROR: The acquired rclone binary does not support 'nfsmount' command."
  exit 1
fi
echo "    rclone nfsmount verified successfully!"
cp "${RCLONE_LOCAL_BIN}" "${APP_BUNDLE}/Contents/Resources/rclone"
chmod +x "${APP_BUNDLE}/Contents/Resources/rclone"

echo "==> [3/6] Compiling Swift sources into Universal Binary (arm64 + x86_64)..."
SWIFT_FILES=$(find Sources -name "*.swift")
ARM64_BIN="${BUILD_DIR}/${APP_NAME}-arm64"
X86_64_BIN="${BUILD_DIR}/${APP_NAME}-x86_64"

echo "    -> Compiling arm64-apple-macos13.0..."
swiftc -O \
  -target arm64-apple-macos13.0 \
  -parse-as-library \
  -framework SwiftUI \
  -framework AppKit \
  -framework Charts \
  -framework AVFoundation \
  -framework IOKit \
  -framework FileProvider \
  -o "${ARM64_BIN}" \
  ${SWIFT_FILES}

echo "    -> Compiling x86_64-apple-macos13.0..."
swiftc -O \
  -target x86_64-apple-macos13.0 \
  -parse-as-library \
  -framework SwiftUI \
  -framework AppKit \
  -framework Charts \
  -framework AVFoundation \
  -framework IOKit \
  -framework FileProvider \
  -o "${X86_64_BIN}" \
  ${SWIFT_FILES}

echo "    -> Merging architectures via lipo..."
lipo -create -output "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" "${ARM64_BIN}" "${X86_64_BIN}"
rm -f "${ARM64_BIN}" "${X86_64_BIN}"

echo "==> [4/6] Compiling embedded Finder Sync Extension (ZeroDriveFinderSync.appex) & copying Assets..."
if [ -f "Assets/Info.plist" ]; then
  cp "Assets/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
fi
if [ -f "Assets/AppIcon.icns" ]; then
  cp "Assets/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi
if [ -d "Assets/logos" ]; then
  cp -R Assets/logos/* "${APP_BUNDLE}/Contents/Resources/"
fi

if [ -f "FinderSyncExtension/ZeroDriveFinderSync.swift" ]; then
  APPEX_BUNDLE="${APP_BUNDLE}/Contents/PlugIns/ZeroDriveFinderSync.appex"
  mkdir -p "${APPEX_BUNDLE}/Contents/MacOS"
  cp "FinderSyncExtension/Info.plist" "${APPEX_BUNDLE}/Contents/Info.plist"

  swiftc -O \
    -target arm64-apple-macos13.0 \
    -parse-as-library \
    -module-name ZeroDriveFinderSync \
    -framework Cocoa \
    -framework FinderSync \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "${BUILD_DIR}/ZeroDriveFinderSync-arm64" \
    FinderSyncExtension/ZeroDriveFinderSync.swift

  swiftc -O \
    -target x86_64-apple-macos13.0 \
    -parse-as-library \
    -module-name ZeroDriveFinderSync \
    -framework Cocoa \
    -framework FinderSync \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "${BUILD_DIR}/ZeroDriveFinderSync-x86_64" \
    FinderSyncExtension/ZeroDriveFinderSync.swift

  lipo -create -output "${APPEX_BUNDLE}/Contents/MacOS/ZeroDriveFinderSync" \
    "${BUILD_DIR}/ZeroDriveFinderSync-arm64" \
    "${BUILD_DIR}/ZeroDriveFinderSync-x86_64"
  rm -f "${BUILD_DIR}/ZeroDriveFinderSync-arm64" "${BUILD_DIR}/ZeroDriveFinderSync-x86_64"
fi

if [ -f "ZeroDriveFileProvider/file-provider-extension.swift" ]; then
  echo "    -> Compiling Apple FileProvider Extension (ZeroDriveFileProvider.appex)..."
  FP_BUNDLE="${APP_BUNDLE}/Contents/PlugIns/ZeroDriveFileProvider.appex"
  mkdir -p "${FP_BUNDLE}/Contents/MacOS"
  cp "ZeroDriveFileProvider/Info.plist" "${FP_BUNDLE}/Contents/Info.plist"

  FP_SWIFT_FILES=$(find ZeroDriveFileProvider -name "*.swift")

  swiftc -O \
    -target arm64-apple-macos13.0 \
    -parse-as-library \
    -module-name ZeroDriveFileProvider \
    -framework Cocoa \
    -framework FileProvider \
    -framework UniformTypeIdentifiers \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "${BUILD_DIR}/ZeroDriveFileProvider-arm64" \
    ${FP_SWIFT_FILES}

  swiftc -O \
    -target x86_64-apple-macos13.0 \
    -parse-as-library \
    -module-name ZeroDriveFileProvider \
    -framework Cocoa \
    -framework FileProvider \
    -framework UniformTypeIdentifiers \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "${BUILD_DIR}/ZeroDriveFileProvider-x86_64" \
    ${FP_SWIFT_FILES}

  lipo -create -output "${FP_BUNDLE}/Contents/MacOS/ZeroDriveFileProvider" \
    "${BUILD_DIR}/ZeroDriveFileProvider-arm64" \
    "${BUILD_DIR}/ZeroDriveFileProvider-x86_64"
  rm -f "${BUILD_DIR}/ZeroDriveFileProvider-arm64" "${BUILD_DIR}/ZeroDriveFileProvider-x86_64"
fi

echo "==> [5/6] Code signing ZeroDrive.app with identity: ${SIGN_IDENTITY}..."
ENTITLEMENTS_FLAG=""
if [ -f "Assets/Entitlements.plist" ]; then
  ENTITLEMENTS_FLAG="--entitlements Assets/Entitlements.plist"
fi

TIMESTAMP_FLAG=""
if [ "${SIGN_IDENTITY}" != "-" ]; then
  TIMESTAMP_FLAG="--timestamp"
fi

if [ -d "${APP_BUNDLE}/Contents/PlugIns/ZeroDriveFinderSync.appex" ]; then
  codesign --force ${TIMESTAMP_FLAG} --options runtime \
    --entitlements FinderSyncExtension/Entitlements.plist \
    --sign "${SIGN_IDENTITY}" \
    "${APP_BUNDLE}/Contents/PlugIns/ZeroDriveFinderSync.appex"
fi

if [ -d "${APP_BUNDLE}/Contents/PlugIns/ZeroDriveFileProvider.appex" ]; then
  codesign --force ${TIMESTAMP_FLAG} --options runtime \
    --entitlements ZeroDriveFileProvider/Entitlements.plist \
    --sign "${SIGN_IDENTITY}" \
    "${APP_BUNDLE}/Contents/PlugIns/ZeroDriveFileProvider.appex"
fi

codesign --force ${TIMESTAMP_FLAG} --options runtime ${ENTITLEMENTS_FLAG} --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}/Contents/Resources/rclone"
codesign --force ${TIMESTAMP_FLAG} --options runtime ${ENTITLEMENTS_FLAG} --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"

echo "==> [6/6] Generating drag-and-drop ZeroDrive-Installer.dmg..."
DMG_TEMP_DIR="${BUILD_DIR}/dmg_staging"
mkdir -p "${DMG_TEMP_DIR}"
cp -R "${APP_BUNDLE}" "${DMG_TEMP_DIR}/"
ln -s /Applications "${DMG_TEMP_DIR}/Applications"

hdiutil create -volname "ZeroDrive Installer" \
  -srcfolder "${DMG_TEMP_DIR}" \
  -size 250m \
  -ov -format UDZO \
  "${DMG_PATH}"

rm -rf "${DMG_TEMP_DIR}"

if [ "${SIGN_IDENTITY}" != "-" ]; then
  codesign --force ${TIMESTAMP_FLAG} --sign "${SIGN_IDENTITY}" "${DMG_PATH}"
fi

echo "=============================================================================="
echo " BUILD SUCCESSFUL!"
echo " Universal Binary Verified: $(lipo -archs "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}")"
echo " DMG Created: ${DMG_PATH}"
echo " Install to Mac: Open ${DMG_PATH} and drag ZeroDrive to /Applications"
echo "=============================================================================="
