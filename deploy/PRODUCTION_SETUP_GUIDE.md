# ZeroDrive Production 1-Click Launch & Setup Guide

**Target Domains:**
- Interim / Current Active: `zerodrive.aisimple.co`
- Production Future: `zerodrive.dev`
- Bundle Identifier: `co.aisimple.zerodrive`

---

## 1. Domain & DNS Setup (zerodrive.aisimple.co)
In your Cloudflare DNS control panel for **aisimple.co**:
1. Add a **CNAME** record:
   - **Type:** CNAME
   - **Name:** `zerodrive`
   - **Target:** Your Google Cloud Run service URL or Workers domain
   - **Proxy Status:** Proxied (Orange Cloud) for automatic SSL & edge caching.

---

## 2. Deploy Cloudflare Worker Edge Provisioner (1-Click)
Deploy the serverless edge provisioning endpoint so `https://zerodrive.aisimple.co/v1/vault/provision` responds globally in <15 ms:
```bash
cd deploy
npx wrangler deploy
```
Configure your live Cloudflare R2 account and S3 credentials:
```bash
npx wrangler secret put CLOUDFLARE_ACCOUNT_ID
npx wrangler secret put R2_ACCESS_KEY_ID
npx wrangler secret put R2_SECRET_ACCESS_KEY
# Optional for dynamic per-user R2 bucket + token creation:
npx wrangler secret put CLOUDFLARE_API_TOKEN
```

---

## 3. Build Universal macOS Binary & DMG Installer
On any Mac (Apple Silicon or Intel):
```bash
cd ZeroDriveProject
chmod +x build_installer.sh
bash build_installer.sh
```
This script:
1. Compiles ZeroDrive in release mode for `arm64` and `x86_64`
2. Creates a Universal Binary using `lipo -create`
3. Downloads the official CGO-enabled `rclone` release with `nfsmount` support
4. Signs all binaries with your Developer ID Application certificate (or ad-hoc signs for local testing)
5. Packages `build/ZeroDrive-Installer.dmg` with a standard drag-to-Applications layout.

---

## 4. Apple Developer ID Notarization (Gatekeeper)
Submit the generated DMG for Apple notarization:
```bash
xcrun notarytool submit build/ZeroDrive-Installer.dmg \
  --keychain-profile "AC_PASSWORD" \
  --wait

xcrun stapler staple build/ZeroDrive-Installer.dmg
```
Your DMG is now fully approved for Gatekeeper and ready to distribute to users!
