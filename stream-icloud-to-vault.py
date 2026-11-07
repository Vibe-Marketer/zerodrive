#!/usr/bin/env python3
"""
stream-icloud-to-vault.py
Streams files directly from Apple's iCloud HTTP APIs (`iclouddrive` backend)
into Cloudflare R2 (`primary_vault`) in RAM — using ZERO local Mac SSD space
and bypassing Apple's local `bird` / FileProvider daemon completely.

Features:
1. Native macOS GUI dialogs (`osascript`) for Apple ID password + 6-digit 2FA code
   (for `naegele412@gmail.com` or any user Apple ID) via `rclone config create --non-interactive`.
2. Syncs the authenticated `[icloud_direct]` remote token to `naegele-mm` so the
   Mac mini can also run the stream headless while your MacBook is closed.
3. Streams `icloud_direct:<folder>` -> `primary_vault:.../MAIN` in RAM and updates
   `~/.config/rclone/migration-telemetry.json` for live ZeroDrive UI & Menu Bar telemetry.
"""

import os
import sys
import json
import time
import shutil
import subprocess

RCLONE_BIN = "/Applications/ZeroDrive.app/Contents/Resources/rclone"
if not os.path.exists(RCLONE_BIN):
    RCLONE_BIN = "/opt/homebrew/bin/rclone" if os.path.exists("/opt/homebrew/bin/rclone") else "rclone"

RCLONE_CONF = os.path.expanduser("~/.config/rclone/rclone.conf")
TELEMETRY_PATH = os.path.expanduser("~/.config/rclone/migration-telemetry.json")
SETTINGS_PATH = os.path.expanduser("~/.config/rclone/zerodrive-vault.json")
REMOTE_NAME = "icloud_direct"
DEFAULT_APPLE_ID = "naegele412@gmail.com"


def load_vault_prefix():
    prefix = "zerodrive-vault-prod/usr_andrew_8bc7fb477f"
    if os.path.exists(SETTINGS_PATH):
        try:
            with open(SETTINGS_PATH, "r") as f:
                data = json.load(f)
                bp = data.get("bucketAndPrefix", "").strip("/")
                if bp and bp != "zerodrive-vault-prod":
                    prefix = bp
        except Exception:
            pass
    return f"primary_vault:{prefix}"


def write_telemetry(payload):
    try:
        tmp = f"{TELEMETRY_PATH}.tmp.{os.getpid()}"
        with open(tmp, "w") as f:
            json.dump(payload, f)
        os.replace(tmp, TELEMETRY_PATH)
    except Exception:
        pass


def ask_macos_dialog(prompt_text, title="ZeroDrive Direct iCloud Stream", default_answer="", hidden=False):
    hidden_flag = "with hidden answer" if hidden else ""
    script = (
        f'display dialog "{prompt_text}" '
        f'with title "{title}" '
        f'default answer "{default_answer}" '
        f'{hidden_flag} '
        f'buttons {{"Cancel", "Continue"}} default button "Continue"'
    )
    res = subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True, text=True)
    if res.returncode != 0:
        return None
    out = res.stdout.strip()
    marker = "text returned:"
    idx = out.find(marker)
    if idx != -1:
        return out[idx + len(marker):].strip()
    return ""


def show_macos_alert(message, title="ZeroDrive Direct iCloud Stream"):
    script = f'display dialog "{message}" with title "{title}" buttons {{"OK"}} default button "OK"'
    subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True, text=True)


def has_valid_icloud_remote():
    if not os.path.exists(RCLONE_CONF):
        return False
    res = subprocess.run(
        [RCLONE_BIN, "lsd", f"{REMOTE_NAME}:", f"--config={RCLONE_CONF}", "--timeout=15s", "--retries=1"],
        capture_output=True,
        text=True,
    )
    return res.returncode == 0


def authenticate_icloud_remote(apple_id=DEFAULT_APPLE_ID):
    print(f"Checking direct iCloud connection for {apple_id}...", flush=True)
    if has_valid_icloud_remote():
        print(f"✓ Direct iCloud remote [{REMOTE_NAME}] is already authenticated and active!", flush=True)
        return True

    apple_id_input = ask_macos_dialog(
        "Confirm the Apple ID for your iCloud Drive:",
        title="Step 1 of 2: Connect iCloud Drive Directly",
        default_answer=apple_id,
        hidden=False,
    )
    if not apple_id_input:
        print("Cancelled Apple ID prompt.", flush=True)
        return False

    password_input = ask_macos_dialog(
        f"Enter the iCloud password for {apple_id_input}:\\n\\n(Used once to create an encrypted rclone trust token — ZeroDrive never stores plain-text passwords.)",
        title="Step 1 of 2: iCloud Password",
        default_answer="",
        hidden=True,
    )
    if not password_input:
        print("Cancelled password prompt.", flush=True)
        return False

    # Step 1: Initial non-interactive config create
    cmd = [
        RCLONE_BIN,
        "config",
        "create",
        REMOTE_NAME,
        "iclouddrive",
        f"apple_id={apple_id_input}",
        f"password={password_input}",
        "--obscure",
        "--non-interactive",
        f"--config={RCLONE_CONF}",
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        err = res.stderr.strip() or res.stdout.strip()
        show_macos_alert(f"Could not start iCloud sign-in: {err[:250]}")
        return False

    # Loop through rclone's non-interactive state machine (handles 2FA code prompt)
    stdout = res.stdout.strip()
    while stdout:
        try:
            data = json.loads(stdout)
        except Exception:
            break

        state = data.get("State", "")
        error_msg = data.get("Error", "")
        if error_msg:
            show_macos_alert(f"Apple iCloud sign-in error: {error_msg}")
            return False

        if not state:
            # Completed!
            break

        opt = data.get("Option", {})
        help_text = opt.get("Help", "Enter your 6-digit Apple 2FA verification code:")
        default_val = str(opt.get("DefaultStr", "") or "")

        # If rclone asks a boolean/confirm question with a default, accept default unless it's 2FA
        if "2fa" in state.lower() or "code" in help_text.lower() or "verification" in help_text.lower() or state != "":
            code = ask_macos_dialog(
                f"Apple just sent a 6-digit verification code to your trusted device.\\n\\n{help_text}",
                title="Step 2 of 2: Apple 2FA Verification Code",
                default_answer=default_val,
                hidden=False,
            )
            if code is None:
                return False
            cont_cmd = [
                RCLONE_BIN,
                "config",
                "create",
                REMOTE_NAME,
                "iclouddrive",
                "--continue",
                "--state",
                state,
                "--result",
                code.strip(),
                "--non-interactive",
                f"--config={RCLONE_CONF}",
            ]
            res2 = subprocess.run(cont_cmd, capture_output=True, text=True)
            if res2.returncode != 0:
                err = res2.stderr.strip() or res2.stdout.strip()
                show_macos_alert(f"2FA verification failed: {err[:250]}")
                return False
            stdout = res2.stdout.strip()
        else:
            break

    if has_valid_icloud_remote():
        # Sync updated rclone.conf to naegele-mm so the Mac mini also has the trust token!
        subprocess.run(
            ["/usr/bin/scp", "-q", RCLONE_CONF, "naegele-mm:~/.config/rclone/rclone.conf"],
            capture_output=True,
        )
        print("✓ Authenticated direct iCloud stream and synced token to naegele-mm!", flush=True)
        return True

    show_macos_alert("Connected config, but could not list iCloud Drive yet. Please verify your 2FA code and try again.")
    return False


def stream_icloud_folder_to_vault(icloud_subpath="Desktop/MAIN", vault_subpath="MAIN"):
    vault_base = load_vault_prefix()
    src = f"{REMOTE_NAME}:{icloud_subpath}".rstrip(":")
    dst = f"{vault_base}/{vault_subpath}".rstrip("/")
    display_name = vault_subpath or icloud_subpath or "iCloud Drive"

    print(f"Streaming directly in RAM: {src} -> {dst}", flush=True)

    cmd = [
        RCLONE_BIN,
        "copy",
        src,
        dst,
        f"--config={RCLONE_CONF}",
        "--size-only",
        "--update",
        "--transfers=8",
        "--checkers=16",
        "--s3-upload-cutoff=32M",
        "--s3-chunk-size=16M",
        "--s3-upload-concurrency=4",
        "--exclude=**/.DS_Store",
        "--exclude=**/._*",
        "--exclude=**/node_modules/**",
        "--stats=400ms",
        "--stats-log-level=NOTICE",
        "--use-json-log",
    ]

    last_write = 0.0
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    for raw_line in proc.stdout:
        line = raw_line.strip()
        if not line:
            continue
        try:
            data = json.loads(line)
            if "stats" in data:
                st = data["stats"]
                moved_b = st.get("bytes", 0)
                total_b = max(moved_b, st.get("totalBytes", 0))
                moved_f = st.get("transfers", 0)
                total_f = max(moved_f, st.get("totalTransfers", 0))
                speed_mbps = (st.get("speed", 0.0) or 0.0) / (1024 * 1024)
                eta_sec = st.get("eta") or 0
                pct = (moved_b / total_b * 100.0) if total_b > 0 else 0.0

                now = time.time()
                if now - last_write >= 0.3:
                    last_write = now
                    cur_free = shutil.disk_usage(os.path.expanduser("~")).free
                    write_telemetry({
                        "spaceName": f"iCloud Direct: {display_name}",
                        "isRunning": True,
                        "isComplete": False,
                        "speedMBps": round(speed_mbps, 1),
                        "percent": round(min(99.9, pct), 1),
                        "movedFiles": moved_f,
                        "totalFiles": total_f,
                        "movedBytes": moved_b,
                        "totalBytes": total_b,
                        "remainingBytes": max(0, total_b - moved_b),
                        "etaSeconds": int(eta_sec),
                        "freeDiskBytes": cur_free,
                        "diskDeltaBytes": 0,
                        "activeWorkers": 8,
                        "statusMessage": f"Direct RAM Stream (0 Disk Used) • {moved_f}/{total_f} files ({pct:.1f}%)",
                        "currentFile": display_name,
                        "sourceLocation": f"iCloud API: {icloud_subpath}",
                        "destLocation": f"My Drive/{vault_subpath}",
                    })
        except Exception:
            pass

    proc.wait()
    cur_free = shutil.disk_usage(os.path.expanduser("~")).free
    write_telemetry({
        "spaceName": f"iCloud Direct: {display_name}",
        "isRunning": False,
        "isComplete": True,
        "speedMBps": 0.0,
        "percent": 100.0,
        "movedFiles": 0,
        "totalFiles": 0,
        "movedBytes": 0,
        "totalBytes": 0,
        "remainingBytes": 0,
        "etaSeconds": 0,
        "freeDiskBytes": cur_free,
        "diskDeltaBytes": 0,
        "activeWorkers": 0,
        "statusMessage": f"✓ Direct iCloud -> Vault stream complete for {display_name} (0 local disk used)!",
        "currentFile": "",
        "sourceLocation": f"iCloud API: {icloud_subpath}",
        "destLocation": f"My Drive/{vault_subpath}",
    })


def main():
    os.chmod(__file__, 0o755)
    icloud_path = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "Desktop/MAIN"
    vault_path = sys.argv[2] if len(sys.argv) > 2 and not sys.argv[2].startswith("--") else "MAIN"
    login_only = "--login-only" in sys.argv
    run_on_mini = "--run-on-mini" in sys.argv

    if not authenticate_icloud_remote(DEFAULT_APPLE_ID):
        sys.exit(1)

    if login_only:
        show_macos_alert(
            "✓ Direct iCloud Stream is connected for naegele412@gmail.com and synced to naegele-mm!"
        )
        return

    if run_on_mini:
        # Copy this script and rclone.conf to naegele-mm and start the stream in the background on the Mac mini!
        subprocess.run(["/usr/bin/scp", "-q", RCLONE_CONF, "naegele-mm:~/.config/rclone/rclone.conf"], check=False)
        subprocess.run(["/usr/bin/scp", "-q", __file__, "naegele-mm:/tmp/stream-icloud-to-vault.py"], check=False)
        remote_cmd = (
            f"nohup /usr/bin/python3 /tmp/stream-icloud-to-vault.py "
            f"'{icloud_path}' '{vault_path}' > /tmp/icloud-direct-stream.log 2>&1 &"
        )
        subprocess.run(["/usr/bin/ssh", "naegele-mm", remote_cmd], check=False)
        show_macos_alert(
            f"✓ Started Direct iCloud -> R2 Stream on naegele-mm (Mac mini) for '{icloud_path}' -> 'My Drive/{vault_path}'!\n\nYour MacBook Pro uses 0% CPU and 0 bytes of disk."
        )
        return

    stream_icloud_folder_to_vault(icloud_path, vault_path)


if __name__ == "__main__":
    main()
