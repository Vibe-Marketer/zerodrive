# ZeroDrive Agent Quickstart Guide

Connect any AI coding agent, chatbot, desktop assistant, or cloud server to your ZeroDrive vault in seconds.

---

## 1. Overview: The 24/7 ZeroDrive Cloud Vault

ZeroDrive is an unlimited 24/7 cloud drive backed by Cloudflare R2 object storage. It provides unified, instant access across:
1. **Interactive macOS Finder & Terminal Mount:** Browse and edit files like a local drive at `~/ZeroDrive/My Drive`.
2. **High-Speed ZeroDrive CLI (`zd` / `zerodrive`):** Millisecond metadata queries, file slicing, and high-speed transfers without mount stalls.
3. **Hosted 24/7 MCP Server (`https://api.zerodrive.dev/mcp`):** Native Model Context Protocol (MCP) server supporting **both text and all binary files** (screenshots, creative crops, PDFs, MP4/MOV videos, and ZIP archives) with 1-click OAuth 2.0.

---

## 2. Connect Remote & Desktop AI Apps via MCP

ZeroDrive runs a hosted 24/7 MCP server with native OAuth 2.0 authentication. You do **not** need to manually generate or copy API keys or secrets.

- **MCP Endpoint:** `https://api.zerodrive.dev/mcp`
- **Authentication:** Native OAuth 2.0 (1-click Google Sign-In)
- **Supported File Types:** Text, Markdown, JSON, Code, PNG/JPG/WebP Images, PDFs, MP4/MOV/WebM Videos, and ZIP Archives.

### A. Muse & Mobile AI Assistants
1. Add a new MCP connector in settings:
   - **URL:** `https://api.zerodrive.dev/mcp`
2. Tap **Sign In**.
3. A native sign-in window opens on `api.zerodrive.dev` with the ZeroDrive logo. Select your Google account.
4. Connection is complete! Muse now has access to all vault tools and resources.

### B. Claude Desktop
Add ZeroDrive to your Claude Desktop configuration (`~/Library/Application Support/Claude/claude_desktop_config.json`):

**Option 1: Hosted Remote MCP (Recommended):**
```json
{
  "mcpServers": {
    "zerodrive": {
      "url": "https://api.zerodrive.dev/mcp"
    }
  }
}
```

**Option 2: Local Stdio (Direct CLI Engine):**
```json
{
  "mcpServers": {
    "zerodrive": {
      "command": "zerodrive",
      "args": ["mcp"]
    }
  }
}
```

### C. Cursor
Add to `~/.cursor/mcp.json` or your project `.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "zerodrive": {
      "command": "zerodrive",
      "args": ["mcp"]
    }
  }
}
```

---

## 3. Built-In Native MCP Tools

Connected agents have access to verb-noun tools covering the entire vault lifecycle:

| Tool Name | What It Does |
| :--- | :--- |
| `get_file_tree` | Visual directory tree of the entire vault or subfolder (depth 1 to 4). |
| `list_files` | List files and folders with exact byte sizes, dates, and optional recursion. |
| `search_filenames` | Fast search across the vault by filename, pattern, or extension (`*.mp4`, `*.pdf`, `ROUTER`). |
| `grep_vault` | Search text contents inside files across the vault, returning matching snippets and line numbers. |
| `read_file` | Read text files with line slicing (`head`, `tail`, `lines`) or inspect images/PDFs directly. |
| `write_file` | Create or update any text, code, or binary file (supports text, base64, URL fetch, or append). |
| `edit_file` | Modify an existing file by replacing exact target text without rewriting the whole file. |
| `upload_binary_file` | Upload images, creative crops, PDFs, videos, or archives via base64 or remote URL. |
| `create_upload_urls` | **Streaming for Large Files & Batch Uploads:** Generates 1-hour pre-signed HTTP PUT URLs for streaming local binary files (36+ screenshots, 35MB+ assets, multi-GB videos) straight to R2 with zero LLM token overhead. |
| `get_download_url` | Direct HTTPS preview/download link with HTTP Byte-Range support (video streaming!). |
| `save_skill` | Save reusable Agent Skills into `_SKILLS/<verb-noun-name>/SKILL.md` (and bundled scripts/zips). |
| `run_vault_doctor` | Run a live health check on vault connectivity and return the complete operational manual. |
| `move_file` | Move or rename files inside the vault. |
| `copy_file` | Duplicate files inside the vault. |
| `delete_file` | Remove files from the vault. |
| `get_folder_size` | Calculate total file count and size in GB for any folder. |

---

## 4. Built-In Skills, Resources & Prompts

ZeroDrive automatically advertises built-in context to connected models:

### MCP Resources
- `zerodrive://vault/SKILL.md`: Operational manual showing models how to save text, images, videos, ZIPs, and skills.
- `zerodrive://vault/ROUTER.md`: Top-level directory routing map.
- `zerodrive://vault/AGENTS.md`: Workspace rules and conventions.
- `zerodrive://vault/CONTEXT.md`: System state and architecture.

### MCP Prompts
- `zerodrive-help`: Injects the complete ZeroDrive skill and operational guide.
- `zerodrive-doctor`: Triggers a full diagnostic check on the vault connection.
- `save-skill`: Guides the agent to package and save a reusable skill into `_SKILLS/`.

---

## 5. Saving Images, PDFs, Videos, ZIPs, and Skills

ZeroDrive is **not** limited to text. Connected agents can save any file type:

### A. Uploading Local Binary Files (Screenshots, Videos, ZIPs, Multi-MB Files)
When an agent has local binary files in its workspace/sandbox:
1. Agent calls `create_upload_urls` with target paths:
   ```json
   { "paths": ["MAIN/screenshots/screen-01.png", "MAIN/videos/demo.mp4", "MAIN/export.zip"] }
   ```
2. ZeroDrive returns a 1-hour pre-signed HTTP PUT upload URL for each file.
3. The agent uploads each file directly via HTTP PUT:
   ```bash
   curl -sS -X PUT --upload-file "./screen-01.png" "<upload_url>"
   ```
   **Zero LLM token waste. Full multi-megabyte / multi-gigabyte upload speed.**

### B. Uploading from Remote URLs
Agent calls `upload_binary_file` with `path` and `source_url: "https://example.com/asset.png"`. ZeroDrive downloads and stores it directly into R2.

### C. Creating Reusable Agent Skills
Agent calls `save_skill` with `name`, `description`, and `instructions`. ZeroDrive writes `_SKILLS/<name>/SKILL.md` and any bundled templates or helper scripts.

---

## 6. Local Coding Agents on macOS (Claude Code, Terminal Agents)

Coding agents on your local Mac have two high-speed access methods:

### Option 1: Direct Filesystem Mount
Tell your agent:
> "My cloud vault is mounted at `~/ZeroDrive/My Drive`. Read and write files directly there. Check `ROUTER.md` at the root for folder structure."

### Option 2: The `zerodrive` / `zd` CLI (Fastest, Saves Tokens)
Tell your agent:
> "Use the `zerodrive` (or `zd`) CLI in your terminal:
> - `zd ls [folder]` — list folder contents
> - `zd cat [file] --head 30` or `--lines 1-50` — stream file slices without loading entire files into context
> - `zd cp [src] [dst]` — parallel high-speed file copy
> - `zd mv [src] [dst] --symlink` — move local folder to cloud and leave a 0-byte local shortcut
> - `zd find [pattern]` — fast server-side file search
> - `zd size [folder]` — instant file count and total GB
> - `zd doctor` — check vault health and storage engine status"

---

## 7. Remote Linux & Cloud Agents (VPS, Codespaces, Docker)

To connect an agent running on a remote headless machine:

1. Install the `zerodrive` CLI binary onto the machine.
2. Place your ZeroDrive vault credentials in `~/.config/zerodrive/vault.conf`:
   ```ini
   [primary_vault]
   type = s3
   provider = Cloudflare
   access_key_id = <your-access-key-id>
   secret_access_key = <your-secret-access-key>
   endpoint = https://api.zerodrive.dev/s3
   acl = private
   force_path_style = true
   no_check_bucket = true
   ```
3. Run `zerodrive doctor` to verify the connection.
4. Alternatively, point any remote agent directly to the 24/7 hosted MCP server at `https://api.zerodrive.dev/mcp` via OAuth 2.0 with zero local configuration.

---

## 8. File & Skill Naming Rules

When creating files or saving skills in ZeroDrive, always follow these rules:

1. **Describe function, not ambition:** A filename must tell what is inside before opening it.
2. **Lowercase and hyphenated:** `extract-call-insights.py`, `payment-config.json`, `q3-revenue-report.md`.
3. **Verb-noun format for skills:** `create-substack-articles`, `research-youtube-topics`.
4. **Banned buzzwords:** Never use grand nouns to name utilities or skills:
   - *Banned:* `forge`, `engine`, `system`, `suite`, `hub`, `nexus`, `matrix`, `factory`, `mastery`, `ultimate`, `pro`, `2.0`.
   - *Example:* `mastery-system-forge.md` $\rightarrow$ `create-marketing-frameworks.md`.
