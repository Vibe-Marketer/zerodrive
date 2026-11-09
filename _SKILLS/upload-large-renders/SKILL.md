---
name: upload-large-renders
description: "Upload large video renders, archives, and multi-gigabyte bundles to ZeroDrive without hitting Cloudflare's 100MB body limit."
---

# Upload Large Renders

Use this skill whenever you need to upload video renders (.mp4, .mov, .mkv), render bundles, audio tracks, archives (.zip, .tar.gz), or any file larger than 80MB to ZeroDrive.

## The Rule

- **Files <= 80MB**: Standard upload via `create_upload_urls`, `upload_binary_file`, or direct `curl -X PUT --upload-file <file> <upload_url>`.
- **Files > 80MB**: DO NOT attempt to send the file in a single HTTP request to `/vault/upload` or via tool arguments. Cloudflare Workers enforces a hard 100MB request body limit and will return `413 Payload Too Large` or drop the socket.
- **Always use `upload-large-render.sh`** or the multipart chunk protocol for multi-megabyte and multi-gigabyte files.

## 1. Quick Upload Command (Recommended)

From any terminal or subshell where the file resides:

```bash
bash "$HOME/_LAB/zerodrive/scripts/upload-large-render.sh" \
  --file "./renders/gymshark-composite.mp4" \
  --vault-path "_REELFARM/renders/gymshark-composite.mp4"
```

Or from the fleet machines:
```bash
bash "$HOME/ZeroDrive/_SYSTEM/MACHINES/upload-large-render.sh" \
  --file "./render.mp4" \
  --vault-path "_REELFARM/renders/render.mp4"
```

This script automatically:
1. Calculates file size and chunk boundaries.
2. If <= 80MB, streams in one pass.
3. If > 80MB, slices into 45MB chunks.
4. Uploads parts in parallel or sequence to Cloudflare R2 via `/v1/files/multipart/*`.
5. Assembles the final object and verifies the ETag.
6. Triggers real-time SSE invalidation so macOS Finder and Windows Explorer update instantly.

## 2. Low-Level API Flow (If Script Is Unavailable)

If executing directly via `curl` or Python:

### Step 1: Initiate Multipart Session
```bash
curl -sS -X POST "https://api.zerodrive.dev/v1/files/multipart/create" \
  -H "Authorization: Bearer $ZERODRIVE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"path": "MAIN/renders/bundle.zip"}'
```
Returns: `{"ok": true, "uploadId": "xyz...", "path": "MAIN/renders/bundle.zip"}`

### Step 2: Slice and Upload Parts (45MB Chunks)
For each part `N` (1, 2, 3...):
```bash
curl -sS -X PUT "https://api.zerodrive.dev/v1/files/multipart/part?uploadId=xyz...&partNumber=1&path=MAIN/renders/bundle.zip" \
  -H "Authorization: Bearer $ZERODRIVE_API_TOKEN" \
  --data-binary "@part-001.tmp"
```
Returns: `{"ok": true, "partNumber": 1, "etag": "abc..."}`

### Step 3: Complete Multipart Assembly
```bash
curl -sS -X POST "https://api.zerodrive.dev/v1/files/multipart/complete" \
  -H "Authorization: Bearer $ZERODRIVE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "path": "MAIN/renders/bundle.zip",
    "uploadId": "xyz...",
    "parts": [
      {"partNumber": 1, "etag": "abc..."},
      {"partNumber": 2, "etag": "def..."}
    ]
  }'
```
Returns: `{"ok": true, "path": "MAIN/renders/bundle.zip", "size": 943718400, "etag": "...", "completed": true}`

### Step 4: Abort on Error (Optional Cleanup)
If a render is cancelled or an error occurs:
```bash
curl -sS -X POST "https://api.zerodrive.dev/v1/files/multipart/abort" \
  -H "Authorization: Bearer $ZERODRIVE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"path": "MAIN/renders/bundle.zip", "uploadId": "xyz..."}'
```

## 3. Verifying the Upload
After completion:
1. Verify metadata:
   `curl -sS -H "Authorization: Bearer $ZERODRIVE_API_TOKEN" "https://api.zerodrive.dev/v1/files/stat?path=MAIN/renders/bundle.zip"`
2. Finder (Mac) and Explorer (Windows) will show the file within 100ms via SSE invalidation.
