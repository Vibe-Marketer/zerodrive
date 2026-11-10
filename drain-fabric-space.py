#!/usr/bin/env python3
"""
Directly drains a space from Fabric Cloud via API into local disk and streams to ZeroDrive.
Bypasses the broken macOS FileProvider extension completely.
"""

import os
import sys
import json
import time
import urllib.request
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed

COOKIE_NAME = "fbc_sess_live"
COOKIE_VAL = "5YAKL72SAh9xj4dhWdyH3jq%2FuJmULT%2FwBT7k8cCR%2Fww%3D%3A1a17df68967"
NODES_JSON = os.path.expanduser("~/Library/Group Containers/3KCGYLP9VD.so.fabric.fileprovider/nodes-0ecf67ad-6fc2-4768-a3f6-87d7c9fdca9a.json")
RCLONE = "/Applications/ZeroDrive.app/Contents/Resources/rclone"
CONF = os.path.expanduser("~/.config/rclone/rclone.conf")
VAULT_BASE = "primary_vault:zerodrive-vault-prod/usr_andrew_8bc7fb477f"

def get_headers():
    return {
        "Cookie": f"{COOKIE_NAME}={COOKIE_VAL}",
        "User-Agent": "FabricCLI/0.1.8"
    }

def fetch_resource_download_url(res_id):
    clean_id = res_id.replace("res:", "")
    url = f"https://api.fabric.so/v2/resources/{clean_id}"
    req = urllib.request.Request(url, headers=get_headers())
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode())
            file_url = data.get("fileUrl") or data.get("downloadUrl")
            # If it's a note or markdown document without a fileUrl, check data.text or content
            text_content = None
            if not file_url and "data" in data and "text" in data["data"]:
                text_content = data["data"]["text"]
            return file_url, text_content
    except Exception as e:
        return None, None

def download_file(item, dest_root):
    # item: (clean_rel_path, node_info)
    rel_p, node = item
    dest_path = os.path.join(dest_root, rel_p)
    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
    
    # If already exists and matches size, skip
    expected_sz = node.get("size", 0)
    if expected_sz == 0:
        with open(dest_path, "wb") as f:
            pass
        return True, "empty_file", rel_p

    if os.path.exists(dest_path) and os.path.getsize(dest_path) == expected_sz and expected_sz > 0:
        return True, "already_exists", rel_p

    res_id = node.get("id")
    file_url, text_content = fetch_resource_download_url(res_id)
    
    if text_content is not None:
        with open(dest_path, "w", encoding="utf-8") as f:
            f.write(text_content)
        return True, "text_saved", rel_p

    if not file_url:
        return False, "no_download_url", rel_p

    try:
        req = urllib.request.Request(file_url, headers={"User-Agent": "FabricCLI/0.1.8"})
        with urllib.request.urlopen(req, timeout=30) as resp, open(dest_path, "wb") as f:
            f.write(resp.read())
        return True, "downloaded", rel_p
    except Exception as e:
        return False, str(e), rel_p

def main():
    if len(sys.argv) < 2:
        print("Usage: drain-fabric-space.py <space_name> [staging_dir]")
        sys.exit(1)

    space_name = sys.argv[1]
    staging_dir = sys.argv[2] if len(sys.argv) > 2 else f"/tmp/fabric-drain/{space_name}"
    os.makedirs(staging_dir, exist_ok=True)

    print(f"Loading nodes index for [{space_name}]...")
    with open(NODES_JSON, "r") as f:
        data = json.load(f)

    nodes = data.get("nodes", {})
    items = []
    
    for k, v in nodes.items():
        if v.get("isFolder"):
            continue
        p = v.get("path", [])
        # p is typically ["Spaces", space_name, ...]
        if len(p) > 2 and p[0] == "Spaces" and p[1] == space_name:
            rel_p = os.path.join(*p[2:])
            items.append((rel_p, v))
        elif len(p) == 2 and p[0] == "Spaces" and p[1] == space_name:
            # Single file at root of space
            rel_p = p[1]
            items.append((rel_p, v))

    print(f"Found {len(items)} files in space [{space_name}]. Staging in {staging_dir}...")

    success_cnt = 0
    fail_cnt = 0

    with ThreadPoolExecutor(max_workers=24) as pool:
        futures = {pool.submit(download_file, item, staging_dir): item[0] for item in items}
        for fut in as_completed(futures):
            rel_p = futures[fut]
            try:
                ok, reason, _ = fut.result()
                if ok:
                    success_cnt += 1
                    if success_cnt % 25 == 0 or success_cnt == len(items):
                        print(f"[{space_name}] Progress: {success_cnt}/{len(items)} files saved ({reason}: {os.path.basename(rel_p)})", flush=True)
                else:
                    fail_cnt += 1
                    print(f"[{space_name}] Failed: {rel_p} -> {reason}", flush=True)
            except Exception as e:
                fail_cnt += 1
                print(f"[{space_name}] Exception: {rel_p} -> {e}", flush=True)

    print(f"\nFinished download for [{space_name}]: {success_cnt} succeeded, {fail_cnt} failed.")

    if success_cnt > 0:
        print(f"\nUploading to ZeroDrive primary vault at {VAULT_BASE}/{space_name}...")
        cmd = [
            RCLONE,
            "copy",
            staging_dir,
            f"{VAULT_BASE}/{space_name}",
            f"--config={CONF}",
            "--transfers=8",
            "--s3-upload-concurrency=4",
            "-v"
        ]
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode == 0:
            print("✓ Rclone upload to ZeroDrive Vault succeeded!")
        else:
            print(f"✗ Rclone upload failed: {res.stderr.strip()[:300]}")

if __name__ == "__main__":
    main()
