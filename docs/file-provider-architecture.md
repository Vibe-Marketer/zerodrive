# ZeroDrive Native FileProvider Architecture

## Overview

ZeroDrive uses Apple's modern replicated file provider architecture (`NSFileProviderReplicatedExtension`, macOS 12+), replacing the loopback NFS daemon with native macOS Virtual File System (VFS) integration.

```
+-------------------------------------------------------------------------+
|                                 macOS                                   |
|                                                                         |
|  [ Finder / Apps / Terminal ] --> [ ~/ZeroDrive ] (Symlink)             |
|                                          |                              |
|                                          v                              |
|                         [ ~/Library/CloudStorage/ZeroDrive ]            |
|                                          |                              |
|                                          v                              |
|                           [ macOS fileproviderd ]                       |
|                                          |                              |
|                       (IPC via NSFileProviderExtension)                 |
+------------------------------------------|------------------------------+
                                           v
    +----------------------------------------------------------------+
    | ZeroDrive.app/Contents/PlugIns/ZeroDriveFileProvider.appex     |
    |                                                                |
    |  - FileProviderExtension (NSFileProviderReplicatedExtension)   |
    |  - FileEnumerator (NSFileProviderEnumerator with /v1/files)    |
    |  - FileProviderItem (NSFileProviderItem APFS placeholders)     |
    |  - Shared Keychain / App Group (group.co.aisimple.zerodrive)   |
    +------------------------------|---------------------------------+
                                   | HTTPS / REST / Bearer Auth
                                   v
    +----------------------------------------------------------------+
    | Cloudflare Workers Global Edge (api.zerodrive.dev)             |
    |                                                                |
    |  - GET  /v1/files/stat?path=...      (Sub-15ms head lookup)    |
    |  - GET  /v1/files?limit=500&cursor= (Cursor paginated listing)|
    |  - GET  /vault/download?path=...     (Byte-range HTTP 206)     |
    |  - POST /vault/upload?path=...       (Direct streaming PUT)    |
    |  - GET  /v1/activity                 (Remote delta ledger)     |
    +------------------------------|---------------------------------+
                                   v
    +----------------------------------------------------------------+
    | Cloudflare R2 Bucket (zerodrive-vault-prod)                    |
    |  - 37,131+ files, 337+ GB raw storage                          |
    +----------------------------------------------------------------+
```

---

## 1. Core Extension Components

### A. Extension Principal (`extension.swift`)
- Conforms to `NSFileProviderReplicatedExtension`.
- Implements:
  - `invalidate()`: Graceful cleanup upon domain removal.
  - `item(for:request:completionHandler:)`: Sub-15ms stat resolution calling `/v1/files/stat?path=...`.
  - `fetchContents(for:version:request:completionHandler:)`: Streams bytes directly into a temporary file using `/vault/download?path=...`.
  - `createItem(basedOn:fields:contents:options:request:completionHandler:)`: Uploads new files created locally to `/vault/upload?path=...`.
  - `modifyItem(_:baseVersion:changedFields:contents:options:request:completionHandler:)`: Streams edited file bytes on `Cmd+S` / close to `/vault/upload?path=...`.
  - `deleteItem(identifier:baseVersion:options:request:completionHandler:)`: Deletes remote files via `DELETE /v1/files?path=...`.

### B. Directory Enumerator (`file-enumerator.swift`)
- Conforms to `NSFileProviderEnumerator`.
- Handles folder browsing inside Finder:
  - Enumerates `.rootContainer` as vault root `/`.
  - Enumerates child folders by their relative vault paths (e.g., `MAIN`, `Course`).
  - Calls `GET /v1/files?path=<path>&limit=500&cursor=<cursor>`.
  - Maps pagination tokens directly into `NSFileProviderPage(data)`.
  - Solves the 37,131-file `MAIN` directory bottleneck by streaming 500 items per page on-demand.

### C. File Item (`file-provider-item.swift`)
- Conforms to `NSFileProviderItem`.
- Fields:
  - `itemIdentifier`: Vault relative path (e.g. `MAIN/document.pdf`). Root identifier is `.rootContainer`.
  - `parentItemIdentifier`: Parent directory path or `.rootContainer`.
  - `filename`: Base name of file.
  - `contentType`: Uniform Type Identifier (UTType) derived from extension / MIME type.
  - `documentSize`: Int64 byte size from `/v1/files/stat` or `/v1/files`.
  - `contentModificationDate`: ISO timestamp converted to `Date`.
  - `capabilities`: `[.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting]`.

---

## 2. Dataless Placeholder Mechanics

1. **Browsing:**
   - Finder displays files with 0 bytes downloaded locally.
   - macOS assigns each file a dataless APFS inode with the native cloud status badge.
   - Instant folder navigation: zero network payload beyond lightweight metadata JSON.

2. **Hydration (On-Demand Read):**
   - User double-clicks, previews with QuickLook (Spacebar), or an app (Photoshop, VS Code) opens the file.
   - `fileproviderd` triggers `fetchContents(for:version:)`.
   - Bytes stream down over HTTPS. Progress bar displays natively in Finder.
   - Once completed, APFS marks the file locally hydrated. Subsequent opens are 0ms instant local disk reads.

3. **Dehydration (Eviction):**
   - User can right-click any file/folder in Finder and select "Remove Download".
   - macOS purges the local blocks from APFS while keeping the placeholder intact, reclaiming local SSD space.

4. **Saving & Syncing Back:**
   - Saving in any local app modifies the APFS file.
   - macOS schedules an upload and calls `modifyItem`.
   - File streams directly to Cloudflare R2 via `POST /vault/upload`.
   - Remote activity log records the change.

---

## 3. Sandboxing & Shared Credentials

Because FileProvider extensions run out-of-process in a strict Apple sandbox:
- **App Group:** `group.co.aisimple.zerodrive`
- **Shared Storage:** `UserDefaults(suiteName: "group.co.aisimple.zerodrive")`
- **Stored Keys:**
  - `api_endpoint`: `https://api.zerodrive.dev`
  - `api_token`: Bearer token
  - `vault_prefix`: `usr_andrew_8bc7fb477f`
- When `ZeroDrive.app` launches or updates credentials, it writes to the shared App Group container. The extension reads the token directly without prompts.

---

## 4. Build, Codesigning & Deployment Target

- **App Extension Path:** `ZeroDrive.app/Contents/PlugIns/ZeroDriveFileProvider.appex`
- **Compiler:** `swiftc` Universal Binary (`arm64` + `x86_64`) targeting `macos13.0`
- **Codesigning Identity:** `Developer ID Application: Andrew Naegele (DTB456HJMJ)`
- **Frameworks:** `FileProvider`, `UniformTypeIdentifiers`, `Foundation`
- **Registration Command:** `NSFileProviderManager.add(domain)` called by `ZeroDriveApp.swift`.
