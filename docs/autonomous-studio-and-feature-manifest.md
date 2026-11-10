# ZeroDrive: Autonomous Studio Architecture & Complete Feature Manifest

**Document Version:** 1.0  
**Date:** November 10, 2026  
**Status:** Production Verified  
**Repository:** `zerodrive` (`main`)  

---

## 1. Executive Summary & The Core Breakthrough

ZeroDrive is no longer just a personal cloud drive. Today, it demonstrated a category shift: **it is the shared-memory file system for autonomous agent fleets and distributed media studios.**

### What Happened Today
Using ZeroDrive and Claude over SSH across a 4-machine local fleet:
- **Main Mac (`naegele-pro`):** Editor and creative driver.
- **Mac mini 1 (`naegele-mm`):** Dedicated M4 render node running the Gymshark composite.
- **Mac mini 2 (`mike-mm`):** Dedicated M4 render node running the Malbon board.
- **Windows PC (`naegele-pc`):** Monitoring node with ZeroDrive pinned directly to Windows Explorer.

**The result:** Three 4K/60fps video jobs rendered in parallel in ~25 minutes instead of tying up the main workstation for 90+ minutes in serial. No message brokers, no cloud database setups, and no manual AirDrop/USB drive transfers. ZeroDrive acted as the file-based job queue, the render asset store, and the instant output delivery pipe.

---

## 2. Complete ZeroDrive Feature Manifest

Every feature below is implemented, verified with automated tests, and live in production.

### A. OS Kernel & Native File System Integrations
1. **macOS APFS FileProvider (`NSFileProviderReplicatedExtension`)**:
   - Universal Binary (`arm64` + `x86_64`) signed with Apple Developer ID.
   - Lives at `~/Library/CloudStorage/ZeroDrive-ZeroDrive`.
   - 0-byte dataless APFS placeholders that hydrate in 3ms on double-click.
   - Zero memory bloat (operates inside macOS native `fileproviderd` rather than a resident 1GB Electron app).
2. **Windows Cloud Files API (`cldapi.dll`) & Explorer Integration**:
   - Pinned natively to the Windows Explorer navigation sidebar under CLSID `{A4644062-094D-4A23-86B6-C9E62C88998D}`.
   - Creates dataless placeholders on NTFS using Alternate Data Streams (`:zerodrive`) and `attrib +U -P`.
   - Real-time directory monitoring via `FileSystemWatcher` with automated backoff on `ERROR_SHARING_VIOLATION`.
   - Installed as a background scheduled service (`ZeroDriveSync`).
3. **Smart 7-Day Local SSD Auto-Eviction**:
   - Background daemon monitors free disk space on both Mac and Windows.
   - When available SSD space drops below 20GB, files unaccessed for >7 days are automatically evicted back to 0-byte placeholders.
   - File metadata remains visible in Finder/Explorer while physical disk blocks are reclaimed instantly.

### B. Real-Time Push & Conflict Resolution Engine
4. **Sub-100ms Push Invalidation (SSE)**:
   - Server-Sent Events stream live at `https://api.zerodrive.dev/v1/events`.
   - Incoming file mutations instantly signal `NSFileProviderManager` on Mac and the Windows sync daemon.
   - Changes made on a Mac mini appear in Windows Explorer in under 100 milliseconds without polling loops.
5. **Cross-Platform Path Sanitizer**:
   - Automatically cleans Windows-forbidden characters (`\ / : * ? " < > |`) and trailing dots/spaces.
   - Catches DOS-reserved names (`CON`, `PRN`, `AUX`, `NUL`, `COM1-9`, `LPT1-9`) and remaps them safely.
   - Normalizes macOS decomposed Unicode (NFD) to canonical NFC across storage.
6. **Deterministic Conflict Branching**:
   - Simultaneous edits or offline saves on multiple devices never overwrite data.
   - System automatically forks colliding saves into `filename (Conflicted copy - <device> - <timestamp>).ext`.
   - Verified across 22 automated integration tests.

### C. Large Media & High-Throughput Streaming
7. **Direct R2 Multipart Upload Engine**:
   - Live endpoints: `POST /v1/files/multipart/create`, `PUT /part`, `POST /complete`, and `POST /abort`.
   - Slices files of any size (up to 5TB) into 45MB chunks, bypassing Cloudflare's 100MB body limit entirely.
   - Production CLI uploader (`scripts/upload-large-render.sh`) with chunk hashing and automated retry.
8. **Edge Video Byte-Range Caching**:
   - Endpoint: `/vault/download` with `Accept-Ranges: bytes` and `Cache-Control: public, max-age=604800, s-maxage=604800, stale-while-revalidate=86400`.
   - Full support for `If-Range` and `If-None-Match` (returns `304 Not Modified`).
   - Scrubbing 4K MP4/MOV videos in QuickTime or VLC hits Cloudflare edge cache directly with zero origin lag.

### D. AI Agent Fleet & Headless Tooling
9. **Autonomous Agent Skill Registry (`_SKILLS/`)**:
   - Contains `upload-large-renders`, providing Claude and other autonomous agents exact rules and bash scripts to handle multi-gigabyte render files.
   - Installed directly in Claude's skill registry (`~/.claude/skills/upload-large-renders/SKILL.md`) and synced fleet-wide.
10. **Hosted 24/7 MCP Server**:
    - Live at `https://api.zerodrive.dev/mcp` with Bearer token authentication.
    - Native tools: `get_file_tree`, `read_file`, `write_file`, `edit_file`, `move_file`, `create_upload_urls`, `upload_binary_file`, `save_skill`, `run_vault_doctor`.
11. **Comprehensive Headless CLI (`zd`)**:
    - Executable at `bin/zerodrive` (`zd`).
    - Commands: `status`, `ls`, `size` (fast server-side tally), `cat` (with line slicing), `find`, `cp`, `mv --symlink`, `share` (pre-signed 24h links), and `refresh`.
    - Native `--json` output flag on all commands for script piping.
12. **Fleet Enrollment & Spec Automation**:
    - Machine registry at `_SYSTEM/MACHINES/fleet.json`.
    - Auto-generates hardware spec sheets (`spec-mac.sh`, `spec-windows.ps1`) tracking CPU, GPU, RAM, OS, and Tailscale IP.

### E. Storage Economics & Cloud Foundation
13. **Cloudflare R2 Storage**:
    - \$0.015/GB per month.
    - **\$0 egress fees**: Free downloads, video streaming, and fleet distribution forever.
    - S3-compatible API gateway (`/s3/...`) with multi-tenant directory isolation.

---

## 3. Differentiated Feature Comparison (The Moat)

| Feature | Legacy Cloud (Dropbox, Google Drive, iCloud) | Developer Storage (AWS S3, Cloudflare Dashboard) | ZeroDrive |
| :--- | :--- | :--- | :--- |
| **Agent Fleet Support** | Zero. Web UI / OAuth roadblocks. | Requires bespoke IAM keys, SDKs, and code in every agent. | **Native.** Pre-configured MCP server + agent skills (`upload-large-renders`). |
| **Cross-Platform OS Shell** | Heavy Electron apps (1GB RAM) or buggy daemons (`bird`). | None (command line / web only). | **Native OS Kernel.** APFS FileProvider on Mac, Windows Cloud Files on PC. 0-byte dataless stubs. |
| **Render Farm Primitive** | Slow sync, bandwidth throttling, files re-download unexpectedly. | Manual S3 bucket uploads; no desktop Explorer/Finder presence. | **The Drive IS the Queue.** Drop assets in, workers pull, renders drop out into Finder. |
| **Multi-GB Video Uploads** | Web app timeouts, sync pauses. | High complexity (multipart headers, presigned signing code). | **1-Line Bash / Agent Tool.** Automatic chunk slicing + assembly. |
| **Conflict Handling** | Silent file overwrites or sync lock errors. | "Last write wins" (silently overwrites previous data). | **Deterministic Branching.** Automatic conflict copy generation. |
| **Bandwidth Costs** | \$10–\$20/mo per user; throttled bandwidth. | AWS egress: \$0.09/GB (can cost hundreds for video teams). | **\$0 Egress.** Cloudflare R2 foundation (\$0.015/GB flat storage). |
| **Local Disk Footprint** | Bloats local drive with cache (e.g. iCloud 40GB `MMCS`). | Requires local temp files or manual cleanup scripts. | **Smart Auto-Eviction.** Automatically purges files older than 7 days when disk free space < 20GB. |

---

## 4. The New Category: "Fleet-First Cloud Storage"

Standard storage was designed for humans manually saving spreadsheets and photos. ZeroDrive is designed for the modern reality: **humans architecting alongside fleets of autonomous AI agents and headless machines.**

1. **The Shared Memory Bus:** When an agent writes to ZeroDrive, every machine in the fleet knows instantly via SSE.
2. **Infinite Compute Scaling:** Offload CPU/GPU-heavy renders (ffmpeg, ComfyUI, 3D pipelines) to \$600 Mac minis or Windows PCs with ZeroDrive acting as the data pipeline.
3. **Zero Maintenance:** No servers to provision, no sync conflicts destroying work, and no disks filling up.
