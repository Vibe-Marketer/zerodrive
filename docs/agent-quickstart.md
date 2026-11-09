# ZeroDrive Agent Quickstart Guide

Connect any AI coding agent, chatbot, or headless server to your ZeroDrive vault in seconds.

---

## 1. Local Agents on Your Mac (Claude Code, Cursor, Terminal, Python)

Local agents already have direct access out of the box via two interfaces:

### Option A: Direct Filesystem Mount
Tell your agent:
> "My cloud vault is mounted at `~/ZeroDrive/My Drive`. Read and write files directly there. See `ROUTER.md` in that directory for folder destinations."

### Option B: The `zerodrive` CLI (Fastest, Saves LLM Context Tokens)
Tell your agent:
> "Use the `zerodrive` CLI tool in your terminal for ZeroDrive operations. It queries Cloudflare R2 directly with sub-second response times and zero mount latency:
> - `zerodrive ls [folder]` — list contents
> - `zerodrive cat [file] --head 30` or `--lines 1-50` — read slices without blowing context
> - `zerodrive cp [local_file] [vault_path]` — write/upload files
> - `zerodrive find [pattern]` — search whole vault
> - `zerodrive size [folder]` — instant file count and total GB"

---

## 2. AI Desktop Apps via Model Context Protocol (MCP)

ZeroDrive has a built-in MCP server that gives AI models native tools (`zd_read`, `zd_write`, `zd_list`, `zd_search`, `zd_size`, `zd_share`).

### Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`)
Add to `mcpServers`:

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

### Cursor (`~/.cursor/mcp.json` or Project `.cursor/mcp.json`)
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

Once added, the agent has 6 native tools to explore, read slices, edit documents, and upload assets directly to the cloud vault.

---

## 3. Remote Cloud Agents (Headless VPS, Modal, Codespaces, Replit)

To connect an agent running on a cloud Linux machine without the Mac app:

1. Copy your vault credentials from `~/.config/rclone/rclone.conf` on your Mac.
2. Run on the remote machine:

```bash
# 1. Install rclone
curl https://rclone.org/install.sh | sudo bash

# 2. Configure ZeroDrive Vault
mkdir -p ~/.config/rclone
cat << 'EOF' > ~/.config/rclone/rclone.conf
[primary_vault]
type = s3
provider = Cloudflare
access_key_id = zd_r2_andrew_8bc7fb477f
secret_access_key = zd_sec_b07b3671b1c45b32195f8353d4df8945ee31448699a361b32b6f8192a9b03633
endpoint = https://api.zerodrive.dev/s3
acl = private
force_path_style = true
no_check_bucket = true
EOF

# 3. Mount as directory (or run zd CLI)
mkdir -p ~/ZeroDrive
rclone mount primary_vault:zerodrive-vault-prod/usr_andrew_8bc7fb477f ~/ZeroDrive --vfs-cache-mode=full --daemon
```

Now any cloud agent reads and writes to the exact same vault as your Mac in real time.
