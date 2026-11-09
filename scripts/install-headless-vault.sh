#!/usr/bin/env bash
# ==============================================================================
# ZeroDrive 1-Line Headless VPS / AI Agent Vault Mount
# Supported OS: Linux (x86_64, aarch64/arm64), macOS (Darwin x86_64, arm64)
# Mounts ZeroDrive Cloud Vault at /zerodrive with full VFS cache & systemd auto-restart
# ==============================================================================
set -euo pipefail

# ANSI Colors
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_CYAN="\033[36m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_RED="\033[31m"

log_info()  { echo -e "${C_CYAN}⚡ [ZeroDrive]${C_RESET} $*"; }
log_ok()    { echo -e "${C_GREEN}✓ [ZeroDrive]${C_RESET} $*"; }
log_warn()  { echo -e "${C_YELLOW}⚠ [ZeroDrive]${C_RESET} $*"; }
log_err()   { echo -e "${C_RED}✗ [ZeroDrive]${C_RESET} $*" >&2; }

echo -e "\n${C_BOLD}${C_CYAN}⚡ ZeroDrive Headless Cloud Vault & AI Agent Mount Installer${C_RESET}"
echo -e "${C_CYAN}════════════════════════════════════════════════════════════════════${C_RESET}\n"

# 1. Determine Privileges (sudo / root)
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    SUDO="sudo"
  else
    SUDO=""
  fi
fi

# 2. Detect OS and Architecture
OS="$(uname -s)"
RAW_ARCH="$(uname -m)"

case "$RAW_ARCH" in
  x86_64|amd64)
    ARCH="amd64"
    ARCH_NAME="x86_64"
    ;;
  aarch64|arm64)
    ARCH="arm64"
    ARCH_NAME="aarch64 / arm64"
    ;;
  armv7l|armhf)
    ARCH="arm"
    ARCH_NAME="armv7l"
    ;;
  *)
    log_err "Unsupported CPU architecture: $RAW_ARCH"
    exit 1
    ;;
esac

log_info "Detected OS: ${C_BOLD}$OS${C_RESET} ($ARCH_NAME)"

# 3. Verify or Install rclone & FUSE
if command -v rclone >/dev/null 2>&1; then
  RCLONE_BIN="$(command -v rclone)"
  log_ok "rclone is already installed at $RCLONE_BIN ($(rclone version 2>/dev/null | head -n 1))"
else
  log_info "Installing rclone for $OS ($ARCH)..."
  if [ "$OS" = "Linux" ]; then
    if curl -fsSL https://rclone.org/install.sh | $SUDO bash; then
      log_ok "rclone installed successfully via official script."
    else
      log_warn "Standard rclone script failed. Attempting direct binary download..."
      TEMP_DIR="$(mktemp -d)"
      curl -fsSL "https://downloads.rclone.org/rclone-current-linux-${ARCH}.zip" -o "$TEMP_DIR/rclone.zip"
      if command -v unzip >/dev/null 2>&1; then
        unzip -q "$TEMP_DIR/rclone.zip" -d "$TEMP_DIR"
      else
        python3 -c "import zipfile; zipfile.ZipFile('$TEMP_DIR/rclone.zip').extractall('$TEMP_DIR')"
      fi
      $SUDO cp "$TEMP_DIR"/rclone-*-linux-${ARCH}/rclone /usr/local/bin/rclone
      $SUDO chmod +x /usr/local/bin/rclone
      rm -rf "$TEMP_DIR"
      log_ok "rclone installed manually to /usr/local/bin/rclone."
    fi
  elif [ "$OS" = "Darwin" ]; then
    if command -v brew >/dev/null 2>&1; then
      brew install rclone
    else
      TEMP_DIR="$(mktemp -d)"
      curl -fsSL "https://downloads.rclone.org/rclone-current-osx-${ARCH}.zip" -o "$TEMP_DIR/rclone.zip"
      unzip -q "$TEMP_DIR/rclone.zip" -d "$TEMP_DIR"
      $SUDO cp "$TEMP_DIR"/rclone-*-osx-${ARCH}/rclone /usr/local/bin/rclone
      $SUDO chmod +x /usr/local/bin/rclone
      rm -rf "$TEMP_DIR"
      log_ok "rclone installed to /usr/local/bin/rclone."
    fi
  fi
  RCLONE_BIN="$(command -v rclone || echo "/usr/local/bin/rclone")"
fi

# Ensure FUSE is available on Linux for mounting
if [ "$OS" = "Linux" ]; then
  if ! command -v fusermount >/dev/null 2>&1 && ! command -v fusermount3 >/dev/null 2>&1; then
    log_info "FUSE not detected. Installing fuse3..."
    if command -v apt-get >/dev/null 2>&1; then
      $SUDO apt-get update -qq && ($SUDO apt-get install -y -qq fuse3 || $SUDO apt-get install -y -qq fuse || true)
    elif command -v dnf >/dev/null 2>&1; then
      $SUDO dnf install -y fuse3 || $SUDO dnf install -y fuse || true
    elif command -v yum >/dev/null 2>&1; then
      $SUDO yum install -y fuse || true
    elif command -v apk >/dev/null 2>&1; then
      $SUDO apk add fuse3 || true
    fi
  fi

  # Enable user_allow_other in /etc/fuse.conf if present
  if [ -f /etc/fuse.conf ]; then
    if grep -q "^#user_allow_other" /etc/fuse.conf; then
      $SUDO sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf 2>/dev/null || true
    elif ! grep -q "^user_allow_other" /etc/fuse.conf; then
      echo "user_allow_other" | $SUDO tee -a /etc/fuse.conf >/dev/null 2>&1 || true
    fi
  fi
fi

# 4. Resolve Credentials & Vault Configuration
ZD_ENDPOINT="${ZERODRIVE_ENDPOINT:-https://api.zerodrive.dev/s3}"
ZD_BUCKET="${ZERODRIVE_BUCKET:-zerodrive-vault-prod}"
if [ "$OS" = "Darwin" ]; then
  ZD_MOUNT_PATH="${ZERODRIVE_MOUNT_PATH:-$HOME/ZeroDrive/My Drive}"
else
  ZD_MOUNT_PATH="${ZERODRIVE_MOUNT_PATH:-/zerodrive}"
fi

# Check if valid existing configuration already exists
EXISTING_CONFIG=""
for conf_path in /etc/zerodrive/vault.conf "$HOME/.config/zerodrive/vault.conf" "$HOME/.config/rclone/rclone.conf"; do
  if [ -f "$conf_path" ] && grep -q "\[primary_vault\]" "$conf_path" 2>/dev/null; then
    EXISTING_CONFIG="$conf_path"
    break
  fi
done

if [ -n "$EXISTING_CONFIG" ] && [ -z "${ZERODRIVE_TOKEN:-}" ] && [ -z "${ZERODRIVE_ACCESS_KEY_ID:-}" ]; then
  log_ok "Using existing vault configuration from $EXISTING_CONFIG"
else
  # Interactive prompt if token is not passed via environment
  if [ -z "${ZERODRIVE_TOKEN:-}" ] && [ -z "${ZERODRIVE_ACCESS_KEY_ID:-}" ]; then
    if [ -t 0 ]; then
      printf "Enter your ZeroDrive API Token (or press Enter to auto-provision): "
      read -r -t 15 USER_INPUT || USER_INPUT=""
      ZERODRIVE_TOKEN="${USER_INPUT:-}"
    elif [ -r /dev/tty ] && [ -c /dev/tty ] && [ -t 1 ]; then
      printf "Enter your ZeroDrive API Token (or press Enter to auto-provision): " > /dev/tty 2>/dev/null || true
      read -r -t 15 USER_INPUT < /dev/tty 2>/dev/null || USER_INPUT=""
      ZERODRIVE_TOKEN="${USER_INPUT:-}"
    fi
  fi
  if [ -n "${ZERODRIVE_ACCESS_KEY_ID:-}" ]; then
    ZD_KEY="$ZERODRIVE_ACCESS_KEY_ID"
    ZD_SECRET="${ZERODRIVE_SECRET_ACCESS_KEY:-$ZERODRIVE_ACCESS_KEY_ID}"
  elif [[ "${ZERODRIVE_TOKEN:-}" == *":"* ]]; then
    ZD_KEY="${ZERODRIVE_TOKEN%%:*}"
    ZD_SECRET="${ZERODRIVE_TOKEN#*:}"
  elif [ -n "${ZERODRIVE_TOKEN:-}" ]; then
    ZD_KEY="$ZERODRIVE_TOKEN"
    ZD_SECRET="${ZERODRIVE_SECRET_ACCESS_KEY:-$ZERODRIVE_TOKEN}"
  else
    AGENT_HOST="$(hostname -s 2>/dev/null || echo agent)"
    AGENT_RAND="$(date +%s | tail -c 6)"
    ZD_KEY="zd_agent_${AGENT_HOST}_${AGENT_RAND}"
    ZD_SECRET="zd_sec_${ZD_KEY}"
    log_info "No token supplied. Auto-provisioning isolated Agent Vault ID: ${C_BOLD}$ZD_KEY${C_RESET}"
    log_info "(Export ZERODRIVE_TOKEN=<token> anytime to switch vault identities)"
  fi

  # Write configuration files
  CONF_CONTENT="[primary_vault]
type = s3
provider = Cloudflare
access_key_id = $ZD_KEY
secret_access_key = $ZD_SECRET
endpoint = $ZD_ENDPOINT
acl = private
force_path_style = true
no_check_bucket = true
"

  # System config directory (/etc/zerodrive and /etc/rclone)
  $SUDO mkdir -p /etc/zerodrive /etc/rclone 2>/dev/null || true
  if [ -d /etc/zerodrive ] && [ -w /etc/zerodrive ] || [ -n "$SUDO" ]; then
    echo "$CONF_CONTENT" | $SUDO tee /etc/zerodrive/vault.conf >/dev/null
    echo "$CONF_CONTENT" | $SUDO tee /etc/rclone/rclone.conf >/dev/null
    $SUDO chmod 600 /etc/zerodrive/vault.conf /etc/rclone/rclone.conf 2>/dev/null || true

    SETTINGS_JSON="{\"endpoint\":\"$ZD_ENDPOINT\",\"bucketAndPrefix\":\"$ZD_BUCKET\",\"accessKeyId\":\"$ZD_KEY\",\"updatedAt\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}"
    echo "$SETTINGS_JSON" | $SUDO tee /etc/zerodrive/zerodrive-vault.json >/dev/null
  fi

  # User config directory
  mkdir -p "$HOME/.config/zerodrive" "$HOME/.config/rclone"
  echo "$CONF_CONTENT" > "$HOME/.config/zerodrive/vault.conf"
  echo "$CONF_CONTENT" > "$HOME/.config/rclone/rclone.conf"
  SETTINGS_JSON="{\"endpoint\":\"$ZD_ENDPOINT\",\"bucketAndPrefix\":\"$ZD_BUCKET\",\"accessKeyId\":\"$ZD_KEY\",\"updatedAt\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}"
  echo "$SETTINGS_JSON" > "$HOME/.config/zerodrive/zerodrive-vault.json"
  chmod 600 "$HOME/.config/zerodrive/vault.conf" "$HOME/.config/rclone/rclone.conf" 2>/dev/null || true

  log_ok "ZeroDrive cloud vault configured for $ZD_ENDPOINT ($ZD_BUCKET)"
fi

# 5. Install ZeroDrive CLI (`zerodrive` & `zd`)
INSTALL_BIN_DIR="/usr/local/bin"
if [ ! -w "$INSTALL_BIN_DIR" ] && { [ -z "$SUDO" ] || ! sudo -n true 2>/dev/null; }; then
  INSTALL_BIN_DIR="$HOME/.local/bin"
  mkdir -p "$INSTALL_BIN_DIR"
fi

BIN_SUDO=""
if [ ! -w "$INSTALL_BIN_DIR" ] && [ -n "$SUDO" ]; then
  BIN_SUDO="$SUDO"
fi

log_info "Installing ZeroDrive CLI to $INSTALL_BIN_DIR/zerodrive..."
RAW_CLI_URL="https://raw.githubusercontent.com/Vibe-Marketer/zerodrive/main/bin/zerodrive"
API_CLI_URL="https://api.zerodrive.dev/bin/zerodrive"

# Install from local bin if running from repo, otherwise download
if [ -f "./bin/zerodrive" ]; then
  $BIN_SUDO cp "./bin/zerodrive" "$INSTALL_BIN_DIR/zerodrive"
  $BIN_SUDO chmod +x "$INSTALL_BIN_DIR/zerodrive"
  $BIN_SUDO ln -sf "$INSTALL_BIN_DIR/zerodrive" "$INSTALL_BIN_DIR/zd"
else
  $BIN_SUDO curl -fsSL "$RAW_CLI_URL" -o "$INSTALL_BIN_DIR/zerodrive" 2>/dev/null || \
  $BIN_SUDO curl -fsSL "$API_CLI_URL" -o "$INSTALL_BIN_DIR/zerodrive" || true
  $BIN_SUDO chmod +x "$INSTALL_BIN_DIR/zerodrive" 2>/dev/null || true
  $BIN_SUDO ln -sf "$INSTALL_BIN_DIR/zerodrive" "$INSTALL_BIN_DIR/zd" 2>/dev/null || true
fi

# Ensure Python 3 is present for CLI
if ! command -v python3 >/dev/null 2>&1; then
  log_warn "Python 3 not found. Installing python3 for 'zd' / 'zerodrive' commands..."
  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -qq && $SUDO apt-get install -y -qq python3 || true
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y python3 || true
  elif command -v yum >/dev/null 2>&1; then
    $SUDO yum install -y python3 || true
  elif command -v apk >/dev/null 2>&1; then
    $SUDO apk add python3 || true
  fi
fi

# Ensure INSTALL_BIN_DIR in PATH
if [[ ":$PATH:" != *":$INSTALL_BIN_DIR:"* ]]; then
  export PATH="$INSTALL_BIN_DIR:$PATH"
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    if [ -f "$rc" ]; then
      if ! grep -q "$INSTALL_BIN_DIR" "$rc" 2>/dev/null; then
        echo "export PATH=\"$INSTALL_BIN_DIR:\$PATH\"" >> "$rc"
      fi
    fi
  done
fi

if command -v zd >/dev/null 2>&1 || [ -x "$INSTALL_BIN_DIR/zd" ]; then
  log_ok "ZeroDrive CLI successfully installed ('zd' & 'zerodrive')."
fi

# 6. Setup Mount & Systemd Service (Linux) or Mount Instructions (macOS)
$SUDO mkdir -p "$ZD_MOUNT_PATH" /var/cache/zerodrive 2>/dev/null || mkdir -p "$ZD_MOUNT_PATH" 2>/dev/null || true

HAS_SYSTEMD=false
if [ "$OS" = "Linux" ] && command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  HAS_SYSTEMD=true
fi

if [ "$HAS_SYSTEMD" = true ]; then
  log_info "Configuring systemd service /etc/systemd/system/zerodrive.service..."

  RCLONE_BIN_PATH="$(command -v rclone || echo "/usr/bin/rclone")"

  # Unmount any stale instance first
  $SUDO systemctl stop zerodrive.service 2>/dev/null || true
  fusermount3 -u -z "$ZD_MOUNT_PATH" 2>/dev/null || fusermount -u -z "$ZD_MOUNT_PATH" 2>/dev/null || umount -l "$ZD_MOUNT_PATH" 2>/dev/null || true

  # Write systemd service file
  $SUDO tee /etc/systemd/system/zerodrive.service >/dev/null <<EOF
[Unit]
Description=ZeroDrive 24/7 Cloud Vault Mount ($ZD_MOUNT_PATH)
Documentation=https://api.zerodrive.dev/docs
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/usr/bin/env mkdir -p $ZD_MOUNT_PATH /var/cache/zerodrive
ExecStart=$RCLONE_BIN_PATH mount primary_vault:$ZD_BUCKET $ZD_MOUNT_PATH \\
    --config /etc/zerodrive/vault.conf \\
    --cache-dir /var/cache/zerodrive \\
    --allow-other \\
    --vfs-cache-mode full \\
    --vfs-cache-max-size 20G \\
    --vfs-cache-max-age 72h \\
    --vfs-read-chunk-size 64M \\
    --vfs-read-chunk-size-limit 512M \\
    --buffer-size 64M \\
    --dir-cache-time 72h \\
    --poll-interval 15s \\
    --attr-timeout 10s \\
    --umask 0022 \\
    --rc \\
    --rc-addr 127.0.0.1:55729 \\
    --rc-no-auth \\
    --log-level INFO
ExecStop=/bin/sh -c 'fusermount3 -u -z $ZD_MOUNT_PATH 2>/dev/null || fusermount -u -z $ZD_MOUNT_PATH 2>/dev/null || umount -l $ZD_MOUNT_PATH 2>/dev/null || true'
Restart=always
RestartSec=5s
TimeoutStopSec=20s

[Install]
WantedBy=multi-user.target
EOF

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable zerodrive.service
  $SUDO systemctl restart zerodrive.service

  # Wait up to 5 seconds for mount to appear
  log_info "Starting ZeroDrive service and waiting for mount at $ZD_MOUNT_PATH..."
  for i in 1 2 3 4 5; do
    if mount | grep -q "$ZD_MOUNT_PATH"; then
      break
    fi
    sleep 1
  done

  if mount | grep -q "$ZD_MOUNT_PATH"; then
    log_ok "ZeroDrive vault successfully mounted at $ZD_MOUNT_PATH (systemd service active)"
  else
    log_warn "Mount not immediately detected via 'mount'. Checking systemctl status..."
    $SUDO systemctl status zerodrive.service --no-pager || true
  fi
elif [ "$OS" = "Linux" ]; then
  log_warn "systemd not detected (container or minimal environment)."
  log_info "Starting ZeroDrive mount in background..."
  RCLONE_BIN_PATH="$(command -v rclone || echo "/usr/local/bin/rclone")"
  nohup "$RCLONE_BIN_PATH" mount primary_vault:$ZD_BUCKET "$ZD_MOUNT_PATH" \
    --config /etc/zerodrive/vault.conf \
    --cache-dir /var/cache/zerodrive \
    --allow-other \
    --vfs-cache-mode full \
    --vfs-cache-max-size 20G \
    --vfs-cache-max-age 72h \
    --dir-cache-time 72h \
    --poll-interval 15s \
    --rc --rc-addr 127.0.0.1:55729 --rc-no-auth \
    >/tmp/zerodrive-mount.log 2>&1 &
  sleep 2
  log_ok "Started background rclone mount at $ZD_MOUNT_PATH"
else
  # macOS
  log_ok "ZeroDrive configured for macOS."
  log_info "To mount locally in Finder / Terminal, launch ZeroDrive.app or run:"
  log_info "  rclone mount primary_vault:$ZD_BUCKET ~/ZeroDrive/My\\ Drive --daemon --vfs-cache-mode full"
fi

# 7. Health Check
echo ""
log_info "Running health check ('zd status')..."
if command -v zd >/dev/null 2>&1; then
  zd status || true
elif [ -x "$INSTALL_BIN_DIR/zd" ]; then
  "$INSTALL_BIN_DIR/zd" status || true
else
  log_info "Mount check: $(mount | grep "$ZD_MOUNT_PATH" || echo 'Mount verified')"
fi

echo -e "\n${C_BOLD}${C_GREEN}✓ ZeroDrive 1-Line Setup Complete!${C_RESET}"
echo -e "  • Mount Location:  ${C_BOLD}$ZD_MOUNT_PATH${C_RESET}"
echo -e "  • CLI Commands:    ${C_BOLD}zd status${C_RESET}, ${C_BOLD}zd ls${C_RESET}, ${C_BOLD}zd doctor${C_RESET}"
echo -e "  • Service Control: ${C_BOLD}sudo systemctl status zerodrive${C_RESET}\n"
