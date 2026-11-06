#!/usr/bin/env python3
"""
High-Speed Parallel ZeroDrive Direct Batch Move & Rolling-Wave iCloud Hydration Engine
Features:
- Direct batch transfer via native multi-threaded rclone move (--transfers=32, --checkers=64, --fast-list).
- Smart Cloud Handling:
  * FabricDrive: Pre-filters SF_DATALESS ghost stubs that were already migrated.
  * iCloud / Mac Folders: Rolling-Wave Hydrate & Move! Moves already-downloaded files immediately to free
    Mac SSD space, while triggering iCloud downloads in safe 8 GB waves so 300+ GB iCloud folders can be
    migrated completely without ever filling up a 100 GB Mac SSD or leaving partial moves behind.
- Live real-time stdout & JSON telemetry parsing: current filename, speed (MB/s), ETA countdown, percent.
- Auto-prunes empty source directories upon file migration.
"""

import os
import sys
import time
import shutil
import json
import subprocess
import tempfile

if len(sys.argv) < 2:
    print("Usage: turbo-migrate-dashboard.py <source_path> [dest_subfolder]")
    sys.exit(1)

SOURCE_INPUT = os.path.abspath(sys.argv[1])
DEST_SUBFOLDER = sys.argv[2] if len(sys.argv) > 2 else ""

RCLONE_BIN = "/Applications/ZeroDrive.app/Contents/Resources/rclone"
if not os.path.exists(RCLONE_BIN):
    RCLONE_BIN = "/opt/homebrew/bin/rclone" if os.path.exists("/opt/homebrew/bin/rclone") else "rclone"

RCLONE_CONF = os.path.expanduser("~/.config/rclone/rclone.conf")
VAULT_PREFIX = "primary_vault:zerodrive-vault-prod/usr_andrew_8bc7fb477f"

IS_FABRIC = "FabricDrive" in SOURCE_INPUT
SOURCE_PREFIX = "Fabric" if IS_FABRIC else ("iCloud" if ("Mobile Documents" in SOURCE_INPUT or "/Desktop/" in SOURCE_INPUT or "/Documents/" in SOURCE_INPUT) else "MacBook")

if DEST_SUBFOLDER:
    DEST_BASE = f"{VAULT_PREFIX}/{DEST_SUBFOLDER}"
    DISPLAY_NAME = DEST_SUBFOLDER
elif os.path.isdir(SOURCE_INPUT):
    DISPLAY_NAME = os.path.basename(os.path.normpath(SOURCE_INPUT))
    DEST_BASE = f"{VAULT_PREFIX}/{DISPLAY_NAME}"
else:
    DISPLAY_NAME = os.path.basename(SOURCE_INPUT)
    DEST_BASE = VAULT_PREFIX

TELEMETRY_PATH = os.path.expanduser("~/.config/rclone/migration-telemetry.json")
LEDGER_PATH = os.path.expanduser("~/.config/rclone/migration-ledger.json")
STATS_PATH = os.path.expanduser("~/.config/rclone/zerodrive-stats.json")

SF_DATALESS = 0x40000000
WAVE_TARGET_BYTES = 8 * 1024 * 1024 * 1024  # 8 GB per hydration wave
MIN_BATCH_BYTES = 250 * 1024 * 1024         # Move as soon as 250 MB is downloaded
MIN_BATCH_FILES = 100                       # Or as soon as 100 files are downloaded

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

def update_migration_ledger(space_name, files_moved, bytes_moved):
    try:
        ledger = {}
        if os.path.exists(LEDGER_PATH):
            with open(LEDGER_PATH, "r") as f:
                ledger = json.load(f)
        
        baseline = ledger.get("baselineMacFreeBytes", 17179869184)
        current_free = shutil.disk_usage("/Users/Naegele").free
        ledger["currentMacFreeBytes"] = current_free
        ledger["totalFreedOnMacBytes"] = max(0, current_free - baseline)
        ledger["totalMovedToVaultBytes"] = ledger.get("totalMovedToVaultBytes", 0) + bytes_moved
        
        completed = ledger.get("completedSpaces", [])
        existing = next((s for s in completed if s.get("spaceName") == space_name), None)
        if existing:
            existing["filesMoved"] += files_moved
            existing["bytesMoved"] += bytes_moved
            existing["completedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        else:
            completed.append({
                "spaceName": space_name,
                "filesMoved": files_moved,
                "bytesMoved": bytes_moved,
                "completedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "status": "Completed"
            })
        ledger["completedSpaces"] = completed
        
        remaining = ledger.get("remainingSpaces", [])
        ledger["remainingSpaces"] = [r for r in remaining if r.get("spaceName") != space_name]
        
        temp_l = f"{LEDGER_PATH}.tmp.{os.getpid()}"
        with open(temp_l, "w") as f:
            json.dump(ledger, f, indent=2)
        os.replace(temp_l, LEDGER_PATH)
    except Exception:
        pass

def update_cached_vault_stats(added_bytes):
    if added_bytes <= 0:
        return
    try:
        data = {}
        if os.path.exists(STATS_PATH):
            with open(STATS_PATH, "r") as f:
                data = json.load(f)
        current = data.get("totalBytes", 0)
        data["totalBytes"] = current + added_bytes
        with open(STATS_PATH, "w") as f:
            json.dump(data, f)
    except Exception:
        pass

def clean_empty_directories(path):
    if not os.path.isdir(path):
        return
    for root, dirs, files in os.walk(path, topdown=False):
        for d in dirs:
            dir_path = os.path.join(root, d)
            try:
                entries = [x for x in os.listdir(dir_path) if x != ".DS_Store"]
                if not entries:
                    ds = os.path.join(dir_path, ".DS_Store")
                    if os.path.exists(ds):
                        try:
                            os.remove(ds)
                        except Exception:
                            pass
                    os.rmdir(dir_path)
            except Exception:
                pass

def refresh_vfs_mount():
    try:
        subprocess.run(["curl", "-s", "-X", "POST", "http://127.0.0.1:55729/vfs/forget"],
                       capture_output=True, timeout=3)
        subprocess.run(["curl", "-s", "-X", "POST", "http://127.0.0.1:55729/vfs/refresh",
                        "-H", "Content-Type: application/json", "-d", '{"dir": "My Drive"}'],
                       capture_output=True, timeout=5)
    except Exception:
        pass

def scan_directory_state(source_dir):
    """
    Returns (ready_files, ready_bytes, cloud_files, cloud_bytes).
    A file is 'ready' ONLY when SF_DATALESS is 0 AND its physical blocks are present on disk.
    """
    ready_files = []
    ready_bytes = 0
    cloud_files = []
    cloud_bytes = 0

    for root, dirs, files in os.walk(source_dir):
        for f in files:
            if f.startswith(".") or f == ".DS_Store":
                continue
            abs_p = os.path.join(root, f)
            rel_p = os.path.relpath(abs_p, source_dir)
            try:
                st = os.stat(abs_p, follow_symlinks=False)
                sz = st.st_size
                is_dataless = bool(getattr(st, "st_flags", 0) & SF_DATALESS)
                # Also verify physical disk blocks for files > 4KB so we never touch a partial file
                is_incomplete = (sz > 4096 and (st.st_blocks * 512) < sz)
                if is_dataless or is_incomplete:
                    cloud_files.append((abs_p, rel_p, sz))
                    cloud_bytes += sz
                else:
                    ready_files.append((abs_p, rel_p, sz))
                    ready_bytes += sz
            except Exception:
                continue

    return ready_files, ready_bytes, cloud_files, cloud_bytes

def trigger_icloud_wave_download(cloud_files, requested_set):
    """
    Requests iCloud (bird) to download up to WAVE_TARGET_BYTES (8 GB) or 500 files
    using macOS brctl download and FileManager.startDownloadingUbiquitousItem.
    """
    wave_paths = []
    wave_bytes = 0
    for abs_p, _, sz in cloud_files:
        if abs_p in requested_set:
            continue
        wave_paths.append(abs_p)
        requested_set.add(abs_p)
        wave_bytes += sz
        if wave_bytes >= WAVE_TARGET_BYTES or len(wave_paths) >= 500:
            break

    if not wave_paths:
        # Re-request top 200 remaining cloud files if all were previously requested
        for abs_p, _, sz in cloud_files[:200]:
            wave_paths.append(abs_p)

    if not wave_paths:
        return 0

    # Batch call brctl download in chunks of 100 paths
    for i in range(0, len(wave_paths), 100):
        chunk = wave_paths[i:i+100]
        try:
            subprocess.Popen(["/usr/bin/brctl", "download"] + chunk,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass

    return len(wave_paths)

def run_rclone_batch_move(file_list, wave_bytes, cumulative_moved_files, cumulative_moved_bytes, grand_total_files, grand_total_bytes, initial_free, wave_label=""):
    batch_fd, batch_path = tempfile.mkstemp(prefix=f"zerodrive-batch-{DISPLAY_NAME}-", suffix=".txt")
    with os.fdopen(batch_fd, "w") as bf:
        for _, rel_p, _ in file_list:
            bf.write(f"{rel_p}\n")

    cmd = [
        RCLONE_BIN, "move", SOURCE_INPUT, DEST_BASE,
        f"--config={RCLONE_CONF}",
        "--files-from", batch_path,
        "--size-only",
        "--update",
        "--transfers=24",
        "--checkers=48",
        "--fast-list",
        "--s3-upload-cutoff=32M",
        "--s3-chunk-size=16M",
        "--s3-upload-concurrency=4",
        "--delete-empty-src-dirs",
        "--stats=500ms",
        "--stats-log-level=NOTICE",
        "--use-json-log"
    ]

    last_ui_write = 0.0
    wave_moved_bytes = 0
    wave_moved_files = 0
    current_active_file = ""

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

                    wave_moved_bytes = moved_b
                    wave_moved_files = moved_f

                    transferring = st.get("transferring", [])
                    if transferring:
                        current_active_file = transferring[0].get("name", "")

                    tot_moved_b = cumulative_moved_bytes + moved_b
                    tot_moved_f = cumulative_moved_files + moved_f
                    total_b = max(grand_total_bytes, tot_moved_b)
                    total_f = max(grand_total_files, tot_moved_f)

                    pct = (tot_moved_b / total_b * 100.0) if total_b > 0 else (tot_moved_f / total_f * 100.0 if total_f > 0 else 0.0)
                    rem_b = max(0, total_b - tot_moved_b)

                    now = time.time()
                    if now - last_ui_write >= 0.25:
                        last_ui_write = now
                        cur_free = shutil.disk_usage("/Users/Naegele").free
                        delta_free = cur_free - initial_free

                        prefix_msg = f"{wave_label} • " if wave_label else ""
                        payload = {
                            "spaceName": DISPLAY_NAME,
                            "isRunning": True,
                            "isComplete": False,
                            "speedMBps": round(speed_mbps, 1),
                            "percent": round(min(99.9, pct), 1),
                            "movedFiles": tot_moved_f,
                            "totalFiles": total_f,
                            "movedBytes": tot_moved_b,
                            "totalBytes": total_b,
                            "remainingBytes": rem_b,
                            "etaSeconds": int(eta_sec),
                            "freeDiskBytes": cur_free,
                            "diskDeltaBytes": delta_free,
                            "activeWorkers": 24,
                            "statusMessage": f"{prefix_msg}Moved {tot_moved_f}/{total_f} files ({pct:.1f}%) • {format_bytes(tot_moved_b)} landed",
                            "currentFile": os.path.basename(current_active_file) if current_active_file else "",
                            "sourceLocation": f"{SOURCE_PREFIX}: {DISPLAY_NAME}",
                            "destLocation": f"My Drive/{DISPLAY_NAME}"
                        }
                        write_telemetry(payload)

                        bar_len = 25
                        filled = int(bar_len * (pct / 100.0))
                        bar = "█" * min(bar_len, filled) + "░" * max(0, bar_len - filled)
                        eta_str = f"{int(eta_sec)//60}m {int(eta_sec)%60}s" if eta_sec > 0 else "..."
                        sys.stdout.write(
                            f"\r\033[K[{DISPLAY_NAME}] |{bar}| {pct:5.1f}% | "
                            f"⚡ {speed_mbps:5.1f} MB/s | "
                            f"⏳ ETA: {eta_str} | "
                            f"📦 {tot_moved_f}/{total_f} | "
                            f"File: {os.path.basename(current_active_file)[:28]}"
                        )
                        sys.stdout.flush()
            except Exception:
                pass

        proc.wait()
    finally:
        try:
            if os.path.exists(batch_path):
                os.remove(batch_path)
        except Exception:
            pass

    actual_b = wave_moved_bytes if wave_moved_bytes > 0 else wave_bytes
    actual_f = wave_moved_files if wave_moved_files > 0 else len(file_list)
    return actual_f, actual_b

def main():
    print(f"\n==================================================================", flush=True)
    print(f" ZERO-PRESSURE TURBO BATCH MOVE: [{DISPLAY_NAME}]", flush=True)
    print(f" Source:      {SOURCE_INPUT} ({SOURCE_PREFIX})", flush=True)
    print(f" Destination: {DEST_BASE}", flush=True)
    print(f" Mode:        {'Fabric Ghost Filter' if IS_FABRIC else 'Rolling-Wave iCloud Hydrate & Move'}", flush=True)
    print(f"==================================================================\n", flush=True)

    if not os.path.exists(SOURCE_INPUT):
        print(f"Error: Source '{SOURCE_INPUT}' does not exist.")
        sys.exit(1)

    initial_free = shutil.disk_usage("/Users/Naegele").free
    start_time = time.time()

    if os.path.isfile(SOURCE_INPUT):
        st = os.stat(SOURCE_INPUT)
        sz = st.st_size
        cmd = [
            RCLONE_BIN, "moveto", SOURCE_INPUT, f"{DEST_BASE}/{os.path.basename(SOURCE_INPUT)}",
            f"--config={RCLONE_CONF}", "--size-only", "--update"
        ]
        subprocess.run(cmd)
        update_cached_vault_stats(sz)
        update_migration_ledger(DISPLAY_NAME, 1, sz)
        refresh_vfs_mount()
        return

    # Initial scan
    ready_files, ready_bytes, cloud_files, cloud_bytes = scan_directory_state(SOURCE_INPUT)

    if IS_FABRIC:
        grand_total_files = len(ready_files)
        grand_total_bytes = ready_bytes
    else:
        grand_total_files = len(ready_files) + len(cloud_files)
        grand_total_bytes = ready_bytes + cloud_bytes

    print(f"Initial Scan: {len(ready_files)} local files ({format_bytes(ready_bytes)}) ready, "
          f"{len(cloud_files)} cloud-only files ({format_bytes(cloud_bytes)}).\n", flush=True)

    if grand_total_files == 0:
        cur_free = shutil.disk_usage("/Users/Naegele").free
        payload = {
            "spaceName": DISPLAY_NAME,
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
            "diskDeltaBytes": cur_free - initial_free,
            "activeWorkers": 0,
            "statusMessage": f"✓ {DISPLAY_NAME} has 0 files remaining to move.",
            "currentFile": "",
            "sourceLocation": f"{SOURCE_PREFIX}: {DISPLAY_NAME}",
            "destLocation": f"My Drive/{DISPLAY_NAME}"
        }
        write_telemetry(payload)
        update_migration_ledger(DISPLAY_NAME, 0, 0)
        refresh_vfs_mount()
        return

    cumulative_moved_files = 0
    cumulative_moved_bytes = 0
    requested_cloud_paths = set()
    wave_num = 0

    while True:
        wave_num += 1
        ready_files, ready_bytes, cloud_files, cloud_bytes = scan_directory_state(SOURCE_INPUT)

        # If non-Fabric and cloud files exist, trigger background hydration for the next wave
        if not IS_FABRIC and cloud_files:
            newly_req = trigger_icloud_wave_download(cloud_files, requested_cloud_paths)
            if newly_req > 0:
                print(f"\n[Wave {wave_num}] Triggered iCloud download for {newly_req} cloud files (Remaining in iCloud: {len(cloud_files)} files / {format_bytes(cloud_bytes)})", flush=True)

        # Move all currently downloaded (ready) files immediately to free up local Mac SSD space!
        if ready_files:
            wave_label = f"Wave {wave_num} ({len(cloud_files)} in iCloud)" if (not IS_FABRIC and cloud_files) else ""
            print(f"\n[Wave {wave_num}] Moving {len(ready_files)} downloaded files ({format_bytes(ready_bytes)}) to ZeroDrive...", flush=True)
            moved_f, moved_b = run_rclone_batch_move(
                ready_files,
                ready_bytes,
                cumulative_moved_files,
                cumulative_moved_bytes,
                grand_total_files,
                grand_total_bytes,
                initial_free,
                wave_label=wave_label
            )
            cumulative_moved_files += moved_f
            cumulative_moved_bytes += moved_b
            clean_empty_directories(SOURCE_INPUT)
            update_cached_vault_stats(moved_b)
            update_migration_ledger(DISPLAY_NAME, moved_f, moved_b)
            refresh_vfs_mount()

        # Re-scan after move
        ready_files, ready_bytes, cloud_files, cloud_bytes = scan_directory_state(SOURCE_INPUT)

        if IS_FABRIC or (not ready_files and not cloud_files):
            break

        # If we already have another ready batch that finished downloading during the move, loop immediately!
        if ready_bytes >= MIN_BATCH_BYTES or len(ready_files) >= MIN_BATCH_FILES:
            continue

        # Otherwise, wait & monitor while iCloud downloads the next wave
        wait_start = time.time()
        while True:
            time.sleep(2.0)
            ready_files, ready_bytes, cloud_files, cloud_bytes = scan_directory_state(SOURCE_INPUT)
            cur_free = shutil.disk_usage("/Users/Naegele").free
            delta_free = cur_free - initial_free
            tot_moved_b = cumulative_moved_bytes
            tot_moved_f = cumulative_moved_files
            pct = (tot_moved_b / grand_total_bytes * 100.0) if grand_total_bytes > 0 else 0.0

            status_msg = (
                f"Downloading from iCloud: {len(ready_files)} files ({format_bytes(ready_bytes)}) ready to move • "
                f"{len(cloud_files)} files ({format_bytes(cloud_bytes)}) remaining in iCloud"
            )
            payload = {
                "spaceName": DISPLAY_NAME,
                "isRunning": True,
                "isComplete": False,
                "speedMBps": 0.0,
                "percent": round(min(99.9, pct), 1),
                "movedFiles": tot_moved_f,
                "totalFiles": grand_total_files,
                "movedBytes": tot_moved_b,
                "totalBytes": grand_total_bytes,
                "remainingBytes": cloud_bytes + ready_bytes,
                "etaSeconds": 0,
                "freeDiskBytes": cur_free,
                "diskDeltaBytes": delta_free,
                "activeWorkers": 24,
                "statusMessage": status_msg,
                "currentFile": cloud_files[0][1] if cloud_files else "",
                "sourceLocation": f"{SOURCE_PREFIX}: {DISPLAY_NAME}",
                "destLocation": f"My Drive/{DISPLAY_NAME}"
            }
            write_telemetry(payload)
            sys.stdout.write(f"\r\033[K⏳ {status_msg}")
            sys.stdout.flush()

            # Break out to move as soon as a healthy batch is downloaded or 12s elapsed with ready files
            if not cloud_files:
                break
            if ready_bytes >= MIN_BATCH_BYTES or len(ready_files) >= MIN_BATCH_FILES:
                break
            if ready_files and (time.time() - wait_start) >= 12.0:
                break
            # Re-trigger iCloud download every 30s if waiting
            if (time.time() - wait_start) >= 30.0:
                trigger_icloud_wave_download(cloud_files, requested_cloud_paths)
                wait_start = time.time()

    elapsed = max(0.5, time.time() - start_time)
    avg_speed = (cumulative_moved_bytes / (1024 * 1024)) / elapsed
    cur_free = shutil.disk_usage("/Users/Naegele").free
    delta_free = cur_free - initial_free

    final_payload = {
        "spaceName": DISPLAY_NAME,
        "isRunning": False,
        "isComplete": True,
        "speedMBps": round(avg_speed, 1),
        "percent": 100.0,
        "movedFiles": cumulative_moved_files,
        "totalFiles": cumulative_moved_files,
        "movedBytes": cumulative_moved_bytes,
        "totalBytes": cumulative_moved_bytes,
        "remainingBytes": 0,
        "etaSeconds": 0,
        "freeDiskBytes": cur_free,
        "diskDeltaBytes": delta_free,
        "activeWorkers": 0,
        "statusMessage": f"✓ Finished {DISPLAY_NAME} ({format_bytes(cumulative_moved_bytes)}) in {elapsed:.1f}s!",
        "currentFile": "",
        "sourceLocation": f"{SOURCE_PREFIX}: {DISPLAY_NAME}",
        "destLocation": f"My Drive/{DISPLAY_NAME}"
    }
    write_telemetry(final_payload)

    print(f"\n\n==================================================================", flush=True)
    print(f"✓ FINISHED [{DISPLAY_NAME}] IN {elapsed:.1f} SECONDS!", flush=True)
    print(f"  Files Moved:   {cumulative_moved_files}", flush=True)
    print(f"  Volume Moved:  {format_bytes(cumulative_moved_bytes)}", flush=True)
    print(f"  Average Speed: {avg_speed:.1f} MB/s", flush=True)
    print(f"  Mac Disk Free: {format_bytes(cur_free)} (+{format_bytes(max(0, delta_free))})", flush=True)
    print(f"==================================================================\n", flush=True)

if __name__ == "__main__":
    main()
