# ZeroDrive Session Handoff & Live Status Tracker

**Last Updated:** November 7, 2026 (12:10 EST)  
**Current Branch:** `main`  
**Active Mac Free Space (`naegele-pro`):** 151 GiB (`df -h /`)  
**Active Mac Mini Free Space (`naegele-mm`):** 71 GiB (`df -h /`)  
**Live Mount Path (Both Macs):** `~/.zerodrive-mount` $\rightarrow$ `~/ZeroDrive/My Drive` (`primary_vault:zerodrive-vault-prod/usr_andrew_8bc7fb477f`)

---

## 1. Where Supporting Research & Plans Live

- **Product Strategy, 3-Bucket Inventory, Competitor Research & Pricing:** [`docs/product-strategy-and-market-research.md`](./docs/product-strategy-and-market-research.md)
- **Apple HIG UI/UX Audit & 6th-Grade Simplicity Redesign:** [`docs/ui-ux-review-and-redesign.md`](./docs/ui-ux-review-and-redesign.md)
- **Step-by-Step Execution Plan & Full Scope Outline:** [`docs/execution-plan.md`](./docs/execution-plan.md)
- **Object Storage Backend Cost Comparison:** [`2026-11-05-storage-alternatives.md`](./2026-11-05-storage-alternatives.md)

---

## 2. Step-by-Step Execution Status

| Step | Task Description | Status | Verification Notes |
| :--- | :--- | :--- | :--- |
| **Step 0** | Halt runaway iCloud `bird` download loop, purge 40 GB `MMCS` cache, clear AI/npm caches, fix `My Drive` root prefix (`usr_andrew_8bc7fb477f`) | **DONE** | Reclaimed 149+ GB on Mac SSD (`df -h /` = 151 GiB free); `ls ~/ZeroDrive/"My Drive"` lists all user folders cleanly. |
| **Step 1** | Save complete strategy, competitor research, UI/UX audit, and step-by-step execution plan in `docs/` + commit to Git | **DONE** | Committed in `4057866` (`docs/product-strategy-and-market-research.md`, `docs/ui-ux-review-and-redesign.md`, `docs/execution-plan.md`). |
| **Step 2** | Audit `~/Desktop/MAIN` vs. R2 Vault `MAIN` (`33,960` files already in R2), remove verified duplicates, and move remaining local files | **DONE** | Removed 289 redundant stubs already verified in R2 (`st.st_size == r2_size`), moved all 137 remaining materialized local files (60 MB) into `My Drive/MAIN` in 8s. |
| **Step 3** | Upgrade `turbo-migrate-dashboard.py` with strict 1-by-1 cloud-stub hydration, `--leave-symlink` folder shortcut creation, dataless `.git` directory guard, and activity logging | **DONE** | Tested end-to-end with `/tmp/zd-symlink-test`: verified file moved to R2, local directory replaced with POSIX symlink (`lrwxr-xr-x`), file readable through symlink, and logged to `zerodrive-symlinks.json`. |
| **Step 4** | Implement UI/UX overhaul & Folder Symlink toggle in `ZeroDriveProject` (Menu bar live telemetry, cut menu bar drop box, cut hardcoded `82.4 GB` projections, merge Overview drop boxes, wire Activity ledger + Symlinks section, add Multi-Device card) | **DONE** | Built with `swift build -c release` (0 errors) and deployed to `/Applications/ZeroDrive.app` on both `naegele-pro` and `naegele-mm`. |
| **Step 5** | Harden `RcloneDaemonSupervisor.swift` (`--dir-cache-time=30s`) & `MultiCloudCombineBuilder.swift` prefix safety; deploy `ZeroDrive.app` to `naegele-mm` (`100.114.74.17`) | **DONE** | Verified via `ssh naegele-mm "ls -la ~/ZeroDrive/'My Drive'"` — all top-level folders are live and mounted on `naegele-mm`. |
| **Step 6** | Authenticate `[icloud_direct]` (`naegele412@gmail.com`) and stream `Desktop/MAIN` $\rightarrow$ R2 Vault `MAIN` directly in RAM on `naegele-mm` | **DONE** | Completed at 01:32 AM with 100% success (0 local Mac SSD used, all files synced to `My Drive/MAIN`). Telemetry confirmed: `✓ Direct iCloud -> Vault stream complete for MAIN`. |
| **Step 7** | Fix `dispatch_once` launch crash, SSH live telemetry poller, multi-folder symlink toggle, selected items list + remove/clear controls, and Vault folder picker / `+ New Folder` in `TransferConfirmationSheet` | **DONE** | Verified live: `ZeroDrive.app` running (PID 18587), `My Drive` mounted on `localhost:55730`, live `naegele-mm` telemetry streaming in UI, and confirmation sheet upgraded. |
| **Step 8** | Build, brand, and deploy complete `zerodrive` / `zd` CLI binary (`bin/zerodrive` with `zd -> zerodrive` symlink) across `naegele-pro` and `naegele-mm` | **DONE** | Installed in `~/.local/bin/` on both Macs. Features `status`, `ls`, `size` (8s for 10k files), `cat` (with `--lines`, `--head`, `--tail`), `find`, `cp`, `mv --symlink`, `share` (Cloudflare pre-signed link), `refresh`, and `--json` support. |
| **Step 9** | Fix Finder beachballing, folder stalls, and Spotlight indexing storms | **DONE** | 1. Switched NFS mount flags to `actimeo=60,noatime,noacl,async` (cached folder browsing dropped from 4-5s to 3-5ms).<br>2. Increased rclone `--dir-cache-time` to `24h` and restricted background `prewarmAll` to non-recursive `My Drive` (prevents VFS mutex lockups).<br>3. Placed `.metadata_never_index` in mount roots and excluded `.Spotlight-V100`, `.fseventsd`, and `.Trashes` (stops `mdworker` indexing storms).<br>4. Rebuilt and deployed `ZeroDrive.app` across both `naegele-pro` and `naegele-mm`. |
| **Step 10** | Permanent Zero-Latency Architecture: Disk Handle Cache, 72h VFS, 300s Kernel Cache & Eager Pre-Warming | **DONE** | 1. Configured `--nfs-cache-type=disk` with persistent on-disk handle store (`~/.zerodrive-cache/nfs-handles`).<br>2. Extended `--dir-cache-time` to `72h` and parallel read streams to `--vfs-read-chunk-streams=4`.<br>3. Extended kernel attribute cache to `actimeo=300` (5 minutes).<br>4. Wired eager background pre-warmer for all 9 active collections (`MAIN`, `Course`, `_BUSINESS`, `_LIBRARY`, `_SKILLS`, `_SORT`, `_Retakes`, `_CAPTURES`, `CLOUD-MAIN`).<br>5. Built and deployed across both `naegele-pro` and `naegele-mm`. |
| **Step 11** | Hosted 24/7 AI Agent MCP Server, Google OAuth 2.0 & `zerodrive.dev` Edge Deployment | **DONE** | 1. Deployed live Cloudflare Worker on `api.zerodrive.dev` with version `b9cb393d-5cd4-4214-8f82-bb24a3c5d2d7`.<br>2. Implemented 1-click Google OAuth 2.0 (`/login`, `/auth/google`, `/auth/callback`) with credentials injected via Cloudflare Secrets.<br>3. Hosted 24/7 MCP Server (`api.zerodrive.dev/mcp`) supporting `zd_list`, `zd_read`, `zd_write`, `zd_search`, and `zd_size` directly on R2.<br>4. Tested live over HTTPS: verified 401 Unauthorized protection and authenticated reads/lists returning live vault data in <100ms. |
| **Step 12** | Complete REST API Surface, OpenAPI 3.1 Spec, Multi-Device Fleet & Interactive Docs | **DONE** | 1. Deployed live Cloudflare Worker version `288664cb-6e51-4618-a40a-30faf97bbcd0` on `api.zerodrive.dev`.<br>2. Built full REST API surface: tree, files (read, write, edit, move, copy, delete, batch), pre-signed upload URLs (zero-token binary streaming up to 5GB), Range download streaming, size, search, grep, and doctor.<br>3. Added Multi-Device Fleet API (`/v1/devices`, `/v1/devices/heartbeat`, `/v1/symlinks`, `/v1/activity`).<br>4. Published comprehensive OpenAPI 3.1 blueprint at `api.zerodrive.dev/openapi.json` and interactive docs at `api.zerodrive.dev/docs`.<br>5. Live verified via curl over HTTPS: verified 401 Unauthorized protection and successful responses across all endpoints. |
| **Step 13** | Native Apple FileProvider Extension (`NSFileProviderReplicatedExtension`), 3ms APFS Placeholders & Bidirectional Cloud Sync | **DONE** | 1. Deployed sub-20ms `/v1/files/stat` and cursor pagination on `/v1/files` to `api.zerodrive.dev`.<br>2. Built `ZeroDriveFileProvider.appex` with Universal Binary (`arm64` + `x86_64`) signed with Developer ID (`DTB456HJMJ`).<br>3. Registered native FileProvider domain `ZeroDrive` with `fileproviderd` at `~/Library/CloudStorage/ZeroDrive-ZeroDrive`.<br>4. Verified bidirectional lifecycle: 3ms folder browse (`ls ~/ZeroDrive` in 0.003s), instant file hydration (`CLAUDE.md`), instant file creation (uploaded to R2 in 402ms), and live file deletion (removed from R2 in 580ms).<br>5. Switched `~/ZeroDrive` symlink directly to native APFS FileProvider mount. |

---

## 3. Immediate Next Decisions & Actions

1. **Local `~/Desktop/MAIN` Symlink Cutover:** Since the direct iCloud-to-Vault stream is 100% complete and verified in R2, verify if `~/Desktop/MAIN` can be archived or replaced with a 0-byte symlink to `~/ZeroDrive/My Drive/MAIN` to reclaim the remaining local folder space.
2. **Next Feature from Roadmap:**
   - **Phase 7 (Native in-app Apple ID + 2FA GUI):** Embed the iCloud login dialog natively into SwiftUI so users never see a terminal prompt.
   - **Phase 8 (Headless Linux VPS 1-line mount):** Provide the `curl ... | bash` command for AI agents on cloud VMs.
   - **Phase 12 (Developer CLI `zd`):** Create the lightweight `zd` CLI tool so AI coding agents can query file and folder sizes in milliseconds without triggering slow `du -sh` POSIX walks over the mount.

---

## November 10, 2026: launch offer and funnel (Claude Code, Offer Machine skill)

Drafted the launch offer, funnel and pricing answers in [launch-offer/](launch-offer/01-OFFER-BLUEPRINT.md). Status: concept complete, economics provisional. Nothing priced in Stripe, built or published.

**Launch blocker found in code:** `deploy/worker.js` `extractTenantFromAuth` takes the customer ID from the `Credential=` header without checking the signature, and falls back to `default_tenant`. Any outside user could reach another user's files through `/s3/`. Fix before any free or paid signup. Live endpoint was not probed.

Next action: Andrew works through [the decision list](launch-offer/09-DECISION.md), starting with the tenant fix and the free-vault change.

Revision 2 same day: Andrew kept free at 10 GB on the user's own Cloudflare (switch to paid at 10 GB, MCP yes, API no), held the bonuses until ready, and chose Pro Max as the Founder Special plus Agency. Blueprint updated. New gaps found in code: Connect Cloudflare still asks for pasted keys, and hosted MCP cannot read a user's own bucket (local MCP can). Open: $49 vs $39 start.
