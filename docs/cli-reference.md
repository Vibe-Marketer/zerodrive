# ZeroDrive CLI (`zd`) — Technical Reference & Developer Manual

**Binary Name:** `zerodrive`  
**Terminal Symlink:** `zd -> zerodrive`  
**Installed Locations:** `~/.local/bin/zerodrive`, `~/.local/bin/zd` (in `$PATH` on `naegele-pro` and `naegele-mm`)  
**Storage Backend:** Cloudflare R2 (`https://api.zerodrive.dev/s3`) via `primary_vault`  
**Local Mount:** Loopback NFS at `~/.zerodrive-mount` $\rightarrow$ `~/ZeroDrive/My Drive`  
**Live Version:** `1.0.1`

---

## 1. Architecture: Mount vs. Direct CLI

ZeroDrive separates **interactive virtual filesystem browsing** from **high-throughput cloud operations**:

```
                       ┌─────────────────────────┐
                       │  User Terminal / Agents │
                       │    (Claude, zd, Finder) │
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
   - Reads files on demand and caches them in `~/.zerodrive-cache`.
2. **ZeroDrive CLI (`zd`):**
   - Interacts with Cloudflare R2 directly for metadata queries and transfers, bypassing the POSIX mount to avoid mount stalls.
   - Streams text lines or exact byte ranges without downloading entire large files to disk.
   - Interacts with the daemon's Remote Control port (`127.0.0.1:55729`) to trigger directory cache invalidations.

---

## 2. Path Resolution & Endpoint Classification

`zd` classifies endpoints into **LOCAL** or **REMOTE** based on explicit syntax and filesystem inspection:

| Syntax Pattern | Classified As | Target Resolution |
| :--- | :--- | :--- |
| `primary_vault:<path>` or `<remote>:<path>` | **REMOTE** | Used as an explicit remote vault string. |
| `vault:<path>` or `zd://<path>` | **REMOTE** | Resolved to `primary_vault:<tenant-prefix>/<clean-path>`. |
| `~/...`, `./...`, `../...` | **LOCAL** | Resolved to absolute local filesystem path. |
| `/Users/...`, `/tmp/...`, `/Volumes/...` | **LOCAL** | Known local system paths are resolved to local paths. |
| Inside `~/ZeroDrive/My Drive/<subpath>` | **REMOTE** | Strips local mount prefix and maps directly to vault. |
| Bare name (e.g. `Course`, `file.txt`) | **Contextual** | For query commands (`ls`, `size`, `cat`, `find`): defaults to **REMOTE** vault path.<br>For transfer commands (`cp`, `mv`): if it exists in the current local directory, it is **LOCAL**; otherwise, it is **REMOTE**. |

---

## 3. Copy & Move Semantics

### Copy (`zd cp <src> <dst>`)
- **File to Directory:** When the destination ends with a slash (`/`) or is an existing local directory, `zd` copies the file inside the target folder without altering its filename.
  ```bash
  # Upload single file into cloud folder
  zd cp ~/Desktop/report.pdf Course/
  # Download single file into local folder
  zd cp Course/report.pdf ~/Downloads/
  ```
- **File to File (Rename):** When the destination does not end with a slash and is not an existing directory, `zd` copies to that exact target filename.
  ```bash
  # Cloud-to-cloud file duplicate
  zd cp Course/report.pdf Course/report-backup.pdf
  ```
- **Folder to Folder:** Transfers all contents using parallel multi-stream workers.
  ```bash
  zd cp ~/Desktop/Project/ Course/Project/
  ```

### Move (`zd mv <src> <dst> [--symlink]`)
- Moves files using 32 parallel streams.
- **Empty-Directory Symlink Safety:**
  When moving a local folder to the cloud with `--symlink`:
  1. `zd` executes the transfer and verifies the process exit code.
  2. It attempts a bottom-up empty directory prune (`os.rmdir()`).
  3. **Data Protection Guard:** If any files remain in the source folder (such as untransferred files, excluded files, or permission errors), `zd` **aborts folder removal and refuses to create a symlink**, leaving remaining source files untouched.
  4. Only when the directory is completely emptied does it remove the empty shell, create the symlink `ln -s ~/ZeroDrive/"My Drive"/<dst> <src>`, and log it to `~/.config/zerodrive/zerodrive-symlinks.json`.

---

## 4. Command Reference

### `zd status [--json]`
Inspects local filesystem, loopback mount, daemon RC server, and migration telemetry.

- **Options:** `--json`, `--no-color`
- **Output Metrics:**
  - `mounted`: Whether `~/.zerodrive-mount` is mounted.
  - `macSsdFreeGB`: Local disk free space via APFS.
  - `vfsCacheBytes` / `vfsCacheFiles`: Active VFS cache size.
  - `vfsSyncState`:
    - `Idle (0 pending VFS uploads)`: Cache is clear.
    - `Uploading (X active, Y queued)`: Background VFS write-back in progress.
    - `Errors (N files failed upload)`: Upload failures detected.
    - `Unknown (Daemon offline)`: Mount daemon not reachable on loopback RC port.
  - `activeMigration`: Active bulk migration stream metrics, or `None active`.

### `zd ls [path] [-R] [--json]`
Lists files and folders with `--fast-list`.
- **Options:**
  - `-R`, `--recursive`: Recursively lists all nested files and subdirectories.
  - `--json`: Returns raw array of file objects (`Path`, `Name`, `Size`, `ModTime`, `IsDir`).
- **Target:** Defaults to vault root (`/`). Can specify any vault subfolder (e.g. `zd ls Course`).

### `zd size [path] [--json]`
Queries Cloudflare R2 metadata directly via `--fast-list --json`.
- **Target:** Vault root or subfolder (e.g. `zd size Course`).
- **Performance:** Bypasses POSIX `stat()` calls, querying thousands of files in seconds without mount stalls.

### `zd cat <path> [--lines N-M] [--head N] [--tail N] [--bytes OFFSET-END]`
Reads file contents directly.
- **Line Slicing:**
  - `--lines N-M`: Streams lines sequentially and terminates child process immediately once line $M$ is reached.
  - `--head N`: Streams first $N$ lines, closes pipe, and terminates child process without hanging.
  - `--tail N`: Uses a bounded FIFO queue (`collections.deque(maxlen=N)`) so memory usage is strictly limited to $N$ lines, regardless of file size.
- **Byte Ranges:**
  - `--bytes OFFSET-END`: Uses byte-offset and count streaming for true S3 byte-range reads.
- **Failure Behavior:** If the file does not exist, outputs an error to `stderr` and exits with code 1.

### `zd find <pattern> [path] [--json]`
Performs server-side wildcard matching across cloud file keys.
- **Syntax:** `zd find "*.mov" Course`
- **Options:**
  - Standard: lists matching paths up to 100 entries.
  - `--json`: returns a JSON object:
    ```json
    {
      "pattern": "*.md",
      "target": "primary_vault:zerodrive-vault-prod/usr_andrew_8bc7fb477f/Course",
      "count": 3832,
      "matches": [ ... ]
    }
    ```

### `zd tree [path] [--depth N] [--dirs-only]`
Generates a visual hierarchy tree of cloud folders using server-side listing.
- **Syntax:** `zd tree Course --depth 2`
- **Options:**
  - `-d N`, `--depth N`: Folder depth limit (default: 2).
  - `--dirs-only`: Display directories only.

### `zd share <path> [--hours N] [--json]`
Generates a public pre-signed Cloudflare R2 HTTPS URL.
- **Expiry Range:** 1 to 168 hours (1 hour to 7 days, default: 24).
- **Options:** `--json` outputs `{"target": ..., "expiryHours": ..., "url": ...}`.
- **Error Behavior:** Exits with code 2 if `--hours` is outside 1–168.

### `zd refresh [path] [-R] [--json]`
Invalidates loopback VFS directory cache via `POST http://127.0.0.1:55729/vfs/refresh`.
- **Target:** Defaults to `My Drive` (vault root). Can specify subfolders (e.g. `zd refresh Course`).
- **Options:** `-R`, `--recursive` refreshes subdirectories.
- **Response Verification:** Checks HTTP response and verifies `"OK"` status before reporting success.

### `zd symlinks [--json]`
Audits local folder shortcuts created by ZeroDrive moves.
- **Verification:** Inspects filesystem to verify whether each shortcut's local path is an active symlink (`os.path.islink()`).
- **Options:** `--json` outputs array of entries including `"isLink": true/false`.

### `zd doctor [--json]`
Runs a live health check verifying:
1. **Hosted MCP Server & API:** Connectivity to `https://api.zerodrive.dev/mcp` and `/v1/health`.
2. **OAuth & App Icon:** Discovery metadata and icon availability.
3. **Cloud Vault:** R2 connection and root collection count.
4. **Storage Engine:** Core binary and configuration files.
5. **Finder Mount:** Status of `~/ZeroDrive/My Drive`.

### `zd engine <command...>` (alias `zd raw`)
Passes arguments directly through to the underlying storage engine with pre-bound credentials.
- **Return Code:** Strictly propagates the underlying engine's exit code to the caller.

### `zd version [--json]`
Displays CLI version, storage backend, tenant prefix, and storage engine status.

---

## 5. Exit Codes & Error Propagation

The CLI follows standard POSIX exit code conventions:

| Exit Code | Meaning |
| :--- | :--- |
| `0` | Success. |
| `1` | Operational or transfer error (source not found, transfer failure, network error). |
| `2` | Command-line argument syntax error (unknown subcommand, invalid option). |
| `N > 2` | Direct engine exit code passed through from `zd engine` / `zd raw`. |

---

## 6. Runtime Configuration & State Files

All runtime configuration and telemetry files live in `~/.config/zerodrive/` (with automatic fallback to `~/.config/rclone/`):

1. **`vault.conf`:** Storage backend configuration, endpoints, and credentials.
2. **`zerodrive-vault.json`:** Active tenant prefix, quota, and storage preset.
3. **`migration-telemetry.json`:** Local bulk migration metrics.
4. **`remote-migration-telemetry.json`:** Remote migration metrics streamed from `naegele-mm`.
5. **`zerodrive-symlinks.json`:** Array of active local symlink mappings (`localPath`, `targetMountPath`, `folderName`, `createdTimestamp`).
6. **`migration-ledger.json`:** Permanent historical log of completed folder migrations.
