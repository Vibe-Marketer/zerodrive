#!/usr/bin/env bash
# ==============================================================================
# ZeroDrive Large Render & Bundle Multipart Uploader
# Streams files of ANY size (100MB to 5TB) to ZeroDrive R2 bypassing Worker body limits.
# Cross-platform: macOS (Apple Silicon/Intel), Linux, Windows (Git-Bash/WSL).
# ==============================================================================

set -eo pipefail

API_BASE="${ZERODRIVE_API_BASE:-https://api.zerodrive.dev}"
API_TOKEN="${ZERODRIVE_API_TOKEN:-zd_sec_b07b3671b1c45b32195f8353d4df8945ee31448699a361b32b6f8192a9b03633}"
CHUNK_SIZE_MB=45
LOCAL_FILE=""
VAULT_PATH=""
VERBOSE=false

show_help() {
  cat << EOF
Usage: $(basename "$0") --file <path> --vault-path <path> [options]

Required Arguments:
  -f, --file <path>         Local file path to upload
  -p, --vault-path <path>   Destination path in ZeroDrive vault (e.g. _REELFARM/renders/gymshark.mp4)

Optional Arguments:
  -c, --chunk-size-mb <int> Chunk size in megabytes (default: 45, max: 95)
  -b, --api-base <url>      ZeroDrive API URL (default: https://api.zerodrive.dev)
  -t, --token <token>       ZeroDrive API Token (or set ZERODRIVE_API_TOKEN env)
  -v, --verbose             Print detailed HTTP traces
  -h, --help                Show this help message
EOF
}

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)
      LOCAL_FILE="$2"
      shift 2
      ;;
    -p|--vault-path)
      VAULT_PATH="$2"
      shift 2
      ;;
    -c|--chunk-size-mb)
      CHUNK_SIZE_MB="$2"
      shift 2
      ;;
    -b|--api-base)
      API_BASE="$2"
      shift 2
      ;;
    -t|--token)
      API_TOKEN="$2"
      shift 2
      ;;
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      show_help
      exit 1
      ;;
  esac
done

if [[ -z "$LOCAL_FILE" || -z "$VAULT_PATH" ]]; then
  echo "Error: Both --file and --vault-path are required." >&2
  show_help
  exit 1
fi

if [[ ! -f "$LOCAL_FILE" ]]; then
  echo "Error: File not found at '$LOCAL_FILE'" >&2
  exit 1
fi

# Sanitize vault path (remove leading slash)
VAULT_PATH="${VAULT_PATH#/}"
API_BASE="${API_BASE%/}"

# Determine file size
FILE_SIZE=$(python3 -c "import os; print(os.path.getsize('''$LOCAL_FILE'''))")
FILE_SIZE_MB=$(python3 -c "print(f'{$FILE_SIZE / (1024 * 1024):.2f}')")

echo "=================================================="
echo " ZeroDrive Large File Uploader"
echo "=================================================="
echo " File:       $LOCAL_FILE ($FILE_SIZE_MB MB)"
echo " Vault Path: $VAULT_PATH"
echo " API Base:   $API_BASE"
echo "=================================================="

# Case 1: Direct single-pass upload if <= 80MB (83,886,080 bytes)
if [[ "$FILE_SIZE" -le 83886080 ]]; then
  echo "File size ($FILE_SIZE_MB MB) is under 80MB threshold. Streaming via direct PUT..."
  UPLOAD_URL="${API_BASE}/vault/upload?path=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$VAULT_PATH'''))")"
  
  HTTP_CODE=$(curl -sS -o /tmp/zd_upload_res.json -w "%{http_code}" -X PUT \
    -H "Authorization: Bearer $API_TOKEN" \
    --upload-file "$LOCAL_FILE" \
    "$UPLOAD_URL")
    
  if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
    echo "Upload succeeded (HTTP $HTTP_CODE):"
    cat /tmp/zd_upload_res.json
    echo ""
    exit 0
  else
    echo "Upload failed (HTTP $HTTP_CODE):" >&2
    cat /tmp/zd_upload_res.json >&2
    echo "" >&2
    exit 1
  fi
fi

# Case 2: Multipart chunked upload for files > 80MB (multi-GB renders)
echo "File size ($FILE_SIZE_MB MB) exceeds standard 80MB threshold."
echo "Initiating ZeroDrive R2 Multipart Session..."

INIT_RES=$(curl -sS -X POST "${API_BASE}/v1/files/multipart/create" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"path\": \"$VAULT_PATH\"}")

UPLOAD_ID=$(echo "$INIT_RES" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('upload_id') or data.get('uploadId') or '')" 2>/dev/null || echo "")

if [[ -z "$UPLOAD_ID" ]]; then
  echo "Error: Failed to initiate multipart upload. Server response:" >&2
  echo "$INIT_RES" >&2
  exit 1
fi

echo "Multipart session created. UploadId: $UPLOAD_ID"

# Setup scratch directory for temporary chunks
TMP_DIR=$(mktemp -d -t zd_multipart_XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

# Compute parts
CHUNK_BYTES=$(( CHUNK_SIZE_MB * 1024 * 1024 ))
TOTAL_PARTS=$(python3 -c "import math; print(math.ceil($FILE_SIZE / $CHUNK_BYTES))")
echo "Splitting into $TOTAL_PARTS chunk(s) of $CHUNK_SIZE_MB MB each..."

PARTS_JSON_FILE="$TMP_DIR/parts.json"
echo "[]" > "$PARTS_JSON_FILE"

for (( PART_NUM=1; PART_NUM<=TOTAL_PARTS; PART_NUM++ )); do
  PART_FILE="$TMP_DIR/part_${PART_NUM}.bin"
  SKIP_CHUNKS=$(( PART_NUM - 1 ))
  
  # Extract exact chunk using python
  python3 -c "
with open('$LOCAL_FILE', 'rb') as f:
    f.seek($SKIP_CHUNKS * $CHUNK_BYTES)
    chunk = f.read($CHUNK_BYTES)
    with open('$PART_FILE', 'wb') as out:
        out.write(chunk)
"
  
  PART_SIZE=$(python3 -c "import os; print(os.path.getsize('$PART_FILE'))")
  PART_SIZE_MB=$(python3 -c "print(f'{$PART_SIZE / (1024 * 1024):.2f}')")
  PERCENT=$(python3 -c "print(f'{($PART_NUM / $TOTAL_PARTS) * 100:.1f}')")
  
  echo -n "[Part $PART_NUM/$TOTAL_PARTS] ($PERCENT%) Uploading $PART_SIZE_MB MB... "
  
  PART_URL="${API_BASE}/v1/files/multipart/part?uploadId=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$UPLOAD_ID'''))")&partNumber=${PART_NUM}&path=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$VAULT_PATH'''))")"
  
  # Upload part with up to 3 retries
  SUCCESS=false
  for RETRY in 1 2 3; do
    PART_RES=$(curl -sS -X PUT \
      -H "Authorization: Bearer $API_TOKEN" \
      --upload-file "$PART_FILE" \
      "$PART_URL" || echo '{"error": "curl failed"}')
      
    ETAG=$(echo "$PART_RES" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('etag', ''))" 2>/dev/null || echo "")
    
    if [[ -n "$ETAG" ]]; then
      echo "OK (ETag: $ETAG)"
      # Record in parts ledger
      python3 -c "
import json
with open('$PARTS_JSON_FILE', 'r') as f:
    parts = json.load(f)
parts.append({'partNumber': $PART_NUM, 'etag': '$ETAG'})
with open('$PARTS_JSON_FILE', 'w') as f:
    json.dump(parts, f)
"
      SUCCESS=true
      rm -f "$PART_FILE"
      break
    else
      echo -n "(Retry $RETRY/3)... "
      sleep 2
    fi
  done
  
  if [[ "$SUCCESS" != "true" ]]; then
    echo "FAILED!" >&2
    echo "Aborting multipart session..." >&2
    curl -sS -X POST "${API_BASE}/v1/files/multipart/abort" \
      -H "Authorization: Bearer $API_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"path\": \"$VAULT_PATH\", \"uploadId\": \"$UPLOAD_ID\"}" >/dev/null || true
    exit 1
  fi
done

# Step 3: Complete multipart upload
echo "All $TOTAL_PARTS parts uploaded. Assembling final object in Cloudflare R2..."

COMPLETE_PAYLOAD=$(python3 -c "
import json
with open('$PARTS_JSON_FILE', 'r') as f:
    raw_parts = json.load(f)
parts = [{'part_number': p['partNumber'], 'partNumber': p['partNumber'], 'etag': p['etag']} for p in raw_parts]
payload = {
    'path': '$VAULT_PATH',
    'upload_id': '$UPLOAD_ID',
    'uploadId': '$UPLOAD_ID',
    'parts': parts
}
print(json.dumps(payload))
")

COMPLETE_RES=$(curl -sS -X POST "${API_BASE}/v1/files/multipart/complete" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$COMPLETE_PAYLOAD")

IS_OK=$(echo "$COMPLETE_RES" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('ok', False))" 2>/dev/null || echo "False")

if [[ "$IS_OK" == "True" ]]; then
  echo "=================================================="
  echo " SUCCESS: Large File Uploaded & Verified!"
  echo " Path:   $VAULT_PATH"
  echo " Size:   $FILE_SIZE_MB MB"
  echo " Remote: $COMPLETE_RES"
  echo "=================================================="
  exit 0
else
  echo "Error: Final assembly failed. Response:" >&2
  echo "$COMPLETE_RES" >&2
  exit 1
fi
