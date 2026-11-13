---
name: organize-cloud-files
description: "Inspect, deduplicate, organize, and stream cloud or local files into ZeroDrive without filling local Mac SSD."
---

# Organize Cloud & Local Files Into ZeroDrive

Use this skill whenever the user wants to inspect, deduplicate, reorganize, copy, or move files from iCloud Drive, Google Drive, OneDrive, Dropbox, Fabric Drive, or local Mac folders into their ZeroDrive Cloud Vault (`~/ZeroDrive/My Drive`).

## Core Safety Rules

1. **Never Hydrate Cloud Stubs Just to Inspect Them**
   - On macOS APFS, iCloud and CloudStorage stubs have `SF_DATALESS` (`st_flags & 0x40000000`) and `st_blocks == 0`.
   - Always inspect using `os.lstat()` / `Darwin.lstat()` or `rclone lsjson` — NEVER open, `cat`, `md5`, or `NSWorkspace.icon(forFile:)` on cloud stubs just to sort or inspect them.
2. **Never Follow Symlinks into `~/ZeroDrive`**
   - User home shortcuts (`~/ZeroDrive`, `~/_BUSINESS`, `~/_CONTENT`, `~/_LIBRARY`, `~/_PERSONAL`, `~/_SKILLS`, `~/_SORT`, `~/_CAPTURES`) point into `~/.zerodrive/My Drive`. Always use `follow_symlinks=False` / `lstat` so you do not scan already-offloaded vault files.
3. **Never Move Protected System, App, or Live Database Files**
   - Keep `/System`, `/Applications`, `~/Library`, `.app`/`.framework`/`.photoslibrary`/`.fcpbundle` packages, `.git`, `node_modules`, build caches, and `.wal`/`.shm`/`.lock` files on the local Mac.

## Step 1: Metadata-Only Discovery & Duplicate Detection

Run a metadata-only scan (`os.lstat` for local/iCloud stubs, or `rclone lsjson` for connected cloud remotes):
- Record `logical_size = st.st_size`, `allocated_bytes = st.st_blocks * 512`, and `is_dataless = bool(st.st_flags & 0x40000000)`.
- **Detect exact-size sibling duplicates**: Group files in the same folder by `(parent_dir, logical_size)` where `logical_size >= 10 MB`.
  - Raw camera/OBS timestamped recordings (e.g. `2023-04-04_13-40-04.mp4`) sitting next to renamed copies (e.g. `Day 2 - Close More Deals Challenge.mp4`) with identical byte sizes should be flagged and excluded or deduplicated before uploading so you don't pay bandwidth twice.

## Step 2: Propose a Clean Folder Layout

Group files into clean semantic folders under `My Drive/<TargetRoot>` before transferring:
- `Courses & Training/` (course videos, workbooks, challenge recordings)
- `Videos & Renders/` (`.mp4`, `.mov`, `.mkv`, `.wav`, project exports)
- `Archives & Installers/` (`.zip`, `.7z`, `.dmg`, `.pkg`, `.iso`)
- `Design & Raw Media/` (`.psd`, `.fig`, `.ai`, `.dng`, raw images)
- `Documents & Data/` (`.pdf`, `.docx`, `.xlsx`, datasets, backups)

Present the proposed source -> destination mapping and any detected duplicates before running a destructive move.

## Step 3: Transfer Safely With Zero SSD Bloat

Read the vault prefix from `~/.config/rclone/zerodrive-vault.json` (`bucketAndPrefix`, e.g. `zerodrive-vault-prod/<user_prefix>`) and use `~/.config/rclone/rclone.conf`.

### A. Local Physical Files (`allocated_bytes > 0`)
Stream directly to `primary_vault` with `rclone` (bypasses local VFS spool):
```bash
RCLONE="/Applications/ZeroDrive.app/Contents/Resources/rclone"
CONF="$HOME/.config/rclone/rclone.conf"

# Copy (keep local) or Move (delete local only after size/checksum verification):
"$RCLONE" copyto "<local_file>" "primary_vault:<bucketAndPrefix>/<dest_path>" \
  --config="$CONF" --s3-upload-cutoff=32M --s3-chunk-size=16M \
  --s3-upload-concurrency=4 --disable-http2 --s3-disable-http2 --retries=3
```
If moving, verify the remote object size first:
```bash
"$RCLONE" lsjson "primary_vault:<bucketAndPrefix>/<dest_path>" --files-only --config="$CONF"
```
Only remove the local file after confirming `Size == local_logical_size`.

### B. iCloud Drive Folders (Direct RAM Stream — 0 Bytes Local SSD)
Prefer direct CloudKit HTTP streaming when `[icloud_direct]` is configured:
```bash
python3 /Users/Naegele/_LAB/zerodrive/stream-icloud-to-vault.py "<iCloudSubpath>" "<VaultDest>"
```

### C. Local iCloud / CloudStorage Stubs (Governed 1-by-1 Hydration)
When transferring `~/Desktop`, `~/Documents`, or `~/Library/CloudStorage/*` stubs locally, use ZeroDrive's governor script so >25 MB stubs hydrate strictly 1-by-1 with a hard free-space floor:
```bash
python3 /Users/Naegele/_LAB/zerodrive/turbo-migrate-dashboard.py "<source_path>" "<VaultDest>" [--copy]
```

### D. Connected External Cloud Remotes (`ext_drive:`, `ext_dropbox:`, `ext_onedrive:`)
Stream directly via `rclone copyto` or `rclone moveto` between remotes using `--config="$CONF"`.

## Step 4: Refresh Finder VFS Tree

If the ZeroDrive NFS daemon is running, refresh Finder immediately:
```bash
"$RCLONE" rc vfs/refresh recursive=true --rc-addr=127.0.0.1:55729 || true
```
