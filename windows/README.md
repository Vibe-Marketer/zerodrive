# ZeroDrive for Windows: Cloud Files Sync Architecture

ZeroDrive on Windows delivers instantaneous, two-way cross-platform sync with macOS and Linux. It pairs with Apple's `NSFileProviderReplicatedExtension` on Mac so that files saved in macOS Finder appear immediately in Windows File Explorer and vice versa.

---

## 1. Architectural Overview

ZeroDrive on Windows supports two complementary operational modes:

1. **Native Cloud Filter Provider (`zerodrive-sync.cs`)**:
   Uses the Windows Cloud Files API (`cfapi.dll` and `cldflt.sys` kernel filter). Files appear in File Explorer as true dataless placeholders (Reparse Tag `IO_REPARSE_TAG_CLOUD`), display Explorer sync status badges (cloud / checkmark / sync arrows), integrate with the Windows Shell "Always keep on this device" context menu, and hydrate on demand via the Windows kernel when an app opens them.

2. **Lightweight Zero-Dependency Sync Daemon (`sync-daemon.ps1`)**:
   A standalone PowerShell engine that runs on any modern Windows 10/11 system without requiring visual studio or compilers. It utilizes NTFS sparse files or Alternate Data Streams (`:zerodrive`), `System.IO.FileSystemWatcher`, Server-Sent Events (`/v1/events`), and activity ledger polling (`/v1/activity`) for real-time bi-directional synchronization.

```
+----------------------------------------------------------------------------------+
|                                Windows 10 / 11                                   |
|                                                                                  |
|   [ Windows File Explorer / Word / VS Code / Command Prompt ]                    |
|                               |                                                  |
|                               v                                                  |
|   [ C:\Users\<Username>\ZeroDrive (Pinned Navigation Pane Root) ]                |
|                               |                                                  |
|             +-----------------+-----------------+                                |
|             |                                   |                                |
|             v (Mode A: Native Cloud Files)      v (Mode B: Standalone Daemon)    |
|   [ cldflt.sys (Kernel Minifilter) ]     [ System.IO.FileSystemWatcher ]         |
|             |                                   |                                |
|             v                                   |                                |
|   [ zerodrive-sync.exe (cfapi.dll) ]            |                                |
|     - CfConnectSyncRoot (FETCH_DATA)            |                                |
|     - CfExecute (TRANSFER_DATA)                 |                                |
|             |                                   |                                |
|             +-----------------+-----------------+                                |
|                               |                                                  |
|                               v                                                  |
|                    [ HTTPS REST + SSE Engine ]                                   |
|                      - Bearer Token Auth                                         |
|                      - Windows Path Normalizer (\ <-> /)                         |
|                      - Lock / Sharing Violation Backoff                          |
+-------------------------------|--------------------------------------------------+
                                |
                                v
+----------------------------------------------------------------------------------+
|                Cloudflare Workers Global Edge (api.zerodrive.dev)                |
|                                                                                  |
|   - GET  /v1/files?recursive=true     (Initial tree enumeration)                 |
|   - GET  /v1/events                   (SSE real-time broadcast to devices)       |
|   - GET  /v1/activity                 (Ledger delta polling fallback)            |
|   - GET  /vault/download?path=...     (Byte-streaming download / hydration)      |
|   - POST /vault/upload?path=...       (Direct chunked PUT upload)                |
|   - POST /v1/files/write              (REST write & create endpoint)             |
|   - DELETE /v1/files?path=...         (Remote file deletion)                     |
+-------------------------------|--------------------------------------------------+
                                |
                                v
+----------------------------------------------------------------------------------+
|                  macOS 12+ (NSFileProviderReplicatedExtension)                   |
|                                                                                  |
|   [ Finder ] <-> [ ~/Library/CloudStorage/ZeroDrive ] <-> [ ~/ZeroDrive ]        |
+----------------------------------------------------------------------------------+
```

---

## 2. Windows Cloud Files API (`cfapi.dll`) Deep Dive

Windows Cloud Files API (`cfapi.dll`) is the native Windows equivalent of macOS FileProvider (`NSFileProviderReplicatedExtension`). It was introduced by Microsoft in Windows 10 (Fall Creators Update, build 1709) and is the exact API powering OneDrive, iCloud for Windows, Dropbox, and Box.

### Key Lifecycle Operations

1. **Sync Root Registration (`CfRegisterSyncRoot`)**:
   - Registers a local directory (e.g. `C:\Users\username\ZeroDrive`) as a registered sync root with Windows Storage Provider.
   - Sets population policies:
     - `CF_POPULATION_POLICY_PARTIAL`: Subdirectories can be populated on demand when expanded in Explorer.
   - Sets hydration policies:
     - `CF_HYDRATION_POLICY_PARTIAL`: Files are hydrated as chunks or on-demand when opened.

2. **Placeholder Creation (`CfCreatePlaceholders`)**:
   - Creates a placeholder file in the filesystem with the exact size, attributes, and modified timestamp of the cloud file without downloading its content.
   - File is marked with `FILE_ATTRIBUTE_REPARSE_POINT` and reparse tag `IO_REPARSE_TAG_CLOUD`.
   - File occupies 0 bytes of disk storage (`AllocationSize = 0`).

3. **Kernel Hydration Interception (`CfConnectSyncRoot`)**:
   - The sync client registers callback handlers with `cldflt.sys`:
     - `CF_CALLBACK_TYPE_FETCH_DATA`: Fired by `cldflt.sys` whenever an application attempts to read a dataless placeholder.
     - `CF_CALLBACK_TYPE_CANCEL_FETCH_DATA`: Fired if the user or app cancels the read before completion.
     - `CF_CALLBACK_TYPE_NOTIFY_DELETE`: Fired when a file is deleted in Explorer.
     - `CF_CALLBACK_TYPE_NOTIFY_RENAME`: Fired when a file is renamed or moved.

4. **Streaming Data Transfer (`CfExecute`)**:
   - Upon receiving `CF_CALLBACK_TYPE_FETCH_DATA`, the client fetches bytes from `https://api.zerodrive.dev/vault/download?path=...` in 64 KB to 4 MB blocks.
   - Calls `CfExecute` with `CF_OPERATION_TYPE_TRANSFER_DATA`, providing the byte range, buffer, and target file handle.
   - Once all ranges are transferred, Windows marks the file as hydrated. Explorer immediately updates the badge from a cloud icon to a green checkmark.

5. **Dehydration (`CfDehydratePlaceholder` / "Free up space")**:
   - Reclaims local SSD space by stripping data blocks while keeping the file metadata and cloud inode intact.

---

## 3. Real-Time Bidirectional Sync Flow

### Mac to Windows (Instant Appearance)
1. User on Mac edits or drops `proposal.docx` into `~/ZeroDrive`.
2. macOS FileProvider uploads the file to `api.zerodrive.dev` and logs the event.
3. Edge publishes an SSE message on `/v1/events`:
   ```json
   {
     "event": "file_written",
     "path": "MAIN/proposal.docx",
     "size": 482019,
     "modified": "2026-11-09T17:30:00Z",
     "source_device": "mac-book-pro"
   }
   ```
4. Windows client (connected to `/v1/events`) receives the message within ~50ms.
5. Windows client creates a 0-byte dataless placeholder `C:\Users\username\ZeroDrive\MAIN\proposal.docx`.
6. Windows File Explorer immediately shows the file with the cloud badge.
7. When the Windows user double-clicks `proposal.docx`, the client streams the content down transparently; Word opens without error.

### Windows to Mac (Instant Sync)
1. User on Windows creates or edits a file inside `C:\Users\username\ZeroDrive`.
2. `FileSystemWatcher` detects change (`Created` / `Changed` / `Renamed` / `Deleted`).
3. Client waits for file write completion using an exponential backoff lock checker to avoid `ERROR_SHARING_VIOLATION`.
4. Client uploads bytes via `POST /vault/upload?path=...` or `POST /v1/files/write`.
5. Edge worker records activity and notifies macOS FileProvider via SSE / delta ledger.
6. macOS FileProvider immediately receives the remote change and updates Finder.

---

## 4. Cross-Platform Safeguards

1. **Path Normalization**:
   - Windows uses backslashes (`\`); POSIX and cloud APIs use forward slashes (`/`).
   - Normalizer automatically sanitizes paths: converts `\` to `/` before calling ZeroDrive API, and converts `/` to `\` when interacting with Windows filesystem.
   - Filters out Windows-illegal characters (`:`, `*`, `?`, `"`, `<`, `>`, `|`) and trailing dots/spaces.
   - Ignores Windows system files (`desktop.ini`, `Thumbs.db`, `.tmp` temporary swap files from Office).

2. **File Lock Retries (`ERROR_SHARING_VIOLATION`)**:
   - Windows applications (e.g. Microsoft Word, Excel, Photoshop) frequently lock files exclusively while saving.
   - The sync client wraps all read/write operations in a retry loop:
     - Detects `IOException` with Win32 HResult `0x80070020` (`ERROR_SHARING_VIOLATION`) or `0x80070021` (`ERROR_LOCK_VIOLATION`).
     - Backoff strategy: 100ms, 250ms, 500ms, 1s, 2s up to 5 attempts before queueing for deferred retry.

3. **Loop Suppression (Echo Prevention)**:
   - When the client downloads a file or creates a placeholder, it registers the path in an internal in-memory ignore list.
   - When `FileSystemWatcher` fires for that path, the event is recognized as local hydration/echo and suppressed from uploading back to the cloud.

---

## 5. File Inventory

| File | Function |
| :--- | :--- |
| `windows/README.md` | Architecture design and Windows Cloud Files documentation. |
| `windows/sync-daemon.ps1` | Zero-dependency background PowerShell sync daemon with SSE and FileSystemWatcher. |
| `windows/zerodrive-sync.cs` | Native C# Cloud Files Provider with P/Invoke bindings for `cfapi.dll`. |
| `windows/install-zerodrive.ps1` | Windows installer: registers Explorer sidebar CLSID, SyncRoot, and Scheduled Task. |
| `windows/uninstall-zerodrive.ps1` | Cleanup uninstaller: unregisters services, registry keys, and scheduled tasks. |
| `windows/test-sync.ps1` | Diagnostic test suite for API connectivity, path normalization, and sync events. |

---

## 6. Quick Start

### Installation

Run in an elevated PowerShell prompt (Run as Administrator) on Windows:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\windows\install-zerodrive.ps1 -ApiToken "YOUR_ZERODRIVE_API_TOKEN"
```

The installer:
- Prompts for API token if not provided.
- Creates `C:\Users\<Username>\ZeroDrive`.
- Pins **ZeroDrive** directly to the Windows Explorer left navigation sidebar.
- Registers a Windows Scheduled Task `ZeroDriveSync` that starts automatically at logon in the background.

### Manual Verification

To run a test cycle:

```powershell
.\windows\test-sync.ps1 -Verbose
```
