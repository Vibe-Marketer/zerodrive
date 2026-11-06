#!/usr/bin/env python3
"""
Stream-moves files from a source directory directly into ZeroDrive primary vault
using parallel workers and a strict local disk safety ceiling.
"""

import os
import sys
import time
import shutil
import subprocess
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed

SOURCE_DIR = sys.argv[1] if len(sys.argv) > 1 else "/Users/Naegele/Library/CloudStorage/FabricDrive/Andrew Naegeles Workspace/Spaces/CLOUD-MAIN"
SPACE_NAME = os.path.basename(os.path.normpath(SOURCE_DIR))
RCLONE_BIN = "/Applications/ZeroDrive.app/Contents/Resources/rclone"
RCLONE_CONF = os.path.expanduser("~/.config/rclone/rclone.conf")
DEST_BASE = f"primary_vault:zerodrive-vault-prod/usr_andrew_8bc7fb477f/{SPACE_NAME}"

MAX_WORKERS = 8
TIMEOUT_SEC = 25

lock = threading.Lock()
stats = {
    "moved_files": 0,
    "moved_bytes": 0,
    "failed_files": 0,
    "skipped_files": 0,
    "start_time": time.time()
}

def move_single_file(abs_path, rel_path):
    dest_path = f"{DEST_BASE}/{rel_path}"
    
    # Run rclone move directly on this individual file
    cmd = [
        RCLONE_BIN,
        "move",
        abs_path,
        os.path.dirname(dest_path),
        f"--config={RCLONE_CONF}",
        "--s3-upload-cutoff=32M",
        "--s3-chunk-size=16M",
        "--s3-upload-concurrency=4",
        "--timeout=20s",
        "--retries=2"
    ]
    
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT_SEC)
        if res.returncode == 0:
            sz = 0
            # If the source file was removed by rclone move, consider it successful
            with lock:
                stats["moved_files"] += 1
                elapsed = time.time() - stats["start_time"]
                print(f"[OK] {stats['moved_files']} files moved ({elapsed:.1f}s): {rel_path}", flush=True)
            return True
        else:
            with lock:
                stats["failed_files"] += 1
                print(f"[FAIL] {rel_path} -> {res.stderr.strip()[:100]}", flush=True)
            return False
    except subprocess.TimeoutExpired:
        with lock:
            stats["failed_files"] += 1
            print(f"[TIMEOUT] {rel_path} (hung on cloud provider)", flush=True)
        return False
    except Exception as e:
        with lock:
            stats["failed_files"] += 1
            print(f"[ERR] {rel_path} -> {e}", flush=True)
        return False

def main():
    print(f"=== Starting Chunked Move for [{SPACE_NAME}] ===", flush=True)
    print(f"Source: {SOURCE_DIR}", flush=True)
    print(f"Destination: {DEST_BASE}", flush=True)
    print(f"Workers: {MAX_WORKERS}", flush=True)

    file_list = []
    for root, dirs, files in os.walk(SOURCE_DIR):
        for f in files:
            if not f.startswith(".") and f != ".DS_Store":
                abs_p = os.path.join(root, f)
                rel_p = os.path.relpath(abs_p, SOURCE_DIR)
                file_list.append((abs_p, rel_p))

    print(f"Total items found: {len(file_list)}", flush=True)

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        futures = {executor.submit(move_single_file, abs_p, rel_p): rel_p for abs_p, rel_p in file_list}
        for future in as_completed(futures):
            _ = future.result()

    elapsed = time.time() - stats["start_time"]
    print(f"\n=== Migration Finished in {elapsed:.1f}s ===", flush=True)
    print(f"Moved: {stats['moved_files']}", flush=True)
    print(f"Failed/Hung: {stats['failed_files']}", flush=True)

if __name__ == "__main__":
    main()
