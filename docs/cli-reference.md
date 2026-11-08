# ZeroDrive CLI (`zd`) — Complete Technical Reference & Developer Manual

**Binary Name:** `zerodrive`  
**Terminal Symlink:** `zd -> zerodrive`  
**Installed Locations:** `~/.local/bin/zerodrive`, `~/.local/bin/zd` (in `$PATH` on `naegele-pro` and `naegele-mm`)  
**Storage Engine:** Cloudflare R2 (`https://zerodrive.aisimple.co/s3`) + multi-stream `rclone` engine + loopback NFS mount (`localhost:55730` $\rightarrow$ `~/ZeroDrive/My Drive`)

---

## 1. Architectural Overview & Philosophy

ZeroDrive separates **virtual filesystem browsing** from **high-throughput cloud offloading**:

```
                       ┌─────────────────────────┐
                       │  User Terminal / Agents │
                       │    (Claude, zd, Finder)  │
                       └────────────┬────────────┘
                                    │
             ┌──────────────────────┴──────────────────────┐
             │                                             │
      Interactive Browsing                           Direct CLI Ops
   (Loopback NFS via VFS)                      (Metadata, Streaming, Batch)
             │                                             │
             ▼                                             ▼
  ┌──────────────────────┐                     ┌──────────────────────┐
  │  ~/ZeroDrive/My Drive│                     │  ZeroDrive CLI (zd)  │
  │  (localhost:55730)   │                     │  (bin/zerodrive)     │
  └──────────┬───────────┘                     └──────────┬───────────┘
             │                                             │
             │           Loopback RC Control               │
             ├─────────────────────────────────────────────┤
             │           (http://127.0.0.1:55729)          │
             │                                             │
             ▼                                             ▼
    ┌─────────────────────────────────────────────────────────────┐
    │          Cloudflare Worker S3 Proxy & R2 Vault              │
    │         (primary_vault:zerodrive-vault-prod/usr_*)          │
    └─────────────────────────────────────────────────────────────┘
```

1. **Virtual Filesystem (Finder & Terminal Navigation):**
   - Mounted at `~/.zerodrive-mount` (`nobrowse,vers=3,tcp`) and symlinked to `~/ZeroDrive/My Drive`.
   - Reads files on demand and caches them in `~/.zerodrive-cache` with a guaranteed free-space floor.
2. **ZeroDrive CLI (`zd`):**
   - Interacts with Cloudflare R2 directly for instant metadata queries, bypassing the POSIX mount so commands like `zd size` and `zd ls` never stall Finder.
   - Streams exact line and byte ranges directly from cloud storage, saving AI agents from burning hundreds of thousands of LLM tokens on bulky file reads.
   - Controls the running daemon via loopback Remote Control (`127.0.0.1:55729`), triggering instant directory cache refreshes.

---

## 2. Path Resolution Engine

`zd` translates user inputs into appropriate cloud or local paths automatically:

| Input Argument | Resolved Target | Behavior |
| :--- | :--- | :--- |
| `zd ls` or `zd ls /` | `primary_vault:zerodrive-vault-prod/<tenant>/` | Vault root |
| `zd ls Course` or `zd ls /Course` | `primary_vault:zerodrive-vault-prod/<tenant>/Course` | Cloud collection |
| `zd ls ~/ZeroDrive/"My Drive"/Course` | `primary_vault:zerodrive-vault-prod/<tenant>/Course` | Detects mount path, strips mount root |
| `zd cp ~/Desktop/doc.pdf Course` | Src: `/Users/.../Desktop/doc.pdf`<br>Dst: `primary_vault:.../Course` | Uploads local file to cloud folder |
| `zd cp Course/doc.pdf ~/Desktop/` | Src: `primary_vault:.../Course/doc.pdf`<br>Dst: `/Users/.../Desktop/` | Downloads cloud file to local path |
| `zd mv ~/Desktop/Raw Course/Raw --symlink` | Moves `~/Desktop/Raw` to cloud | Leaves `lrwxr-xr-x` symlink at `~/Desktop/Raw` pointing to `~/ZeroDrive/My Drive/Course/Raw` |

---

## 3. Exhaustive Command Reference

### `zd status`
Displays live system health, loopback mount status, Mac SSD available storage, VFS cache metrics, active background streams, and tracked symlinks.

- **Syntax:** `zd status [--json] [--no-color]`
- **Speed:** ~15 ms
- **Example Output (Human):**
  ```text
  ⚡ ZeroDrive System Status
  ════════════════════════════════════════════════════
    Finder Mount:    ✓ Connected & Mounted
    Mount Path:      /Users/Naegele/ZeroDrive/My Drive
    Mac SSD Free:    157.6 GiB available (926 GB total)
    Local VFS Cache: 3.62 GB (8,166 files cached in RAM/SSD)
    Active Symlinks: 1 local folder shortcut active
    Vault Prefix:    zerodrive-vault-prod/usr_andrew_8bc7fb477f
    Transfer Status: Idle (All files synced)
  ════════════════════════════════════════════════════
  ```
- **Example Output (`--json` for AI Agents):**
  ```json
  {
    "mounted": true,
    "mountPath": "/Users/Naegele/ZeroDrive/My Drive",
    "daemonOnline": true,
    "macSsdFreeGB": 157.59,
    "macSsdTotalGB": 926.35,
    "vfsCacheBytes": 3890493820,
    "vfsCacheFiles": 8166,
    "activeSymlinks": 1,
    "activeStream": null,
    "vaultPrefix": "zerodrive-vault-prod/usr_andrew_8bc7fb477f"
  }
  ```

---

### `zd ls [path]`
High-speed directory listing with `--fast-list` and directory grouping.

- **Syntax:** `zd ls [path] [--json] [-R | --recursive]`
- **Speed:** 0.4s to 0.8s
- **Flags:**
  - `--json`: Outputs array of file objects (`Path`, `Name`, `Size`, `ModTime`, `IsDir`).
  - `-R`, `--recursive`: Lists all nested subdirectories.
- **Example:**
  ```bash
  zd ls Course
  ```

---

### `zd size [path]`
Queries Cloudflare R2 metadata in parallel using `--fast-list`. Calculates total object count and exact byte size without reading file contents or walking POSIX mount nodes.

- **Syntax:** `zd size [path] [--json]`
- **Speed:** ~8s for 10,000+ files (compared to 3+ minutes for Unix `du -sh`).
- **Example:**
  ```bash
  zd size Course
  ```
- **Example Output:**
  ```text
  📊 ZeroDrive Vault Size
  ════════════════════════════════════════════════
    Folder/Path: Course
    File Count:  10,311 files
    Total Size:  32.85 GB (32,850,043,196 bytes)
    Query Time:  7.94s (Cloudflare R2 metadata API)
  ════════════════════════════════════════════════
  ```

---

### `zd cat <path>`
Streams file contents directly from Cloudflare R2 or local cache without downloading the whole file to disk. Includes line-slicing controls specifically built for AI agents to preserve context window limits.

- **Syntax:** `zd cat <path> [--lines N-M] [--head N] [--tail N]`
- **Options:**
  - `--lines N-M`: Streams only line numbers $N$ through $M$ (e.g. `--lines 1-50`).
  - `--head N`: Streams only the first $N$ lines.
  - `--tail N`: Streams only the last $N$ lines.
- **Example:**
  ```bash
  zd cat ROUTER.md --head 15
  zd cat MAIN/COPY-FRAMEWORKS.md --lines 1-100
  ```

---

### `zd find <pattern> [path]`
Fast wildcard file search using server-side glob matching.

- **Syntax:** `zd find <pattern> [path] [--json]`
- **Examples:**
  ```bash
  zd find "*.mov" Course
  zd find "*invoice*" _BUSINESS --json
  ```

---

### `zd cp <source> <destination>`
Multi-stream parallel file or folder copy using 16 concurrent workers and 32 checkers.

- **Syntax:** `zd cp <src> <dst>`
- **Capabilities:**
  - Local Mac to Cloud Vault
  - Cloud Vault to Local Mac
  - Cloud folder to Cloud folder (server-side copy)
- **Example:**
  ```bash
  zd cp ~/Downloads/raw-asset.mov _CONTENT/creator-studio/
  ```

---

### `zd mv <source> <destination> [--symlink]`
High-speed parallel move (32 streams). When `--symlink` is passed on a local folder move, `zd` removes the local directory once files are safely verified in R2 and replaces it with a POSIX symlink pointing to the live mount (`~/ZeroDrive/My Drive/<dest>`).

- **Syntax:** `zd mv <src> <dst> [--symlink]`
- **Example:**
  ```bash
  zd mv ~/Desktop/OldProject MAIN/OldProject --symlink
  # -> Files moved to Cloud Vault
  # -> ~/Desktop/OldProject is now a symlink pointing to ~/ZeroDrive/My Drive/MAIN/OldProject
  # -> Logged to ~/.config/rclone/zerodrive-symlinks.json
  ```

---

### `zd share <path> [--hours 24]`
Generates an instant public pre-signed Cloudflare R2 HTTPS link.

- **Syntax:** `zd share <path> [--hours N]`
- **Default Expiry:** 24 hours (configurable up to 168 hours / 7 days).
- **Example:**
  ```bash
  zd share ROUTER.md --hours 12
  # -> Returns: https://zerodrive.aisimple.co/s3/zerodrive-vault-prod/...
  ```

---

### `zd refresh` (or `zd sync`)
Sends an immediate invalidation command to the live loopback NFS daemon (`POST http://127.0.0.1:55729/vfs/refresh`).

- **Speed:** < 20 ms
- **Purpose:** When an external script, AI agent, or second Mac (`naegele-mm`) uploads files to your vault, running `zd refresh` forces macOS Finder and Terminal to see the new files instantly without unmounting.

---

### `zd symlinks`
Inspects and verifies all local folder shortcuts created by ZeroDrive.

- **Syntax:** `zd symlinks`
- **Output:** Lists local shortcut paths, cloud targets, and whether the symlink is active on the filesystem.

---

### `zd raw <command...>`
Direct pass-through to the underlying rclone engine with your credentials, config file, and S3 parameters pre-bound.

- **Syntax:** `zd raw <rclone_command> [args...]`
- **Examples:**
  ```bash
  zd raw check ~/Desktop/Test primary_vault:zerodrive-vault-prod/usr_andrew_8bc7fb477f/Test
  zd raw md5sum primary_vault:zerodrive-vault-prod/usr_andrew_8bc7fb477f/ROUTER.md
  ```

---

### `zd version`
Prints CLI version, storage backend URL, tenant prefix, and underlying binary path.

---

## 4. Background Jobs & Stream Architecture

| Job Name | Script / Module | Triggers & Behavior |
| :--- | :--- | :--- |
| **Local Parallel Batch Offload** | `turbo-migrate-dashboard.py` | Moves local directories in 32-stream batches; hydrates dataless stubs (`SF_DATALESS`) strictly 1-by-1 to prevent `bird` bufferbloat. |
| **Direct RAM Stream** | `stream-icloud-to-vault.py` | Authenticates `[icloud_direct]` via Apple SRP protocol and streams files directly from Apple servers to Cloudflare R2 in RAM on `naegele-mm` (zero SSD bytes used). |
| **Daemon VFS Write-Back Spool** | `RcloneDaemonSupervisor.swift` | Runs in background with `--vfs-cache-mode=full`, `--vfs-write-back=15s`, `--vfs-cache-max-size=50G`, and `--vfs-cache-min-free-space=10G`. |
| **Remote Node Telemetry Poller** | `TurboMigrationManager.swift` | Polls `naegele-mm` over private SSH every 400ms when a remote stream is active to update the Mac menu bar and UI. |

---

## 5. Telemetry Schema & State Files

All runtime telemetry files live in `~/.config/rclone/`:

1. **`zerodrive-vault.json`:** Active tenant prefix, quota, and storage preset.
2. **`migration-telemetry.json`:** Live local transfer metrics (bytes moved, percent, speed in MB/s, ETA, active workers).
3. **`remote-migration-telemetry.json`:** Live metrics streamed from `naegele-mm`.
4. **`zerodrive-symlinks.json`:** Array of active local symlink mappings (`localPath`, `targetMountPath`, `createdTimestamp`).
5. **`migration-ledger.json`:** Permanent historical log of every completed space migration.
