# ZeroDrive Launch Readiness Status

**Updated:** November 13, 2026
**Release:** `v3.1.0`
**Cloudflare Worker:** `zerodrive-provisioner` (`api.zerodrive.dev`, `zerodrive.aisimple.co`) — Version `e649e8fd-22e6-417e-9e56-7dd862f7d3a3`

## Executive Summary

All core code, desktop builds (`v3.1.0`), auto-updater, multi-tenant R2 S3 proxy, MCP/REST endpoints, billing/license engine, and security hardening are **built, tested (103/103 automated tests passing), deployed to Cloudflare, and pushed to `main`**.

Two external operations items still block live paid public traffic:
1. **Stripe secrets on Cloudflare are unset** (`STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`), so live checkout currently returns HTTP `503` ("Card Billing Setup Pending").
2. **`https://zerodrive.dev/` root site returns HTTP `522`** (origin timeout), and no marketing landing page or checkout funnel is live there yet.

---

## Security & Pre-Launch Fixes Completed & Verified (Nov 13, 2026)

1. **S3 Proxy SigV4 Signature Verification (`deploy/worker.js`, `deploy/billing.js`)**
   - Added AWS4-HMAC-SHA256 verification (`verifyS3RequestSignature`) for both `Authorization` headers and presigned URLs, including Cloudflare edge `Accept-Encoding` header normalization (`identity` <-> `gzip` / `gzip, br`) used by `rclone` / AWS SDK Go v2.
   - Added deterministic `resolveTenantSecretKey` in `deploy/billing.js` derived from `userPrefix` + `LICENSE_SECRET`.
   - Verified live: `rclone lsd primary_vault:zerodrive-vault-prod/usr_andrew_8bc7fb477f` succeeds (`exit 0`), `~/ZeroDrive/"My Drive"` mount is readable, and forged S3 signatures return HTTP `403 SignatureDoesNotMatch`.

2. **REST / MCP / Admin Bearer Authentication Lockdown (`deploy/worker.js`, `deploy/billing.js`)**
   - Converted `authenticateMCPRequest` to `async` across all 7 call sites and removed unverified `zd_oauth_` and `usr_` prefix bypasses.
   - Enforced cryptographic SHA-256 verification against `GOOGLE_CLIENT_SECRET` for `zd_oauth_master_*` and `zd_oauth_usr_*`, valid HMAC-signed license keys (`ZD-PRO-...`, `ZD-AGY-...`, `zd_live_...`), and restricted public R2 AccessKeyId tokens (`zd_r2_*`) strictly to `/v1/events`, `/events`, `/v1/activity`, `/activity/stream`, and `/v1/devices` (used by desktop client SSE/activity polling).
   - Hardened `checkLicenseAdminAuth` in `deploy/billing.js` to reject `zd_r2_andrew_8bc7fb477f` and arbitrary `zd_oauth_master*` prefixes, using `timingSafeEqual`.
   - Verified live: forged `Bearer zd_oauth_master` and `Bearer zd_r2_andrew_8bc7fb477f` on `/v1/files` return HTTP `401`.

3. **Unpaid Provisioning & License Minting Gated (`deploy/worker.js`, `deploy/billing.js`)**
   - Gated `/v1/auth/create-account` and `/v1/vault/provision` so unpaid non-master callers (no valid license key, no existing account, not `free`, and `ALLOW_MOCK_CHECKOUT !== "1"`) receive HTTP `402` (`payment_required: true`, `checkout_url`).
   - Ensured `plan: "free"` provisions `Free Starter (BYOK)` (`0.01 TB`) with a non-Pro `zd_free_*` identifier instead of minting a Pro `zd_live_` key.
   - Updated Stripe Checkout default `success_url` and `cancel_url` in `deploy/billing.js` from the offline `zerodrive.dev` domain to `https://api.zerodrive.dev/...`.
   - Verified live: unpaid `POST /v1/auth/create-account` and `POST /v1/vault/provision` return HTTP `402`.

4. **Test Suites Updated & Passing (`103 / 103`)**
   - `node --test deploy/billing-and-auth.test.js`: `8 / 8` passed (includes S3 SigV4, Cloudflare `Accept-Encoding` edge rewrite, forged Bearer/admin, and 402 gate regression tests)
   - `node tests/test-auto-updates.js`: `5 / 5` passed
   - `node tests/test-billing-and-license.js`: `26 / 26` passed
   - `node tests/test-cross-platform-sync.js`: `22 / 22` passed
   - `node tests/test-multi-drive.js`: `17 / 17` passed
   - `node tests/test-team-mcp.js`: `25 / 25` passed

---

## Remaining Manual Steps Before Public Paid Traffic

### Must-Do Launch Blockers
1. **Configure Live Stripe Billing Secrets on Cloudflare**
   - Set secrets via Wrangler in `deploy/`:
     - `wrangler secret put STRIPE_SECRET_KEY`
     - `wrangler secret put STRIPE_WEBHOOK_SECRET`
   - Configure Stripe Webhook endpoint to `https://api.zerodrive.dev/v1/billing/webhook` (`checkout.session.completed`, `customer.subscription.updated`, `customer.subscription.deleted`), then run an end-to-end live checkout -> webhook -> license key -> app activation test.
2. **Bring `zerodrive.dev` Online**
   - Resolve Cloudflare HTTP `522` origin timeout on `https://zerodrive.dev/` and deploy the launch marketing site / pricing page (`launch-offer/01-OFFER-BLUEPRINT.md`).

### Optional Pre-Launch Polish (Non-Blocking for macOS / Soft Launch)
- **Windows Authenticode Code Signing:** `build/releases/3.1.0/manifest.json` has `notarized: true` on macOS and `authenticode_signed: false` on Windows (Windows installers trigger a SmartScreen warning until signed with an Authenticode/EV certificate).
- **1-Click Cloudflare OAuth BYOK Setup:** Currently BYOK requires manual R2 API key entry; OAuth automation is not yet wired.
- **Launch Assets & Legal Pages:** Sales landing copy, onboarding/launch email sequences, Terms/Privacy pages, and fresh-machine QA walkthrough.
