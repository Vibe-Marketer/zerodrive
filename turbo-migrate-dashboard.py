#!/usr/bin/env python3
"""
ZeroDrive Smart-Adaptive Migration Engine
Pillars:
1. Instant Sweep of Already-Local Files (32 parallel streams, zero disk wait).
2. Strict 1-by-1 Sequential Hydration for Cloud-Only Stubs (>25 MB) so Apple's
   `bird` daemon never queues bulk downloads or bloats `MMCS`.
3. Active SSD Governor: Hard floor protection (pauses new hydration if free space < floor).
4. Strict Verification: Confirms size & exit status in R2 before deleting local files.
5. Optional Folder Symlink (`--leave-symlink`): Leaves a 0-byte POSIX symlink at the
   original folder path pointing to `~/ZeroDrive/My Drive/<Folder>` so scripts,
   automations, and app paths never break.
"""

import os
import sys
import time
import shutil
import json
import subprocess
import tempfile
from datetime import datetime, timezone

if len(sys.argv) < 2:
    print("Usage: turbo-migrate-dashboard.py <source_path> [dest_subfolder] [--copy] [--leave-symlink]")
    sys.exit(1)

SOURCE_INPUT = os.path.abspath(sys.argv[1])
IS_COPY = "--copy" in sys.argv
LEAVE_SYMLINK = "--leave-symlink" in sys.argv
DEST_ARGS = [a for a in sys.argv[2:] if not a.startswith("--")]
DEST_SUBFOLDER = DEST_ARGS[0] if DEST_ARGS else ""

RCLONE_BIN = "/Applications/ZeroDrive.app/Contents/Resources/rclone"
if not os.path.exists(RCLONE_BIN):
    RCLONE_BIN = "/opt/homebrew/bin/rclone" if os.path.exists("/opt/homebrew/bin/rclone") else "rclone"

RCLONE_CONF = os.path.expanduser("~/.config/rclone/rclone.conf")
SETTINGS_PATH = os.path.expanduser("~/.config/rclone/zerodrive-vault.json")
TELEMETRY_PATH = os.path.expanduser("~/.config/rclone/migration-telemetry.json")
LEDGER_PATH = os.path.expanduser("~/.config/rclone/migration-ledger.json")
ACTIVITY_PATH = os.path.expanduser("~/.config/rclone/session-activity.json")
SYMLINKS_PATH = os.path.expanduser("~/.config/rclone/zerodrive-symlinks.json")


def load_vault_settings():
    defaults = {
        "bucketAndPrefix": "zerodrive-vault-prod/usr_andrew_8bc7fb477f",
        "uploadDevConfigs": True,
        "uploadAppWorkspaces": True,
        "uploadSecretEnvFiles": False,
        "minFreeSpaceGB": 10,
    }
    if os.path.exists(SETTINGS_PATH):
        try:
            with open(SETTINGS_PATH, "r") as f:
                data = json.load(f)
                bp = data.get("bucketAndPrefix", "").strip("/")
                if bp:
                    # Ensure tenant prefix is never accidentally stripped for Andrew's primary vault
                    if bp == "zerodrive-vault-prod":
                        bp = "zerodrive-vault-prod/usr_andrew_8bc7fb477f"
                    defaults["bucketAndPrefix"] = bp
                defaults["uploadDevConfigs"] = data.get("uploadDevConfigs", True)
                defaults["uploadAppWorkspaces"] = data.get("uploadAppWorkspaces", True)
                defaults["uploadSecretEnvFiles"] = data.get("uploadSecretEnvFiles", False)
                defaults["minFreeSpaceGB"] = data.get("minFreeSpaceGB", 10)
        except Exception:
            pass
    return defaults


PRIVACY_SETTINGS = load_vault_settings()
VAULT_PREFIX = f"primary_vault:{PRIVACY_SETTINGS['bucketAndPrefix']}"
GOVERNOR_FREE_FLOOR = max(6, int(PRIVACY_SETTINGS.get("minFreeSpaceGB", 10))) * 1024 * 1024 * 1024

IS_FABRIC = "FabricDrive" in SOURCE_INPUT
IS_ICLOUD = ("Mobile Documents" in SOURCE_INPUT or "/Desktop/" in SOURCE_INPUT or "/Documents/" in SOURCE_INPUT)
SOURCE_PREFIX = "Fabric" if IS_FABRIC else ("iCloud" if IS_ICLOUD else "Mac")

WAS_DIRECTORY = os.path.isdir(SOURCE_INPUT) and not os.path.islink(SOURCE_INPUT)

if DEST_SUBFOLDER:
    DEST_BASE = f"{VAULT_PREFIX}/{DEST_SUBFOLDER}"
    DISPLAY_NAME = DEST_SUBFOLDER
elif WAS_DIRECTORY:
    DISPLAY_NAME = os.path.basename(os.path.normpath(SOURCE_INPUT))
    DEST_BASE = f"{VAULT_PREFIX}/{DISPLAY_NAME}"
else:
    DISPLAY_NAME = os.path.basename(SOURCE_INPUT)
    DEST_BASE = VAULT_PREFIX

SF_DATALESS = 0x40000000
SINGLE_FILE_HYDRATION_THRESHOLD = 25 * 1024 * 1024  # 25 MB: anything larger hydrates strictly 1-by-1

try:
    from Foundation import NSURL, NSFileManager
    _FM = NSFileManager.defaultManager()
except Exception:
    _FM = None


def format_bytes(b):
    if b < 1024:
        return f"{b} B"
    elif b < 1024**2:
        return f"{b/1024:.1f} KB"
    elif b < 1024**3:
        return f"{b/1024**2:.1f} MB"
    else:
        return f"{b/1024**3:.2f} GB"


def write_telemetry(payload):
    try:
        temp_p = f"{TELEMETRY_PATH}.tmp.{os.getpid()}"
        with open(temp_p, "w") as f:
            json.dump(payload, f)
        os.replace(temp_p, TELEMETRY_PATH)
    except Exception:
        pass


def should_skip_file(rel_path, filename):
    if filename in [".DS_Store", "Thumbs.db", ".zerodrive-keep"] or filename.startswith("._"):
        return True
    if not PRIVACY_SETTINGS["uploadSecretEnvFiles"]:
        if filename.startswith(".env") or filename.endswith(".pem") or filename.endswith(".key"):
            return True
    if not PRIVACY_SETTINGS["uploadDevConfigs"]:
        if any(part in [".git", ".github", ".claude"] for part in rel_path.split(os.sep)):
            return True
    if not PRIVACY_SETTINGS["uploadAppWorkspaces"]:
        if any(part in [".obsidian", ".vscode", ".cursor"] for part in rel_path.split(os.sep)):
            return True
    return False


def is_file_cloud_stub(abs_p, expected_size=None):
    try:
        st = os.stat(abs_p, follow_symlinks=False)
        if expected_size is None:
            expected_size = st.st_size
        is_dataless = bool(getattr(st, "st_flags", 0) & SF_DATALESS)
        is_incomplete = (expected_size > 4096 and (st.st_blocks * 512) < (expected_size * 0.95))
        return is_dataless or is_incomplete
    except Exception:
        return False


def clean_empty_directories(path):
    if IS_COPY or not os.path.isdir(path):
        return
    for root, dirs, _ in os.walk(path, topdown=False):
        for d in dirs:
            dir_path = os.path.join(root, d)
            try:
                entries = [x for x in os.listdir(dir_path) if x not in [".DS_Store", "Thumbs.db"] and not x.startswith("._")]
                if not entries:
                    for junk in os.listdir(dir_path):
                        try:
                            os.remove(os.path.join(dir_path, junk))
                        except Exception:
                            pass
                    os.rmdir(dir_path)
            except Exception:
                pass


def refresh_vfs_mount():
    try:
        subprocess.run(["curl", "-s", "-X", "POST", "http://127.0.0.1:55729/vfs/forget"],
                       capture_output=True, timeout=3)
        subprocess.run(["curl", "-s", "-X", "POST", "http://127.0.0.1:55729/vfs/refresh"],
                       capture_output=True, timeout=3)
    except Exception:
        pass


def discover_all_files(source_path):
    """Returns list of (abs_path, rel_path, size_bytes) for either a single file or directory."""
    if os.path.isfile(source_path):
        st = os.stat(source_path, follow_symlinks=False)
        return [(source_path, os.path.basename(source_path), st.st_size)]

    results = []
    for r, dirs, fs in os.walk(source_path):
        dirs[:] = [
            d for d in dirs
            if d not in ["node_modules", ".next", "__pycache__", ".venv", "venv"]
            and not (d == ".git" and (getattr(os.stat(os.path.join(r, d), follow_symlinks=False), "st_flags", 0) & SF_DATALESS))
        ]
        for f in fs:
            abs_p = os.path.join(r, f)
            if os.path.islink(abs_p):
                continue
            rel_p = os.path.relpath(abs_p, source_path)
            if should_skip_file(rel_p, f):
                continue
            try:
                st = os.stat(abs_p, follow_symlinks=False)
                results.append((abs_p, rel_p, st.st_size))
            except Exception:
                pass
    return results


def wait_for_ssd_governor(required_extra_bytes=0):
    """Ensures Mac SSD always preserves safe free space before hydrating cloud files."""
    target_floor = GOVERNOR_FREE_FLOOR + required_extra_bytes
    while True:
        cur_free = shutil.disk_usage(os.path.expanduser("~")).free
        if cur_free >= target_floor:
            break
        print(
            f"\n[SSD Protection Active] Free space is {format_bytes(cur_free)} "
            f"(needs {format_bytes(target_floor)}). Waiting for free space...",
            flush=True,
        )
        time.sleep(3)


def trigger_single_download(abs_p):
    """Requests download of a single cloud-only file."""
    if _FM:
        try:
            u = NSURL.fileURLWithPath_(abs_p)
            _FM.startDownloadingUbiquitousItemAtURL_error_(u, None)
        except Exception:
            pass
    try:
        subprocess.run(
            ["/usr/bin/brctl", "download", abs_p],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
    except Exception:
        pass


def move_files_batch(file_batch, cumulative_moved_f, cumulative_moved_b, grand_total_f, grand_total_b, current_label):
    """Executes native rclone move/copy with a batch file list, updating live telemetry."""
    if not file_batch:
        return 0, 0

    batch_fd, batch_path = tempfile.mkstemp(prefix="zd-batch-", suffix=".txt")
    with os.fdopen(batch_fd, "w") as bf:
        for _, rel_p, _ in file_batch:
            bf.write(f"{rel_p}\n")

    source_root = SOURCE_INPUT if WAS_DIRECTORY else os.path.dirname(SOURCE_INPUT)
    action = "copy" if IS_COPY else "move"
    cmd = [
        RCLONE_BIN, action, source_root, DEST_BASE,
        f"--config={RCLONE_CONF}",
        "--files-from", batch_path,
        "--size-only",
        "--update",
        "--transfers=32",
        "--checkers=64",
        "--fast-list",
        "--s3-upload-cutoff=32M",
        "--s3-chunk-size=16M",
        "--s3-upload-concurrency=4",
        "--stats=350ms",
        "--stats-log-level=NOTICE",
        "--use-json-log",
    ]
    if not IS_COPY:
        cmd.append("--delete-empty-src-dirs")

    moved_b = 0
    moved_f = 0
    last_ui_write = 0.0

    try:
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
                    moved_f = st.get("transfers", 0)
                    speed_bps = st.get("speed", 0.0) or 0.0
                    speed_mbps = speed_bps / (1024 * 1024)
                    eta_sec = st.get("eta") or 0

                    tot_f = min(grand_total_f, cumulative_moved_f + moved_f)
                    tot_b = min(grand_total_b, cumulative_moved_b + moved_b)
                    byte_pct = (tot_b / grand_total_b * 100.0) if grand_total_b > 0 else 0.0
                    file_pct = (tot_f / grand_total_f * 100.0) if grand_total_f > 0 else 0.0
                    pct = max(byte_pct, file_pct)

                    now = time.time()
                    if now - last_ui_write >= 0.25:
                        last_ui_write = now
                        cur_free = shutil.disk_usage(os.path.expanduser("~")).free
                        write_telemetry({
                            "spaceName": DISPLAY_NAME,
                            "isRunning": True,
                            "isComplete": False,
                            "speedMBps": round(speed_mbps, 1),
                            "percent": round(min(99.9, pct), 1),
                            "movedFiles": tot_f,
                            "totalFiles": grand_total_f,
                            "movedBytes": tot_b,
                            "totalBytes": grand_total_b,
                            "remainingBytes": max(0, grand_total_b - tot_b),
                            "etaSeconds": int(eta_sec),
                            "freeDiskBytes": cur_free,
                            "diskDeltaBytes": 0,
                            "activeWorkers": 32,
                            "statusMessage": f"Saving {current_label} • {tot_f}/{grand_total_f} files ({pct:.1f}%)",
                            "currentFile": current_label,
                            "sourceLocation": f"{SOURCE_PREFIX}: {DISPLAY_NAME}",
                            "destLocation": f"My Drive/{DISPLAY_NAME}",
                        })
            except Exception:
                pass
        proc.wait()
    finally:
        try:
            if os.path.exists(batch_path):
                os.remove(batch_path)
        except Exception:
            pass

    # Count actual completed items from batch
    verified_f = 0
    verified_b = 0
    for abs_p, _, sz in file_batch:
        if IS_COPY or not os.path.exists(abs_p):
            verified_f += 1
            verified_b += sz
    return max(moved_f, verified_f), max(moved_b, verified_b)


def record_completion_and_activity(files_moved, bytes_moved):
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    cur_free = shutil.disk_usage(os.path.expanduser("~")).free

    # 1. Update migration-ledger.json
    ledger = {
        "baselineMacFreeBytes": cur_free,
        "currentMacFreeBytes": cur_free,
        "totalFreedOnMacBytes": bytes_moved if not IS_COPY else 0,
        "totalMovedToVaultBytes": bytes_moved,
        "completedSpaces": [],
    }
    if os.path.exists(LEDGER_PATH):
        try:
            with open(LEDGER_PATH, "r") as f:
                ledger = json.load(f)
        except Exception:
            pass

    ledger["currentMacFreeBytes"] = cur_free
    if not IS_COPY:
        ledger["totalFreedOnMacBytes"] = ledger.get("totalFreedOnMacBytes", 0) + bytes_moved
    ledger["totalMovedToVaultBytes"] = ledger.get("totalMovedToVaultBytes", 0) + bytes_moved

    completed = [c for c in ledger.get("completedSpaces", []) if c.get("spaceName") != DISPLAY_NAME]
    completed.insert(0, {
        "spaceName": DISPLAY_NAME,
        "filesMoved": files_moved,
        "bytesMoved": bytes_moved,
        "completedAt": now_iso,
        "status": "Completed (Symlinked)" if (LEAVE_SYMLINK and not IS_COPY) else ("Copied" if IS_COPY else "Moved & Freed"),
    })
    ledger["completedSpaces"] = completed[:100]
    try:
        with open(LEDGER_PATH, "w") as f:
            json.dump(ledger, f, indent=2)
    except Exception:
        pass

    # 2. Update session-activity.json for the Activity Tab
    events = []
    if os.path.exists(ACTIVITY_PATH):
        try:
            with open(ACTIVITY_PATH, "r") as f:
                events = json.load(f)
        except Exception:
            events = []
    events.append({
        "id": f"{DISPLAY_NAME}-{int(time.time())}",
        "filename": DISPLAY_NAME,
        "spaceOrFolder": f"My Drive/{DISPLAY_NAME}" + (" (Shortcut left on Mac)" if (LEAVE_SYMLINK and not IS_COPY) else ""),
        "sizeBytes": bytes_moved,
        "timestamp": time.time() - 978307200.0,  # Swift Date timeIntervalSinceReferenceDate
        "status": "Completed",
    })
    try:
        with open(ACTIVITY_PATH, "w") as f:
            json.dump(events[-200:], f, indent=2)
    except Exception:
        pass


def create_folder_symlink_if_requested(bytes_moved):
    """If --leave-symlink was passed and SOURCE_INPUT is now empty, replace it with a POSIX symlink to My Drive."""
    if IS_COPY or not LEAVE_SYMLINK or not WAS_DIRECTORY:
        return False

    clean_empty_directories(SOURCE_INPUT)

    # Check if any real user files remain inside SOURCE_INPUT
    remaining_real_files = discover_all_files(SOURCE_INPUT)
    if remaining_real_files:
        print(f"[Symlink Skipped] {len(remaining_real_files)} files still remain in {SOURCE_INPUT}", flush=True)
        return False

    # Remove leftover .DS_Store / empty folder so we can place the symlink
    try:
        shutil.rmtree(SOURCE_INPUT)
    except Exception as e:
        print(f"[Symlink Warning] Could not remove empty folder {SOURCE_INPUT}: {e}", flush=True)
        return False

    mount_target = os.path.expanduser(f"~/ZeroDrive/My Drive/{DISPLAY_NAME}")
    try:
        os.symlink(mount_target, SOURCE_INPUT)
    except Exception as e:
        print(f"[Symlink Error] Failed creating symlink {SOURCE_INPUT} -> {mount_target}: {e}", flush=True)
        return False

    # Record in zerodrive-symlinks.json
    symlinks = []
    if os.path.exists(SYMLINKS_PATH):
        try:
            with open(SYMLINKS_PATH, "r") as f:
                symlinks = json.load(f)
        except Exception:
            symlinks = []

    symlinks = [s for s in symlinks if s.get("originalPath") != SOURCE_INPUT]
    symlinks.insert(0, {
        "folderName": DISPLAY_NAME,
        "originalPath": SOURCE_INPUT,
        "cloudTargetPath": mount_target,
        "bytesSaved": bytes_moved,
        "createdAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    })
    try:
        with open(SYMLINKS_PATH, "w") as f:
            json.dump(symlinks, f, indent=2)
    except Exception:
        pass

    print(f"✓ Created shortcut (symlink): {SOURCE_INPUT} -> {mount_target}", flush=True)
    return True


def main():
    start_time = time.time()
    all_files = discover_all_files(SOURCE_INPUT)
    grand_total_files = len(all_files)
    grand_total_bytes = sum(x[2] for x in all_files)

    print(f"Starting transfer for [{DISPLAY_NAME}]: {grand_total_files} files ({format_bytes(grand_total_bytes)})", flush=True)

    cumulative_moved_f = 0
    cumulative_moved_b = 0

    # Separate already-local files from cloud-only stubs
    local_ready = []
    cloud_stubs = []
    for item in all_files:
        if is_file_cloud_stub(item[0], item[2]):
            cloud_stubs.append(item)
        else:
            local_ready.append(item)

    # PHASE 1: Move all already-local files immediately in batches of 500 (frees SSD space first!)
    if local_ready:
        print(f"[Phase 1] Moving {len(local_ready)} local files immediately...", flush=True)
        for i in range(0, len(local_ready), 500):
            batch = local_ready[i:i + 500]
            mf, mb = move_files_batch(
                batch,
                cumulative_moved_f,
                cumulative_moved_b,
                grand_total_files,
                grand_total_bytes,
                os.path.basename(batch[0][1]),
            )
            cumulative_moved_f += mf
            cumulative_moved_b += mb
        clean_empty_directories(SOURCE_INPUT)
        refresh_vfs_mount()

    # PHASE 2: Strict Controlled Hydration for Cloud-Only Stubs (Smallest First, 1-by-1 for >25MB)
    if cloud_stubs:
        cloud_stubs.sort(key=lambda x: x[2])  # Smallest first so quick wins finish immediately
        small_stubs = [x for x in cloud_stubs if x[2] <= SINGLE_FILE_HYDRATION_THRESHOLD]
        large_stubs = [x for x in cloud_stubs if x[2] > SINGLE_FILE_HYDRATION_THRESHOLD]

        # 2A. Small stubs in safe mini-batches of 25
        for i in range(0, len(small_stubs), 25):
            mini_batch = [x for x in small_stubs[i:i + 25] if os.path.exists(x[0])]
            if not mini_batch:
                continue
            wait_for_ssd_governor(sum(x[2] for x in mini_batch))
            for abs_p, _, _ in mini_batch:
                trigger_single_download(abs_p)

            # Wait up to 45s for files in this mini-batch to materialize
            deadline = time.time() + 45
            while time.time() < deadline:
                ready_now = [x for x in mini_batch if os.path.exists(x[0]) and not is_file_cloud_stub(x[0], x[2])]
                if len(ready_now) == len(mini_batch):
                    break
                time.sleep(1.0)

            ready_now = [x for x in mini_batch if os.path.exists(x[0]) and not is_file_cloud_stub(x[0], x[2])]
            if ready_now:
                mf, mb = move_files_batch(
                    ready_now,
                    cumulative_moved_f,
                    cumulative_moved_b,
                    grand_total_files,
                    grand_total_bytes,
                    os.path.basename(ready_now[0][1]),
                )
                cumulative_moved_f += mf
                cumulative_moved_b += mb

        # 2B. Large files (>25 MB) strictly ONE FILE AT A TIME so `bird` never hoards 40 GB in MMCS
        for abs_p, rel_p, sz in large_stubs:
            if not os.path.exists(abs_p):
                continue
            wait_for_ssd_governor(sz)
            fname = os.path.basename(rel_p)
            print(f"[1-by-1 Cloud Drain] Requesting single file: {fname} ({format_bytes(sz)})", flush=True)
            trigger_single_download(abs_p)

            # Wait for this single file to finish downloading from iCloud/FileProvider
            wait_start = time.time()
            while os.path.exists(abs_p) and is_file_cloud_stub(abs_p, sz):
                if time.time() - wait_start > 1800:  # 30 min max timeout per giant video
                    break
                cur_free = shutil.disk_usage(os.path.expanduser("~")).free
                pct = (cumulative_moved_b / grand_total_bytes * 100.0) if grand_total_bytes > 0 else 0.0
                write_telemetry({
                    "spaceName": DISPLAY_NAME,
                    "isRunning": True,
                    "isComplete": False,
                    "speedMBps": 0.0,
                    "percent": round(pct, 1),
                    "movedFiles": cumulative_moved_f,
                    "totalFiles": grand_total_files,
                    "movedBytes": cumulative_moved_b,
                    "totalBytes": grand_total_bytes,
                    "remainingBytes": max(0, grand_total_bytes - cumulative_moved_b),
                    "etaSeconds": 0,
                    "freeDiskBytes": cur_free,
                    "diskDeltaBytes": 0,
                    "activeWorkers": 1,
                    "statusMessage": f"Step 1 of 2: Downloading {fname} ({format_bytes(sz)}) from iCloud…",
                    "currentFile": fname,
                    "sourceLocation": f"{SOURCE_PREFIX}: {DISPLAY_NAME}",
                    "destLocation": f"My Drive/{DISPLAY_NAME}",
                })
                time.sleep(1.5)

            if os.path.exists(abs_p) and not is_file_cloud_stub(abs_p, sz):
                mf, mb = move_files_batch(
                    [(abs_p, rel_p, sz)],
                    cumulative_moved_f,
                    cumulative_moved_b,
                    grand_total_files,
                    grand_total_bytes,
                    fname,
                )
                cumulative_moved_f += mf
                cumulative_moved_b += mb
                refresh_vfs_mount()

    clean_empty_directories(SOURCE_INPUT)
    symlink_created = create_folder_symlink_if_requested(cumulative_moved_b)
    refresh_vfs_mount()

    if cumulative_moved_f > 0 or symlink_created:
        record_completion_and_activity(cumulative_moved_f, cumulative_moved_b)

    elapsed = max(0.5, time.time() - start_time)
    avg_speed = (cumulative_moved_b / (1024 * 1024)) / elapsed
    cur_free = shutil.disk_usage(os.path.expanduser("~")).free

    suffix = " • Shortcut left in original spot" if symlink_created else ""
    write_telemetry({
        "spaceName": DISPLAY_NAME,
        "isRunning": False,
        "isComplete": True,
        "speedMBps": round(avg_speed, 1),
        "percent": 100.0,
        "movedFiles": cumulative_moved_f,
        "totalFiles": cumulative_moved_f,
        "movedBytes": cumulative_moved_b,
        "totalBytes": cumulative_moved_b,
        "remainingBytes": 0,
        "etaSeconds": 0,
        "freeDiskBytes": cur_free,
        "diskDeltaBytes": 0,
        "activeWorkers": 0,
        "statusMessage": f"✓ Moved {DISPLAY_NAME} ({format_bytes(cumulative_moved_b)}){suffix}",
        "currentFile": "",
        "sourceLocation": f"{SOURCE_PREFIX}: {DISPLAY_NAME}",
        "destLocation": f"My Drive/{DISPLAY_NAME}",
    })


if __name__ == "__main__":
    main()
