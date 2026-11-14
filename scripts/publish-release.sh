#!/usr/bin/env bash
# ==============================================================================
# ZeroDrive Unified Cross-Platform Release Publisher (macOS + Windows)
# Builds, signs, packages, generates release manifest + changelog from
# release-notes.md, deploys Cloudflare Worker, and uploads artifacts to R2.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

PRIVATE_KEY="${ZERODRIVE_SIGNING_PRIVATE_KEY:-${HOME}/.zerodrive-keys/update-signing-private.pem}"
PUBLIC_KEY="${ZERODRIVE_SIGNING_PUBLIC_KEY:-${HOME}/.zerodrive-keys/update-signing-public.pem}"
WRANGLER_BIN="${WRANGLER_BIN:-/Users/Naegele/.npm-global/bin/wrangler}"
if [ ! -x "${WRANGLER_BIN}" ]; then
  WRANGLER_BIN="$(command -v wrangler || true)"
fi
R2_BUCKET="${ZERODRIVE_R2_BUCKET:-zerodrive-vault-prod}"
CANONICAL_ORIGIN="${ZERODRIVE_API_BASE:-https://api.zerodrive.dev}"

SKIP_DEPLOY=0
SKIP_NOTARIZE=0
REUSE_MACOS_BUILD=0
POSITIONAL=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-deploy)
      SKIP_DEPLOY=1
      shift
      ;;
    --skip-notarize)
      SKIP_NOTARIZE=1
      shift
      ;;
    --reuse-macos-build)
      REUSE_MACOS_BUILD=1
      shift
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

VERSION="${POSITIONAL[0]:-}"
BUILD_NUMBER="${POSITIONAL[1]:-}"

if [ ! -f "${REPO_ROOT}/release-notes.md" ]; then
  echo "ERROR: ${REPO_ROOT}/release-notes.md not found." >&2
  exit 1
fi
if [ ! -f "${PRIVATE_KEY}" ] || [ ! -f "${PUBLIC_KEY}" ]; then
  echo "ERROR: ECDSA P-256 signing keypair missing at ${PRIVATE_KEY} / ${PUBLIC_KEY}" >&2
  exit 1
fi

# Determine defaults from release-notes.md if VERSION not supplied
if [ -z "${VERSION}" ]; then
  VERSION=$(node -e '
    import("./deploy/releases.js").then(({ parseReleaseNotesMarkdown }) => {
      const fs = require("fs");
      const list = parseReleaseNotesMarkdown(fs.readFileSync("./release-notes.md", "utf8"));
      if (!list.length) process.exit(1);
      process.stdout.write(list[0].version);
    });
  ')
fi

if [ -z "${BUILD_NUMBER}" ]; then
  CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "ZeroDriveProject/Assets/Info.plist" 2>/dev/null || echo "1")
  if [ "${VERSION}" = "3.1.0" ] && [ "${CURRENT_BUILD}" -lt 2 ]; then
    BUILD_NUMBER="2"
  else
    BUILD_NUMBER="${CURRENT_BUILD}"
  fi
fi

# Validate that VERSION is documented in release-notes.md
node -e '
  import("./deploy/releases.js").then(({ parseReleaseNotesMarkdown }) => {
    const fs = require("fs");
    const version = process.argv[1];
    const list = parseReleaseNotesMarkdown(fs.readFileSync("./release-notes.md", "utf8"));
    const match = list.find((r) => r.version === version);
    if (!match) {
      console.error(`ERROR: release-notes.md does not contain a "## v${version}" section.`);
      process.exit(1);
    }
    console.log(`==> Verified release notes entry for v${version}: ${match.title} (${match.highlights.length} highlights)`);
  });
' "${VERSION}"

RELEASE_OUT_DIR="${REPO_ROOT}/build/releases/${VERSION}"
rm -rf "${RELEASE_OUT_DIR}"
mkdir -p "${RELEASE_OUT_DIR}"

RELEASE_NOTES_JSON="${RELEASE_OUT_DIR}/release-notes.json"
CHANGELOG_MD="${RELEASE_OUT_DIR}/CHANGELOG.md"

node -e '
  import("./deploy/releases.js").then(({ parseReleaseNotesMarkdown }) => {
    const fs = require("fs");
    const targetVer = process.argv[1];
    const targetBuild = process.argv[2];
    const jsonOut = process.argv[3];
    const mdOut = process.argv[4];
    const rawMd = fs.readFileSync("./release-notes.md", "utf8");
    const parsed = parseReleaseNotesMarkdown(rawMd).map((r) => ({
      ...r,
      build: r.version === targetVer ? String(targetBuild) : r.build
    }));
    fs.writeFileSync(jsonOut, JSON.stringify(parsed, null, 2));
    fs.writeFileSync(mdOut, rawMd);
  });
' "${VERSION}" "${BUILD_NUMBER}" "${RELEASE_NOTES_JSON}" "${CHANGELOG_MD}"

echo "==> [1/6] Stamping version v${VERSION} (build ${BUILD_NUMBER}) across source manifests..."
for plist in \
  "ZeroDriveProject/Assets/Info.plist" \
  "ZeroDriveProject/FinderSyncExtension/Info.plist" \
  "ZeroDriveProject/ZeroDriveFileProvider/Info.plist"; do
  if [ -f "${plist}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${plist}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${plist}"
  fi
done

node -e '
  const fs = require("fs");
  const ver = process.argv[1];

  const csprojPath = "windows/zerodrive-sync.csproj";
  let csproj = fs.readFileSync(csprojPath, "utf8");
  csproj = csproj
    .replace(/<Version>[^<]+<\/Version>/, `<Version>${ver}</Version>`)
    .replace(/<AssemblyVersion>[^<]+<\/AssemblyVersion>/, `<AssemblyVersion>${ver}.0</AssemblyVersion>`)
    .replace(/<FileVersion>[^<]+<\/FileVersion>/, `<FileVersion>${ver}.0</FileVersion>`);
  fs.writeFileSync(csprojPath, csproj);

  const csPath = "windows/zerodrive-sync.cs";
  let cs = fs.readFileSync(csPath, "utf8");
  cs = cs.replace(/public const string CurrentVersion = "[^"]+";/, `public const string CurrentVersion = "${ver}";`);
  fs.writeFileSync(csPath, cs);

  const psPath = "windows/install-zerodrive.ps1";
  let ps = fs.readFileSync(psPath, "utf8");
  ps = ps.replace(/version\s*=\s*"[^"]+"/, `version   = "${ver}"`);
  fs.writeFileSync(psPath, ps);
' "${VERSION}"

MAC_ZIP_NAME="ZeroDrive-macOS-${VERSION}.zip"
MAC_ZIP_PATH="${RELEASE_OUT_DIR}/${MAC_ZIP_NAME}"
DMG_PATH="${RELEASE_OUT_DIR}/ZeroDrive-Installer.dmg"

if [ "${REUSE_MACOS_BUILD}" -eq 1 ] && [ -f "${REPO_ROOT}/ZeroDriveProject/build/${MAC_ZIP_NAME}" ] && [ -f "${REPO_ROOT}/ZeroDriveProject/build/ZeroDrive-Installer.dmg" ]; then
  echo "==> [2/6] Reusing existing macOS build artifacts for v${VERSION}..."
else
  echo "==> [2/6] Building & signing macOS app, ZIP, and DMG..."
  MAC_FLAGS=(
    --version "${VERSION}"
    --build-number "${BUILD_NUMBER}"
    --release-notes-json "${RELEASE_NOTES_JSON}"
    --update-source-plists
  )
  if [ "${SKIP_NOTARIZE}" -eq 1 ]; then
    MAC_FLAGS+=(--skip-notarize)
  fi
  bash ZeroDriveProject/build_installer.sh "${MAC_FLAGS[@]}"
fi

cp "${REPO_ROOT}/ZeroDriveProject/build/${MAC_ZIP_NAME}" "${MAC_ZIP_PATH}"
cp "${REPO_ROOT}/ZeroDriveProject/build/ZeroDrive-Installer.dmg" "${DMG_PATH}"

MAC_NOTARIZED="false"
if xcrun stapler validate "${REPO_ROOT}/ZeroDriveProject/build/ZeroDrive.app" >/dev/null 2>&1; then
  MAC_NOTARIZED="true"
fi

echo "==> [3/6] Building & packaging Windows client (win-x64)..."
WIN_STAGE="${RELEASE_OUT_DIR}/win-stage"
WIN_PUB="${WIN_STAGE}/pub"
WIN_PKG="${WIN_STAGE}/pkg"
mkdir -p "${WIN_PUB}" "${WIN_PKG}"

dotnet publish windows/zerodrive-sync.csproj \
  -c Release \
  -r win-x64 \
  --no-self-contained \
  -p:Version="${VERSION}" \
  -p:AssemblyVersion="${VERSION}.0" \
  -p:FileVersion="${VERSION}.0" \
  -o "${WIN_PUB}"

cp "${WIN_PUB}/zerodrive-sync.exe" "${WIN_PKG}/zerodrive-sync.exe"
cp windows/zerodrive-sync.cs "${WIN_PKG}/zerodrive-sync.cs"
cp windows/zerodrive-sync.csproj "${WIN_PKG}/zerodrive-sync.csproj"
cp windows/sync-daemon.ps1 "${WIN_PKG}/sync-daemon.ps1"
cp windows/update-zerodrive.ps1 "${WIN_PKG}/update-zerodrive.ps1"
cp windows/install-zerodrive.ps1 "${WIN_PKG}/install-zerodrive.ps1"
cp windows/uninstall-zerodrive.ps1 "${WIN_PKG}/uninstall-zerodrive.ps1"
cp "${RELEASE_NOTES_JSON}" "${WIN_PKG}/release-notes.json"
cp "${CHANGELOG_MD}" "${WIN_PKG}/CHANGELOG.md"

WIN_AUTHENTICODE_SIGNED="false"
AZURE_SIGNING_ENDPOINT="${AZURE_SIGNING_ENDPOINT:-https://eus.codesigning.azure.net/}"
AZURE_SIGNING_ACCOUNT="${AZURE_SIGNING_ACCOUNT:-zerodrive-signing}"
AZURE_SIGNING_PROFILE="${AZURE_SIGNING_PROFILE:-zerodrive-public-trust}"

has_azure_signing_auth() {
  if [ -n "${AZURE_CLIENT_ID:-}" ] && [ -n "${AZURE_TENANT_ID:-}" ] && [ -n "${AZURE_CLIENT_SECRET:-}" ]; then
    return 0
  fi
  command -v az >/dev/null 2>&1 && az account get-access-token --resource "https://codesigning.azure.net" >/dev/null 2>&1
}

if command -v trusted-signing-cli >/dev/null 2>&1 && has_azure_signing_auth; then
  echo "    Applying Windows Authenticode signature via Azure Artifact Signing (${AZURE_SIGNING_ACCOUNT}/${AZURE_SIGNING_PROFILE})..."
  if trusted-signing-cli \
    -e "${AZURE_SIGNING_ENDPOINT}" \
    -a "${AZURE_SIGNING_ACCOUNT}" \
    -c "${AZURE_SIGNING_PROFILE}" \
    "${WIN_PKG}/zerodrive-sync.exe"; then
    WIN_AUTHENTICODE_SIGNED="true"
  else
    echo "    WARNING: Azure Artifact Signing (${AZURE_SIGNING_ACCOUNT}/${AZURE_SIGNING_PROFILE}) did not complete; checking PFX fallback."
  fi
fi

if [ "${WIN_AUTHENTICODE_SIGNED}" != "true" ]; then
  if [ -n "${WINDOWS_CERT_PFX:-}" ] && [ -f "${WINDOWS_CERT_PFX}" ] && command -v osslsigncode >/dev/null 2>&1; then
    echo "    Applying Windows Authenticode signature via osslsigncode..."
    SIGNED_EXE="${WIN_STAGE}/zerodrive-sync.signed.exe"
    SIGN_ARGS=(sign -pkcs12 "${WINDOWS_CERT_PFX}" -n "ZeroDrive Sync Client" -i "https://zerodrive.dev" -t "http://timestamp.digicert.com")
    if [ -n "${WINDOWS_CERT_PASSWORD:-}" ]; then
      SIGN_ARGS+=(-pass "${WINDOWS_CERT_PASSWORD}")
    fi
    osslsigncode "${SIGN_ARGS[@]}" -in "${WIN_PKG}/zerodrive-sync.exe" -out "${SIGNED_EXE}"
    mv "${SIGNED_EXE}" "${WIN_PKG}/zerodrive-sync.exe"
    WIN_AUTHENTICODE_SIGNED="true"
  else
    echo "    WARNING: Skipping Windows Authenticode signing (Azure Artifact Signing ${AZURE_SIGNING_ACCOUNT} at ${AZURE_SIGNING_ENDPOINT}, profile ${AZURE_SIGNING_PROFILE}, or WINDOWS_CERT_PFX + osslsigncode not active yet)."
  fi
fi

WIN_ZIP_NAME="ZeroDrive-Windows-${VERSION}.zip"
WIN_ZIP_PATH="${RELEASE_OUT_DIR}/${WIN_ZIP_NAME}"
(cd "${WIN_PKG}" && zip -q -r "${WIN_ZIP_PATH}" .)
rm -rf "${WIN_STAGE}"

echo "==> [4/6] Computing SHA-256 digests & ECDSA P-256 signatures..."
sign_and_verify() {
  local platform="$1"
  local file_path="$2"
  local sha
  sha=$(shasum -a 256 "${file_path}" | awk '{print $1}')
  local size
  size=$(stat -f%z "${file_path}")
  local payload="zerodrive-release-v1:${platform}:${VERSION}:${sha}:${size}"
  local sig_bin="${RELEASE_OUT_DIR}/.${platform}.sig.bin"
  printf '%s' "${payload}" | openssl dgst -sha256 -sign "${PRIVATE_KEY}" -out "${sig_bin}"
  printf '%s' "${payload}" | openssl dgst -sha256 -verify "${PUBLIC_KEY}" -signature "${sig_bin}" >/dev/null
  local sig_b64
  sig_b64=$(openssl base64 -A -in "${sig_bin}")
  rm -f "${sig_bin}"
  printf '%s|%s|%s\n' "${sha}" "${size}" "${sig_b64}"
}

MAC_META=$(sign_and_verify "macos" "${MAC_ZIP_PATH}")
MAC_SHA256="${MAC_META%%|*}"
REST="${MAC_META#*|}"
MAC_SIZE="${REST%%|*}"
MAC_SIG="${REST#*|}"

WIN_META=$(sign_and_verify "windows" "${WIN_ZIP_PATH}")
WIN_SHA256="${WIN_META%%|*}"
REST="${WIN_META#*|}"
WIN_SIZE="${REST%%|*}"
WIN_SIG="${REST#*|}"

MANIFEST_PATH="${RELEASE_OUT_DIR}/manifest.json"
node -e '
  import("./deploy/releases.js").then(({ UPDATE_SIGNING_PUBLIC_KEY_PEM }) => {
    const fs = require("fs");
    const [
      version, build, origin, releaseNotesPath, manifestOut,
      macFilename, macSize, macSha, macSig, macNotarized,
      winFilename, winSize, winSha, winSig, winSigned
    ] = process.argv.slice(1);
    const releases = JSON.parse(fs.readFileSync(releaseNotesPath, "utf8"));
    const manifest = {
      schema: 1,
      latest_version: version,
      build: String(build),
      published_at: new Date().toISOString(),
      public_key: UPDATE_SIGNING_PUBLIC_KEY_PEM,
      platforms: {
        macos: {
          platform: "macos",
          arch: "arm64",
          filename: macFilename,
          url: `${origin}/download/${macFilename}`,
          dmg_url: `${origin}/download/ZeroDrive-Installer.dmg`,
          size: Number(macSize),
          sha256: macSha,
          signature: macSig,
          signature_alg: "ecdsa-p256-sha256",
          team_id: "DTB456HJMJ",
          notarized: macNotarized === "true",
          minimum_os: "13.0"
        },
        windows: {
          platform: "windows",
          arch: "x64",
          filename: winFilename,
          url: `${origin}/download/${winFilename}`,
          installer_url: `${origin}/download/install-zerodrive.ps1`,
          size: Number(winSize),
          sha256: winSha,
          signature: winSig,
          signature_alg: "ecdsa-p256-sha256",
          authenticode_signed: winSigned === "true",
          minimum_os: "Windows 10 1809"
        }
      },
      releases
    };
    fs.writeFileSync(manifestOut, JSON.stringify(manifest, null, 2));
  });
' \
  "${VERSION}" "${BUILD_NUMBER}" "${CANONICAL_ORIGIN}" "${RELEASE_NOTES_JSON}" "${MANIFEST_PATH}" \
  "${MAC_ZIP_NAME}" "${MAC_SIZE}" "${MAC_SHA256}" "${MAC_SIG}" "${MAC_NOTARIZED}" \
  "${WIN_ZIP_NAME}" "${WIN_SIZE}" "${WIN_SHA256}" "${WIN_SIG}" "${WIN_AUTHENTICODE_SIGNED}"

echo "    macOS ZIP:   ${MAC_ZIP_NAME} (${MAC_SIZE} bytes, sha256=${MAC_SHA256:0:16}...)"
echo "    Windows ZIP: ${WIN_ZIP_NAME} (${WIN_SIZE} bytes, sha256=${WIN_SHA256:0:16}...)"
echo "    Manifest:    ${MANIFEST_PATH}"

if [ "${SKIP_DEPLOY}" -eq 1 ]; then
  echo "==> [5/6] & [6/6] Skipped Cloudflare Worker & R2 upload (--skip-deploy)."
  exit 0
fi

if [ -z "${WRANGLER_BIN}" ] || [ ! -x "${WRANGLER_BIN}" ]; then
  echo "ERROR: wrangler CLI not found. Install wrangler or set WRANGLER_BIN." >&2
  exit 1
fi

if [ -n "${CLOUDFLARE_API_TOKEN:-}" ] && [ "${ZERODRIVE_USE_ENV_CF_TOKEN:-0}" != "1" ]; then
  if ! "${WRANGLER_BIN}" r2 bucket list >/dev/null 2>&1; then
    if env -u CLOUDFLARE_API_TOKEN "${WRANGLER_BIN}" r2 bucket list >/dev/null 2>&1; then
      echo "    NOTE: Unsetting shell CLOUDFLARE_API_TOKEN (lacks R2/Worker access); using logged-in Wrangler OAuth session."
      unset CLOUDFLARE_API_TOKEN
    fi
  fi
fi

echo "==> [5/6] Deploying Cloudflare Worker & uploading artifacts to R2 (${R2_BUCKET})..."
(cd "${REPO_ROOT}/deploy" && "${WRANGLER_BIN}" deploy)

"${WRANGLER_BIN}" r2 object put "${R2_BUCKET}/releases/${MAC_ZIP_NAME}" --file "${MAC_ZIP_PATH}" --content-type "application/zip" --remote
"${WRANGLER_BIN}" r2 object put "${R2_BUCKET}/releases/ZeroDrive-Installer.dmg" --file "${DMG_PATH}" --content-type "application/x-apple-diskimage" --remote
"${WRANGLER_BIN}" r2 object put "${R2_BUCKET}/releases/${WIN_ZIP_NAME}" --file "${WIN_ZIP_PATH}" --content-type "application/zip" --remote
"${WRANGLER_BIN}" r2 object put "${R2_BUCKET}/releases/install-zerodrive.ps1" --file "${REPO_ROOT}/windows/install-zerodrive.ps1" --content-type "text/plain; charset=utf-8" --remote
"${WRANGLER_BIN}" r2 object put "${R2_BUCKET}/releases/release-notes.json" --file "${RELEASE_NOTES_JSON}" --content-type "application/json" --remote
"${WRANGLER_BIN}" r2 object put "${R2_BUCKET}/releases/CHANGELOG.md" --file "${CHANGELOG_MD}" --content-type "text/markdown; charset=utf-8" --remote
"${WRANGLER_BIN}" r2 object put "${R2_BUCKET}/releases/manifest.json" --file "${MANIFEST_PATH}" --content-type "application/json" --remote

echo "==> [6/6] Verifying live production endpoints on ${CANONICAL_ORIGIN}..."
curl -fsSL "${CANONICAL_ORIGIN}/v1/releases/latest?platform=macos&current_version=3.0.0" | node -e '
  const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
  if (!data.update_available || !data.platform_artifact?.signature) process.exit(1);
  console.log(`    [OK] macOS check -> latest=${data.latest_version}, missed=${(data.missed_releases || []).map(r => r.version).join(",")}, size=${data.platform_artifact.size}`);
'
curl -fsSL "${CANONICAL_ORIGIN}/v1/releases/latest?platform=windows&current_version=3.0.0" | node -e '
  const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
  if (!data.update_available || !data.platform_artifact?.signature) process.exit(1);
  console.log(`    [OK] Windows check -> latest=${data.latest_version}, missed=${(data.missed_releases || []).map(r => r.version).join(",")}, size=${data.platform_artifact.size}`);
'
curl -fsSL "${CANONICAL_ORIGIN}/v1/releases/appcast.xml" | grep -q "sparkle:shortVersionString>${VERSION}<"
echo "    [OK] Sparkle appcast.xml serving v${VERSION}"

curl -fsSI "${CANONICAL_ORIGIN}/download/${MAC_ZIP_NAME}" | grep -qi "accept-ranges: bytes"
echo "    [OK] macOS ZIP HEAD + Range header verified"

curl -fsSI "${CANONICAL_ORIGIN}/download/${WIN_ZIP_NAME}" | grep -qi "accept-ranges: bytes"
echo "    [OK] Windows ZIP HEAD + Range header verified"

echo "=============================================================================="
echo " RELEASE v${VERSION} (build ${BUILD_NUMBER}) PUBLISHED SUCCESSFULLY!"
echo " Output dir: ${RELEASE_OUT_DIR}"
echo "=============================================================================="
