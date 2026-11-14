#!/usr/bin/env bash
# ==============================================================================
# ZeroDrive Build & DMG Installer Generation Script (v3.0 Production)
# Target OS: macOS 13.0 (Ventura) or newer (Native Apple Silicon arm64)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

APP_NAME="ZeroDrive"
BUNDLE_ID="co.aisimple.zerodrive"
DEFAULT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "Assets/Info.plist" 2>/dev/null || echo "3.0.0")
DEFAULT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "Assets/Info.plist" 2>/dev/null || echo "1")

VERSION="${DEFAULT_VERSION}"
BUILD_NUMBER="${DEFAULT_BUILD}"
RELEASE_NOTES_JSON=""
RELEASE_NOTES_MD="../release-notes.md"
BUILD_DIR="${SCRIPT_DIR}/build"
SKIP_NOTARIZE=0
UPDATE_SOURCE_PLISTS=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --release-notes-json)
      RELEASE_NOTES_JSON="$2"
      shift 2
      ;;
    --release-notes-md)
      RELEASE_NOTES_MD="$2"
      shift 2
      ;;
    --output-dir)
      BUILD_DIR="$2"
      shift 2
      ;;
    --skip-notarize)
      SKIP_NOTARIZE=1
      shift
      ;;
    --update-source-plists)
      UPDATE_SOURCE_PLISTS=1
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DMG_NAME="ZeroDrive-Installer.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"
ZIP_NAME="ZeroDrive-macOS-${VERSION}.zip"
ZIP_PATH="${BUILD_DIR}/${ZIP_NAME}"
RCLONE_CACHE_DIR="${HOME}/.zerodrive-build-cache"
DEFAULT_DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
SIGN_IDENTITY="${SIGNING_IDENTITY:-${DEFAULT_DEV_ID:--}}"

set_plist_version() {
  local plist_path="$1"
  if [ -f "${plist_path}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${plist_path}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${plist_path}"
  fi
}

echo "==> [1/7] Cleaning previous build artifacts (version ${VERSION}, build ${BUILD_NUMBER})..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

echo "==> [2/6] Acquiring official CGO-enabled rclone engine with nfsmount..."
mkdir -p "${RCLONE_CACHE_DIR}"
RCLONE_LOCAL_BIN="${RCLONE_CACHE_DIR}/rclone"

if [ ! -f "${RCLONE_LOCAL_BIN}" ] || ! file "${RCLONE_LOCAL_BIN}" | grep -q "arm64"; then
  RCLONE_URL="https://downloads.rclone.org/rclone-current-osx-arm64.zip"
  echo "    Downloading official CGO rclone binary (arm64) from ${RCLONE_URL}..."
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

echo "==> [3/6] Compiling Swift sources into Native Apple Silicon Binary (arm64)..."
SWIFT_FILES=()
while IFS= read -r line; do
  SWIFT_FILES+=("$line")
done < <(find Sources -name "*.swift")

echo "    -> Compiling arm64-apple-macos13.0..."
swiftc -O \
  -target arm64-apple-macos13.0 \
  -parse-as-library \
  -framework SwiftUI \
  -framework AppKit \
  -framework Charts \
  -framework AVFoundation \
  -framework IOKit \
  -framework CryptoKit \
  -framework FileProvider \
  -o "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" \
  "${SWIFT_FILES[@]}"

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

if [ -f "../bin/zerodrive" ]; then
  cp "../bin/zerodrive" "${APP_BUNDLE}/Contents/Resources/zerodrive"
  chmod +x "${APP_BUNDLE}/Contents/Resources/zerodrive"
fi
if [ -f "../bin/zerodrive-mcp" ]; then
  cp "../bin/zerodrive-mcp" "${APP_BUNDLE}/Contents/Resources/zerodrive-mcp"
  chmod +x "${APP_BUNDLE}/Contents/Resources/zerodrive-mcp"
fi
if [ -d "../_SKILLS" ]; then
  rm -rf "${APP_BUNDLE}/Contents/Resources/_SKILLS"
  cp -R "../_SKILLS" "${APP_BUNDLE}/Contents/Resources/_SKILLS"
fi
if [ -n "${RELEASE_NOTES_JSON}" ] && [ -f "${RELEASE_NOTES_JSON}" ]; then
  cp "${RELEASE_NOTES_JSON}" "${APP_BUNDLE}/Contents/Resources/release-notes.json"
fi
if [ -f "${RELEASE_NOTES_MD}" ]; then
  cp "${RELEASE_NOTES_MD}" "${APP_BUNDLE}/Contents/Resources/release-notes.md"
  if [ ! -f "${APP_BUNDLE}/Contents/Resources/release-notes.json" ] && command -v node >/dev/null 2>&1 && [ -f "../deploy/releases.js" ]; then
    node -e '
      const fs = require("fs");
      const { parseReleaseNotesMarkdown } = require("../deploy/releases.js");
      const md = fs.readFileSync(process.argv[1], "utf8");
      const parsed = parseReleaseNotesMarkdown(md);
      fs.writeFileSync(process.argv[2], JSON.stringify(parsed, null, 2));
    ' "${RELEASE_NOTES_MD}" "${APP_BUNDLE}/Contents/Resources/release-notes.json"
  fi
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
    -o "${APPEX_BUNDLE}/Contents/MacOS/ZeroDriveFinderSync" \
    FinderSyncExtension/ZeroDriveFinderSync.swift
fi

if [ "${ENABLE_LEGACY_FILEPROVIDER:-0}" = "1" ] && [ -f "ZeroDriveFileProvider/file-provider-extension.swift" ]; then
  echo "    -> Compiling Apple FileProvider Extension (ZeroDriveFileProvider.appex)..."
  FP_BUNDLE="${APP_BUNDLE}/Contents/PlugIns/ZeroDriveFileProvider.appex"
  mkdir -p "${FP_BUNDLE}/Contents/MacOS"
  cp "ZeroDriveFileProvider/Info.plist" "${FP_BUNDLE}/Contents/Info.plist"

  FP_SWIFT_FILES=()
  while IFS= read -r line; do
    FP_SWIFT_FILES+=("$line")
  done < <(find ZeroDriveFileProvider -name "*.swift")

  swiftc -O \
    -target arm64-apple-macos13.0 \
    -parse-as-library \
    -module-name ZeroDriveFileProvider \
    -framework Cocoa \
    -framework FileProvider \
    -framework UniformTypeIdentifiers \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "${FP_BUNDLE}/Contents/MacOS/ZeroDriveFileProvider" \
    "${FP_SWIFT_FILES[@]}"
fi

echo "==> [5/7] Stamping Info.plist versions (${VERSION} / ${BUILD_NUMBER}) & Code signing ZeroDrive.app with identity: ${SIGN_IDENTITY}..."
set_plist_version "${APP_BUNDLE}/Contents/Info.plist"
set_plist_version "${APP_BUNDLE}/Contents/PlugIns/ZeroDriveFinderSync.appex/Contents/Info.plist"
if [ -f "${APP_BUNDLE}/Contents/PlugIns/ZeroDriveFileProvider.appex/Contents/Info.plist" ]; then
  set_plist_version "${APP_BUNDLE}/Contents/PlugIns/ZeroDriveFileProvider.appex/Contents/Info.plist"
fi

if [ "${UPDATE_SOURCE_PLISTS}" -eq 1 ]; then
  set_plist_version "Assets/Info.plist"
  set_plist_version "FinderSyncExtension/Info.plist"
  set_plist_version "ZeroDriveFileProvider/Info.plist"
fi

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

echo "    Verifying strict bundle signature..."
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

notarize_artifact() {
  local artifact_path="$1"
  if [ "${SKIP_NOTARIZE}" -eq 1 ] || [ "${SIGN_IDENTITY}" = "-" ]; then
    return 1
  fi
  if [ -z "${NOTARY_PROFILE:-}" ]; then
    for candidate in "AC_PASSWORD" "zerodrive-notary" "everdrive-notary"; do
      if xcrun notarytool history --keychain-profile "${candidate}" >/dev/null 2>&1; then
        NOTARY_PROFILE="${candidate}"
        break
      fi
    done
  fi
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "    Submitting ${artifact_path} for notarization (Keychain profile: ${NOTARY_PROFILE})..."
    xcrun notarytool submit "${artifact_path}" --keychain-profile "${NOTARY_PROFILE}" --wait
    return 0
  elif [ -n "${ASC_KEY_PATH:-}" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
    echo "    Submitting ${artifact_path} for notarization (App Store Connect API key)..."
    xcrun notarytool submit "${artifact_path}" --key "${ASC_KEY_PATH}" --key-id "${ASC_KEY_ID}" --issuer "${ASC_ISSUER_ID}" --wait
    return 0
  elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
    echo "    Submitting ${artifact_path} for notarization (Apple ID)..."
    xcrun notarytool submit "${artifact_path}" --apple-id "${APPLE_ID}" --password "${APPLE_APP_SPECIFIC_PASSWORD}" --team-id "${APPLE_TEAM_ID}" --wait
    return 0
  fi
  return 1
}

echo "==> [6/7] Creating signed macOS auto-update ZIP (${ZIP_NAME})..."
ditto -c -k --sequesterRsrc --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"

NOTARIZED=0
if notarize_artifact "${ZIP_PATH}"; then
  echo "    Stapling notarization ticket to ${APP_BUNDLE}..."
  xcrun stapler staple "${APP_BUNDLE}"
  rm -f "${ZIP_PATH}"
  ditto -c -k --sequesterRsrc --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"
  NOTARIZED=1
else
  echo "    WARNING: Skipping Apple notarization (set NOTARY_PROFILE, ASC_KEY_PATH/ASC_KEY_ID/ASC_ISSUER_ID, or APPLE_ID/APPLE_APP_SPECIFIC_PASSWORD/APPLE_TEAM_ID)."
fi

echo "==> [7/7] Generating drag-and-drop ZeroDrive-Installer.dmg..."
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
  if [ "${NOTARIZED}" -eq 1 ]; then
    if notarize_artifact "${DMG_PATH}"; then
      xcrun stapler staple "${DMG_PATH}"
    fi
  fi
fi

if find "${APP_BUNDLE}" -type f -perm +111 -exec file {} + | grep -q "x86_64"; then
  echo "ERROR: Found x86_64 Intel slice inside ${APP_BUNDLE}!"
  exit 1
fi

echo "=============================================================================="
echo " BUILD SUCCESSFUL! (v${VERSION} build ${BUILD_NUMBER}, notarized=${NOTARIZED})"
echo " Native Apple Silicon Binary Verified: $(lipo -archs "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}")"
echo " Auto-Update ZIP Created: ${ZIP_PATH}"
echo " DMG Created: ${DMG_PATH}"
echo " Install to Mac: Open ${DMG_PATH} and drag ZeroDrive to /Applications"
echo "=============================================================================="
