# ZeroDrive REST API & Fleet Reference

Complete reference for the ZeroDrive REST API deployed on `api.zerodrive.dev`. Designed for OpenAI Custom GPT Actions, autonomous AI agents, multi-device sync, and workflow automations.

- **Base URL:** `https://api.zerodrive.dev`
- **OpenAPI 3.1 Spec:** [`https://api.zerodrive.dev/openapi.json`](https://api.zerodrive.dev/openapi.json)
- **Interactive Documentation:** [`https://api.zerodrive.dev/docs`](https://api.zerodrive.dev/docs)
- **Hosted MCP Server:** [`https://api.zerodrive.dev/mcp`](https://api.zerodrive.dev/mcp)
- **Health Check:** [`https://api.zerodrive.dev/v1/health`](https://api.zerodrive.dev/v1/health)

---

## 1. Authentication

Every request requires authentication via Bearer token:

```bash
Authorization: Bearer <API_KEY_OR_OAUTH_TOKEN>
```

Alternatively, you can pass `?key=<TOKEN>` as a query parameter.

---

## 2. Vault Browsing & Sizing

### `GET /v1/tree`
Render a visual directory hierarchy of the vault or any subfolder.
- **Query Parameters:**
  - `path`: Subfolder to inspect (e.g. `MAIN`, `Course`). Empty for root.
  - `depth`: Levels deep to traverse (1 to 4, default: 2).

### `GET /v1/files`
List directory contents with byte sizes, modified timestamps, and MIME types.
- **Query Parameters:**
  - `path`: Directory path.
  - `recursive`: `true` or `false` (default: false).

### `GET /v1/size`
Compute exact total file count and byte/GB storage size.
- **Query Parameters:**
  - `path`: Folder path (e.g. `MAIN`, `_SKILLS`).

---

## 3. File Operations (Read, Write, Edit, Move, Delete)

### `POST /v1/files/read` (or `GET /v1/files/read?path=...`)
Read text files with optional line range slicing or get binary metadata + signed download URL.
- **JSON Body:**
  ```json
  {
    "path": "MAIN/notes.md",
    "lines": "1-50",
    "encoding": "utf-8"
  }
  ```

### `POST /v1/files/write`
Create, overwrite, or append to any file via UTF-8 text, base64 binary, or remote `source_url`.
- **JSON Body:**
  ```json
  {
    "path": "MAIN/log.txt",
    "content": "New entry\n",
    "append": true
  }
  ```

### `POST /v1/files/edit`
Surgical find-and-replace inside a file without overwriting the entire document.
- **JSON Body:**
  ```json
  {
    "path": "MAIN/config.json",
    "old_text": "v1.0.0",
    "new_text": "v1.1.0"
  }
  ```

### `POST /v1/files/move` & `POST /v1/files/copy`
Move, rename, or duplicate files in the vault.
- **JSON Body:**
  ```json
  {
    "source": "MAIN/draft.md",
    "destination": "MAIN/published.md"
  }
  ```

### `POST /v1/files/delete` (or `DELETE /v1/files?path=...`)
Delete a file from the vault.

### `POST /v1/files/batch`
Execute up to 50 copy, move, and delete actions atomically.

---

## 4. Binary, Video & Archive Streaming

### `POST /v1/files/upload-urls`
Mint 1-hour pre-signed direct HTTP PUT upload URLs for streaming local files (screenshots, PDFs, MP4/MOV videos, ZIPs up to 5 GB) with zero LLM token overhead.
- **JSON Body:**
  ```json
  {
    "paths": ["MAIN/demo.mp4", "MAIN/export.zip"]
  }
  ```

### `GET /v1/files/download-url`
Mint a 24-hour HTTPS download URL with HTTP Range (206) support for fast media streaming.
- **Query Parameters:** `path=MAIN/demo.mp4`

---

## 5. Search & Intelligence

### `GET /v1/search`
Fast server-side wildcard search across all files by filename or extension.
- **Query Parameters:** `query=.mp4&path=MAIN`

### `POST /v1/grep`
Search inside text, markdown, and code files, returning exact line numbers and snippets.
- **JSON Body:**
  ```json
  {
    "query": "Dan Kennedy",
    "path": "MAIN",
    "max_results": 20
  }
  ```

---

## 6. Agent Skills API (`_SKILLS/`)

### `GET /v1/skills`
List all installed skills or inspect a specific skill's markdown instructions.
- **Query Parameters:** `name=create-substack-articles` (optional)

### `POST /v1/skills`
Package and save a reusable skill directly into `_SKILLS/<verb-noun-name>/SKILL.md` along with bundled scripts or ZIP archives. Automatically validates lowercase hyphenated verb-noun names and blocks grand buzzwords.

---

## 7. Multi-Device Fleet & Symlink Registry

### `GET /v1/devices`
List all registered devices (Macs, Linux servers, cloud VMs), free disk space, mount state, and last heartbeat.

### `POST /v1/devices/heartbeat`
Send device SSD telemetry and mount health:
```json
{
  "device_id": "naegele-pro",
  "hostname": "naegele-pro.local",
  "os": "macOS 15.1",
  "free_gb": 151.0,
  "mount_status": "mounted",
  "mount_path": "/Users/Naegele/.zerodrive-mount",
  "version": "1.1.0"
}
```

### `GET /v1/symlinks` & `POST /v1/symlinks`
Track and register which local folder paths are symlinked to cloud vault folders across machines.

### `GET /v1/activity` & `POST /v1/activity`
Read and record ledger events across devices and agents.
