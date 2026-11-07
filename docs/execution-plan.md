# ZeroDrive Step-by-Step Execution Plan & Full Scope Outline

**Last Updated:** November 6, 2026  
**Status:** Active Execution Approved by Andrew  
**Resume Tracker:** See [`STATUS.md`](../STATUS.md) in the repository root for live step completion status.

---

## 1. Full Scope Outline

1. **Phase 1: Repository Documentation & Resumable State (Current)**
   - Save product strategy, market research, 3-bucket inventory, and pricing model in [`docs/product-strategy-and-market-research.md`](./product-strategy-and-market-research.md).
   - Save complete Apple HIG UI/UX audit and 6th-grade simplicity redesign in [`docs/ui-ux-review-and-redesign.md`](./ui-ux-review-and-redesign.md).
   - Save this concrete execution plan in [`docs/execution-plan.md`](./execution-plan.md) and resumable handoff state in [`STATUS.md`](../STATUS.md).
   - Commit documentation baseline to Git.

2. **Phase 2: `MAIN` Folder Audit, De-Duplication & Safe Drain Engine**
   - Audit `~/Desktop/MAIN` vs. `primary_vault:zerodrive-vault-prod/usr_andrew_8bc7fb477f/MAIN`.
   - Identify files in `~/Desktop/MAIN` that are **already verified in R2** (with matching relative path and byte size) and safely remove/evict redundant local copies so zero duplicate storage is wasted.
   - Upgrade [`turbo-migrate-dashboard.py`](../turbo-migrate-dashboard.py) so:
     1. Already-local files move first in fast 32-stream batches (`rclone move --files-from`).
     2. Cloud-only stubs (`SF_DATALESS`) hydrate strictly **one file at a time** (or via direct `rclone iclouddrive:` streaming when configured) with a hard size/disk check so Apple's `bird` daemon never queues 40 GB in `MMCS`.
     3. Completed moves write to both `~/.config/rclone/migration-ledger.json` and `~/.config/rclone/session-activity.json`.

3. **Phase 3: Folder-Level "Move & Leave Symlink" Feature**
   - Add `--leave-symlink` flag to [`turbo-migrate-dashboard.py`](../turbo-migrate-dashboard.py): after a folder's files are verified in R2 and removed locally, replace the local folder with a POSIX symlink (`ln -s "~/ZeroDrive/My Drive/<Destination>" "<OriginalPath>"`) and record the mapping in `~/.config/rclone/zerodrive-symlinks.json`.
   - Wire `leaveSymlink: Bool` through [`TransferConfirmationSheet.swift`](../ZeroDriveProject/Sources/UI/TransferConfirmationSheet.swift) and [`TurboMigrationManager.swift`](../ZeroDriveProject/Sources/Core/TurboMigrationManager.swift).
   - Test with a real folder move + symlink verification (`ls -la`, `cd` through the symlink, and reading files via the symlink).

4. **Phase 4: UI/UX Simplification & High-Precision Polish**
   - **Menu Bar ([`ZeroDriveApp.swift`](../ZeroDriveProject/Sources/ZeroDriveApp.swift), [`MenuBarPopoverView.swift`](../ZeroDriveProject/Sources/UI/MenuBarPopoverView.swift)):**
     - Cut the unusable menu bar drag-and-drop box.
     - Wire `TurboMigrationManager.shared` into both the menu bar icon label and popover so active folder moves show real-time speed (`MB/s`), progress bar, current file, and Stop button.
     - Add at-a-glance storage metrics (`In Cloud Vault` vs. `Mac SSD Free`) and a 1-click **"Move Folder to Cloud…"** button.
   - **Main Window Overview & Migration Card ([`MainStudioWindow.swift`](../ZeroDriveProject/Sources/UI/MainStudioWindow.swift), [`FabricDriveMigrationCard.swift`](../ZeroDriveProject/Sources/UI/FabricDriveMigrationCard.swift)):**
     - Cut hardcoded `"~82.4 GB"` / `"~48 GB"` projection text and hardcoded workspace strings.
     - Merge the duplicate `"Move to My Drive"` drop box in `MainStudioWindow.swift` so there is one clean, unmistakable transfer card on Overview.
     - Update all labels to plain 6th-grade English.
   - **Activity Tab ([`TransfersView.swift`](../ZeroDriveProject/Sources/UI/TransfersView.swift)):**
     - Display completed folder migrations from `migration-ledger.json`, active symlinks from `zerodrive-symlinks.json`, and session events from `session-activity.json`.
   - **Cloud Drives & Devices Tab ([`MainStudioWindow.swift`](../ZeroDriveProject/Sources/UI/MainStudioWindow.swift)):**
     - Add **"My Macs & Devices"** section showing connected devices and a 1-click **"Pair Another Mac"** command/button.

5. **Phase 5: Mount Self-Healing, Multi-Device Sync & `naegele-mm` Deployment**
   - Harden [`RcloneDaemonSupervisor.swift`](../ZeroDriveProject/Sources/Core/RcloneDaemonSupervisor.swift) pre-mount sequence to always run `diskutil unmount force ~/.zerodrive-mount`, verify the tenant prefix in `rclone.conf`, and lower `--dir-cache-time` / trigger `vfs/refresh` so multi-device updates appear quickly.
   - Deploy `ZeroDrive.app` and vault configuration to `naegele-mm` (`100.114.74.17` over SSH), start the mount on `naegele-mm`, and verify `ls -la ~/ZeroDrive/"My Drive"` on `naegele-mm` matches `naegele-pro` 100%.

6. **Phase 6: Build, Deploy, Verify & Commit**
   - Compile release binary (`swift build -c release`), install to `/Applications/ZeroDrive.app`, restart app, verify mount and UI, update [`STATUS.md`](../STATUS.md), and commit all changes to Git.

---

## 2. Concrete Step-by-Step Instructions (For Any Session or Agent)

### Step 1: Audit `~/Desktop/MAIN` vs. R2 Vault `MAIN`
- **Command:**
  ```bash
  rclone lsf primary_vault:zerodrive-vault-prod/usr_andrew_8bc7fb477f/MAIN -R --files-only --format "ps" > /tmp/r2_main_files.txt
  ```
- **Verification:** Compare `/tmp/r2_main_files.txt` against local `/Users/Naegele/Desktop/MAIN`. For any local file that is materialized on disk (`st_flags & 0x40000000 == 0`) AND already exists in `/tmp/r2_main_files.txt` with the exact same byte size, delete the local copy to free SSD space immediately without touching unuploaded files.

### Step 2: Upgrade `turbo-migrate-dashboard.py` (1-by-1 Hydration + `--leave-symlink` + Activity Log)
- **File:** `/Users/Naegele/_LAB/zerodrive/turbo-migrate-dashboard.py`
- **Changes:**
  1. Parse `--leave-symlink` CLI flag.
  2. In `process_space()`:
     - Move all currently local files (`ready_local`) first in batches of 250 via `rclone move --files-from`.
     - For `cloud_only` (`SF_DATALESS`) files: sort smallest-to-largest, and for files >50 MB, hydrate strictly **one file at a time** (`hydrate_single_file(fp)`), wait until `not is_dataless(fp)`, immediately `rclone move` that file to R2, and verify removal before requesting the next file from iCloud/FileProvider.
  3. When `--leave-symlink` is passed and `source_dir` is a directory: once all files in `source_dir` are moved to `~/ZeroDrive/My Drive/<dest_subfolder>`, remove empty subdirectories in `source_dir`, create symlink `os.symlink(target_mount_path, source_dir)`, and record the symlink entry in `~/.config/rclone/zerodrive-symlinks.json`.
- **Verification:** Run a test folder move with `--leave-symlink` on a sample test directory and verify `readlink` and file access through the symlink.

### Step 3: Update Swift UI & Core (`ZeroDriveProject`)
- **Files:**
  - `ZeroDriveProject/Sources/UI/TransferConfirmationSheet.swift`
  - `ZeroDriveProject/Sources/Core/TurboMigrationManager.swift`
  - `ZeroDriveProject/Sources/UI/MenuBarPopoverView.swift`
  - `ZeroDriveProject/Sources/ZeroDriveApp.swift`
  - `ZeroDriveProject/Sources/UI/FabricDriveMigrationCard.swift`
  - `ZeroDriveProject/Sources/UI/MainStudioWindow.swift`
  - `ZeroDriveProject/Sources/UI/TransfersView.swift`
  - `ZeroDriveProject/Sources/Core/RcloneDaemonSupervisor.swift`
- **Verification:** `cd /Users/Naegele/_LAB/zerodrive/ZeroDriveProject && swift build -c release` must compile with zero errors, and `/Applications/ZeroDrive.app` must launch and mount `~/ZeroDrive/My Drive`.

### Step 4: Deploy & Verify on `naegele-mm` (`100.114.74.17`)
- **Commands:**
  ```bash
  ssh 100.114.74.17 "hostname && df -h /"
  ```
  Copy `/Applications/ZeroDrive.app` and `~/.config/rclone/{rclone.conf,zerodrive-vault.json}` to `naegele-mm`, launch `/Applications/ZeroDrive.app` on `naegele-mm`, and run `ls -la ~/ZeroDrive/"My Drive"` on `naegele-mm`.
- **Verification:** `naegele-mm` lists all 9 top-level folders inside `~/ZeroDrive/My Drive` immediately.


---

## 3. Roadmapped Future Initiatives (To-Do)

### Phase 7: Native iCloud Integration & Cloud-to-Cloud UI Flow
- [ ] **Native In-App Sign-In & 2FA Flow**: Embed Apple ID credential entry + native 6-digit 2FA modal directly in ZeroDrive's GUI (leveraging rclone's SRP protocol without requiring Terminal interaction).
- [ ] **Connection Presence & Session Management**: Display live iCloud connection status badge in `Devices & Clouds` with 1-click token refresh (tokens expire after 30 days).
- [ ] **Interactive Remote Cloud Browser**: Browse remote iCloud Drive folders (`icloud_direct:`) in a Finder-like modal, select specific items, and execute **Move** (drain to free space) or **Copy** directly into the ZeroDrive Vault.
- [ ] **iCloud Photos Ingestion**: Leverage rclone's `photos` service backend to allow one-click cloud-to-cloud archiving of Apple Photos into ZeroDrive.

### Phase 8: Drive Customization & Headless VPS / AI Agent Shared Filesystem
- [ ] **Drive Renaming in UI**: Provide user-facing setting in the app to customize the drive name and mount alias (e.g., renaming "My Drive" to a custom branded or workspace name).
- [ ] **1-Line Headless Linux / VPS Mount Script (`curl ... | bash`)**: Provide a 1-command setup for remote Linux VPS boxes, cloud VMs, and Docker containers that mounts the user's ZeroDrive vault (or a scoped directory like `My Drive/_AGENT_WORKSPACE`) directly at `/mnt/zerodrive` via FUSE.
- [ ] **Bidirectional Agent-to-Finder Sync**: Any code, logs, or files generated by an AI coding agent running on the VPS write directly to `/mnt/zerodrive` and sync instantly to the user's Mac Finder at `~/ZeroDrive/My Drive/_AGENT_WORKSPACE` with 0 local SSD disk used.
- [ ] **ZeroDrive Agent MCP Server (Optional Alternative)**: Provide a Model Context Protocol (MCP) server for agents that prefer structured tool calls (`read_file`, `write_file`) over raw OS mounts.

---

## 4. Long-Term / Post-V1 Roadmap (Eventually)

### Phase 9: Apple FileProvider Framework & Mac App Store Edition (Post-V1)
*Context: We intentionally ship the direct Notarized DMG first to avoid Apple's 15–30% fee, bypass App Sandbox restrictions, and maintain the fast, flexible loopback NFS engine. Once V1 is 100% live and proven, we can build the App Store edition.*
- [ ] **Native `NSFileProviderReplicatedExtension` Implementation**: Build a modern macOS FileProvider extension target living in `~/Library/CloudStorage/ZeroDrive`.
- [ ] **Custom Hydration & Eviction Controller**: Enforce strict rate limits and lazy chunk fetching inside our extension to completely prevent the runaway download loops, memory leaks, and `MMCS` cache hoarding that plague Apple's `bird` daemon.
- [ ] **App Sandbox & App Group Hardening**: Package the rclone storage core into a static framework communicating with the host app via App Groups (`com.apple.security.application-groups`).
- [ ] **Mac App Store Submission**: Submit the sandboxed FileProvider edition to the Mac App Store for non-technical retail users.



---

## 5. Post-Launch Roadmap & Long-Term Expansion (Post-V1)

### Phase 10: Multi-Drive Architecture, Sub-Drives & Free Tier Mechanics
- [ ] **Multi-Drive & Sub-Drive Support**: Allow users to provision and mount multiple distinct drives in Finder (e.g. "Work Drive", "Personal Archive", "Client Vault") or create isolated sub-drives with partitioned storage quotas.
- [ ] **Cloudflare R2 Free Tier Accounting Architecture**:
  - *Cloudflare Rule:* Cloudflare provides 10 GB/month of free storage per Cloudflare account across all buckets combined (not 10 GB per bucket/drive).
  - *ZeroDrive Free Tier Strategy:* For user-facing Free Tiers (e.g. a "10 GB Free Forever" starter plan), ZeroDrive will track usage at the user/tenant prefix level inside Cloudflare D1 or provision dedicated multi-tenant prefixes with automated soft/hard limits.

### Phase 11: Public Cloud-Links & Web-Based Shared Drive Experience
- [ ] **Public / Expiring Cloud Links**: Generate secure public sharing links (pre-signed R2 URLs with customizable expiration and password protection) directly from Finder (via context menu Quick Actions or the ZeroDrive app) for any file or folder.
- [ ] **Web Application Workspace (ZeroDrive Web)**:
  - Responsive web client allowing users to log in, browse directory trees, preview media/documents, and upload/download files from any browser.
  - Authentication supporting Google OAuth, Apple ID, GitHub OAuth, and passwordless Magic Links.
- [ ] **Google Drive / Mountain Duck-Style Shared Drives & Team Collaboration**:
  - Provision shared team drives where multiple invited members can access, read, and write to shared directory hierarchies simultaneously.
  - Granular permission control: "Read Only" (community/public view-only link) vs. "Read/Write" (collaborator/team access).
  - "Join Drive via Link": One-click invitation links that immediately mount the shared folder into the recipient's ZeroDrive app or web dashboard.

### Phase 12: Developer & Agent Platform (API, CLI & Hosted MCP Server)
- [ ] **ZeroDrive REST & GraphQL API**:
  - Programmatic endpoints to authenticate, create/delete sub-drives, manage read/write invitation tokens, query folder hierarchies, and trigger server-side cloud-to-cloud copies.
- [ ] **ZeroDrive Developer CLI (`zd`)**:
  - High-performance, lightweight headless CLI binary for macOS, Linux, and Windows.
  - *Token Optimization Value:* Essential for vibe coders and AI agents running in terminal sandboxes (Claude Code, Cursor, Codex). Agents can run `zd ls /path`, `zd cat file.txt --lines 1-50`, or `zd grep "pattern"` to fetch precise context directly without burning hundreds of thousands of LLM tokens on bloated directory dumps.
- [ ] **ZeroDrive Hosted Model Context Protocol (MCP) Server**:
  - Official MCP server integration for Claude Desktop, ChatGPT plugins, Cursor, and headless cloud agents. Exposes native tools (`read_file`, `write_file`, `search_vault`, `share_link`) governed by the user's ZeroDrive API key.
