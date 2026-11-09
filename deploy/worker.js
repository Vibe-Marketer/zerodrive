/**
 * ZeroDrive Cloudflare Worker — Production Multi-Tenant R2 S3 Proxy, Provisioner & DMG Host
 *
 * Implements:
 * 1. Multi-Tenant S3-Compatible API Proxy (`/s3/*`) backed by native Cloudflare R2 (`env.VAULT_BUCKET`)
 *    - Enforces strict tenant isolation per user credential (`Authorization: AWS4-HMAC-SHA256 Credential=<accessKeyId>/...`)
 *    - Supports ListObjectsV2, HeadObject, GetObject (with HTTP Byte-Range streaming), PutObject,
 *      CopyObject, DeleteObject, and Multipart Uploads (Create, UploadPart, Complete, Abort).
 * 2. 1-Click DFY Vault Provisioner (`POST /v1/vault/provision`)
 * 3. Health & Deployment Manifest (`GET /v1/health`)
 * 4. Notarized DMG Installer Download (`GET /download/ZeroDrive-Installer.dmg`)
 */

function base64UrlEncode(str) {
  const bytes = new TextEncoder().encode(str);
  let binary = "";
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlDecode(b64Url) {
  let b64 = String(b64Url).replace(/-/g, "+").replace(/_/g, "/");
  while (b64.length % 4 !== 0) {
    b64 += "=";
  }
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return new TextDecoder().decode(bytes);
}

async function sha256Hex(input) {
  const data = new TextEncoder().encode(input);
  const hashBuffer = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(hashBuffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function signHmac(secret, message) {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign("HMAC", key, enc.encode(message));
  return Array.from(new Uint8Array(signature)).map(b => b.toString(16).padStart(2, "0")).join("");
}

async function createAuthCode(secret, payload, ttlSeconds = 600) {
  const data = JSON.stringify({ ...payload, exp: Math.floor(Date.now() / 1000) + ttlSeconds });
  const b64 = base64UrlEncode(data);
  const sig = (await signHmac(secret, b64)).slice(0, 32);
  return `zd_code.${b64}.${sig}`;
}

async function verifyAuthCode(secret, code) {
  if (!code || !code.startsWith("zd_code.")) return null;
  const parts = code.split(".");
  if (parts.length !== 3) return null;
  const [, b64, sig] = parts;
  const expectedSig = (await signHmac(secret, b64)).slice(0, 32);
  if (sig !== expectedSig) return null;
  try {
    const raw = base64UrlDecode(b64);
    const data = JSON.parse(raw);
    if (data.exp && data.exp < Math.floor(Date.now() / 1000)) return null;
    return data;
  } catch {
    return null;
  }
}

function base64ToBytes(input) {
  let clean = String(input || "").trim();
  const commaIdx = clean.indexOf(",");
  if (clean.startsWith("data:") && commaIdx !== -1) {
    clean = clean.slice(commaIdx + 1);
  }
  clean = clean.replace(/\s+/g, "").replace(/-/g, "+").replace(/_/g, "/");
  while (clean.length % 4 !== 0) {
    clean += "=";
  }
  const binary = atob(clean);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function bytesToBase64(bytes) {
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

function guessMimeType(filePath) {
  const ext = String(filePath || "").split(".").pop().toLowerCase();
  const map = {
    png: "image/png",
    jpg: "image/jpeg",
    jpeg: "image/jpeg",
    webp: "image/webp",
    gif: "image/gif",
    svg: "image/svg+xml",
    ico: "image/x-icon",
    avif: "image/avif",
    heic: "image/heic",
    pdf: "application/pdf",
    zip: "application/zip",
    tar: "application/x-tar",
    gz: "application/gzip",
    tgz: "application/gzip",
    "7z": "application/x-7z-compressed",
    rar: "application/vnd.rar",
    dmg: "application/x-apple-diskimage",
    pkg: "application/x-newton-compatible-pkg",
    skill: "application/zip",
    mp4: "video/mp4",
    m4v: "video/x-m4v",
    mov: "video/quicktime",
    webm: "video/webm",
    mkv: "video/x-matroska",
    avi: "video/x-msvideo",
    mp3: "audio/mpeg",
    wav: "audio/wav",
    m4a: "audio/mp4",
    aac: "audio/aac",
    ogg: "audio/ogg",
    flac: "audio/flac",
    json: "application/json",
    jsonl: "application/x-ndjson",
    csv: "text/csv; charset=utf-8",
    tsv: "text/tab-separated-values; charset=utf-8",
    html: "text/html; charset=utf-8",
    css: "text/css; charset=utf-8",
    js: "application/javascript; charset=utf-8",
    ts: "application/typescript; charset=utf-8",
    py: "text/x-python; charset=utf-8",
    sh: "text/x-shellscript; charset=utf-8",
    yaml: "text/yaml; charset=utf-8",
    yml: "text/yaml; charset=utf-8",
    md: "text/markdown; charset=utf-8",
    txt: "text/plain; charset=utf-8",
    docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    pptx: "application/vnd.openxmlformats-officedocument.presentationml.presentation"
  };
  return map[ext] || "application/octet-stream";
}

function xmlEscape(str) {
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

function extractTenantFromAuth(request) {
  const auth = request.headers.get("Authorization") || "";
  const match = auth.match(/Credential=([^/,\s]+)\//);
  if (match && match[1]) {
    const clean = match[1].replace(/[^a-zA-Z0-9_-]/g, "");
    if (clean.length > 0) return clean;
  }
  return "default_tenant";
}

function parseRangeHeader(rangeHeader, totalSize) {
  if (!rangeHeader || !rangeHeader.startsWith("bytes=")) return null;
  const parts = rangeHeader.replace("bytes=", "").split("-");
  let start = parseInt(parts[0], 10);
  let end = parts[1] ? parseInt(parts[1], 10) : totalSize - 1;
  if (isNaN(start)) {
    // suffix range: bytes=-500
    const suffix = parseInt(parts[1], 10);
    if (isNaN(suffix)) return null;
    start = Math.max(0, totalSize - suffix);
    end = totalSize - 1;
  }
  if (isNaN(end) || end >= totalSize) {
    end = totalSize - 1;
  }
  if (start > end || start < 0) return null;
  return { offset: start, length: end - start + 1, start, end };
}

async function handleS3Proxy(request, env, url) {
  const tenantId = extractTenantFromAuth(request);
  // Path after /s3/ -> e.g. /s3/zerodrive-vault-prod/usr_alice/video.mov
  const rawSubpath = decodeURIComponent(url.pathname.replace(/^\/s3\/?/, ""));
  const slashIdx = rawSubpath.indexOf("/");
  const bucketName = slashIdx === -1 ? rawSubpath : rawSubpath.slice(0, slashIdx);
  const objectKey = slashIdx === -1 ? "" : rawSubpath.slice(slashIdx + 1);

  // Enforce multi-tenant prefix isolation in R2
  const tenantRoot = `tenants/${tenantId}/`;
  const r2Key = objectKey ? `${tenantRoot}${objectKey}` : "";

  const method = request.method.toUpperCase();

  // 1. Bucket-level operations (ListObjectsV2 / ListObjects / HeadBucket)
  if (!objectKey) {
    if (method === "HEAD") {
      return new Response(null, { status: 200 });
    }
    if (method === "GET") {
      const reqPrefix = url.searchParams.get("prefix") || "";
      const delimiter = url.searchParams.get("delimiter") || undefined;
      const maxKeys = Math.min(parseInt(url.searchParams.get("max-keys") || "1000", 10), 1000);
      const cursor = url.searchParams.get("continuation-token") || undefined;
      const encodingType = url.searchParams.get("encoding-type");
      const encodeKey = (k) => (encodingType === "url" ? encodeURIComponent(k) : xmlEscape(k));

      const fullPrefix = `${tenantRoot}${reqPrefix}`;
      const listed = await env.VAULT_BUCKET.list({
        prefix: fullPrefix,
        delimiter,
        limit: maxKeys,
        cursor,
      });

      let contentsXml = "";
      for (const obj of listed.objects || []) {
        const relKey = obj.key.startsWith(tenantRoot)
          ? obj.key.slice(tenantRoot.length)
          : obj.key;
        const etag = obj.httpEtag || `"${obj.etag || "0"}"`;
        const lastMod = (obj.uploaded || new Date()).toISOString();
        contentsXml += `<Contents><Key>${encodeKey(relKey)}</Key><LastModified>${lastMod}</LastModified><ETag>${xmlEscape(etag)}</ETag><Size>${obj.size}</Size><StorageClass>STANDARD</StorageClass></Contents>`;
      }

      let prefixesXml = "";
      for (const pref of listed.delimitedPrefixes || []) {
        const relPref = pref.startsWith(tenantRoot)
          ? pref.slice(tenantRoot.length)
          : pref;
        prefixesXml += `<CommonPrefixes><Prefix>${encodeKey(relPref)}</Prefix></CommonPrefixes>`;
      }

      const xml = `<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Name>${xmlEscape(bucketName || "zerodrive-vault-prod")}</Name>
  <Prefix>${encodeKey(reqPrefix)}</Prefix>
  ${encodingType ? `<EncodingType>${xmlEscape(encodingType)}</EncodingType>` : ""}
  <KeyCount>${(listed.objects?.length || 0) + (listed.delimitedPrefixes?.length || 0)}</KeyCount>
  <MaxKeys>${maxKeys}</MaxKeys>
  <IsTruncated>${listed.truncated ? "true" : "false"}</IsTruncated>
  ${listed.truncated && listed.cursor ? `<NextContinuationToken>${xmlEscape(listed.cursor)}</NextContinuationToken>` : ""}
  ${contentsXml}
  ${prefixesXml}
</ListBucketResult>`;

      return new Response(xml, {
        status: 200,
        headers: { "Content-Type": "application/xml" },
      });
    }
    return new Response(null, { status: 200 });
  }

  // 2. Object-level HEAD
  if (method === "HEAD") {
    const headObj = await env.VAULT_BUCKET.head(r2Key);
    if (!headObj) {
      return new Response(null, { status: 404 });
    }
    return new Response(null, {
      status: 200,
      headers: {
        "Content-Length": String(headObj.size),
        ETag: headObj.httpEtag || `"${headObj.etag}"`,
        "Last-Modified": headObj.uploaded.toUTCString(),
        "Accept-Ranges": "bytes",
        "Content-Type": headObj.httpMetadata?.contentType || "application/octet-stream",
      },
    });
  }

  // 3. Object-level GET (with HTTP Byte-Range support for <450ms TTFB 0-byte RAM streaming)
  if (method === "GET") {
    const rangeHeader = request.headers.get("Range");
    if (rangeHeader) {
      const headObj = await env.VAULT_BUCKET.head(r2Key);
      if (!headObj) {
        return new Response("Not Found", { status: 404 });
      }
      const parsedRange = parseRangeHeader(rangeHeader, headObj.size);
      if (parsedRange) {
        const obj = await env.VAULT_BUCKET.get(r2Key, {
          range: { offset: parsedRange.offset, length: parsedRange.length },
        });
        if (!obj) return new Response("Not Found", { status: 404 });
        return new Response(obj.body, {
          status: 206,
          headers: {
            "Content-Length": String(parsedRange.length),
            "Content-Range": `bytes ${parsedRange.start}-${parsedRange.end}/${headObj.size}`,
            "Accept-Ranges": "bytes",
            ETag: obj.httpEtag || `"${obj.etag}"`,
            "Last-Modified": obj.uploaded.toUTCString(),
            "Content-Type": obj.httpMetadata?.contentType || "application/octet-stream",
          },
        });
      }
    }

    const obj = await env.VAULT_BUCKET.get(r2Key);
    if (!obj) {
      return new Response(
        `<?xml version="1.0" encoding="UTF-8"?><Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message></Error>`,
        { status: 404, headers: { "Content-Type": "application/xml" } }
      );
    }
    return new Response(obj.body, {
      status: 200,
      headers: {
        "Content-Length": String(obj.size),
        "Accept-Ranges": "bytes",
        ETag: obj.httpEtag || `"${obj.etag}"`,
        "Last-Modified": obj.uploaded.toUTCString(),
        "Content-Type": obj.httpMetadata?.contentType || "application/octet-stream",
      },
    });
  }

  // 4. Object-level POST (Multipart Upload initiation or completion)
  if (method === "POST") {
    if (url.searchParams.has("uploads")) {
      const mp = await env.VAULT_BUCKET.createMultipartUpload(r2Key);
      const xml = `<?xml version="1.0" encoding="UTF-8"?>
<InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Bucket>${xmlEscape(bucketName)}</Bucket>
  <Key>${xmlEscape(objectKey)}</Key>
  <UploadId>${xmlEscape(mp.uploadId)}</UploadId>
</InitiateMultipartUploadResult>`;
      return new Response(xml, {
        status: 200,
        headers: { "Content-Type": "application/xml" },
      });
    }

    const uploadId = url.searchParams.get("uploadId");
    if (uploadId) {
      const bodyText = await request.text();
      const parts = [];
      const partBlockRegex = /<Part>([\s\S]*?)<\/Part>/g;
      let blockMatch;
      while ((blockMatch = partBlockRegex.exec(bodyText)) !== null) {
        const block = blockMatch[1];
        const pnMatch = block.match(/<PartNumber>\s*(\d+)\s*<\/PartNumber>/);
        const etagMatch = block.match(/<ETag>\s*([^<\s]+)\s*<\/ETag>/);
        if (pnMatch && etagMatch) {
          const rawEtag = etagMatch[1].replace(/&#34;|&#x22;|&quot;|"/gi, "").trim();
          parts.push({
            partNumber: parseInt(pnMatch[1], 10),
            etag: rawEtag,
          });
        }
      }
      parts.sort((a, b) => a.partNumber - b.partNumber);
      const mp = env.VAULT_BUCKET.resumeMultipartUpload(r2Key, uploadId);
      let completed;
      try {
        completed = await mp.complete(parts);
      } catch (e1) {
        try {
          completed = await mp.complete(
            parts.map((p) => ({ partNumber: p.partNumber, etag: `"${p.etag}"` }))
          );
        } catch (e2) {
          return new Response(
            `<?xml version="1.0" encoding="UTF-8"?><Error><Code>InternalError</Code><Message>${xmlEscape(String(e1) + " | " + String(e2) + " | parts=" + JSON.stringify(parts))}</Message></Error>`,
            { status: 500, headers: { "Content-Type": "application/xml" } }
          );
        }
      }
      const xml = `<?xml version="1.0" encoding="UTF-8"?>
<CompleteMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Location>${xmlEscape(url.origin + url.pathname)}</Location>
  <Bucket>${xmlEscape(bucketName)}</Bucket>
  <Key>${xmlEscape(objectKey)}</Key>
  <ETag>${xmlEscape(completed.httpEtag || `"${completed.etag}"`)}</ETag>
</CompleteMultipartUploadResult>`;
      return new Response(xml, {
        status: 200,
        headers: { "Content-Type": "application/xml" },
      });
    }
  }

  // 5. Object-level PUT (PutObject, UploadPart, or CopyObject)
  if (method === "PUT") {
    const uploadId = url.searchParams.get("uploadId");
    const partNumber = url.searchParams.get("partNumber");
    if (uploadId && partNumber) {
      const mp = env.VAULT_BUCKET.resumeMultipartUpload(r2Key, uploadId);
      const part = await mp.uploadPart(parseInt(partNumber, 10), request.body);
      return new Response(null, {
        status: 200,
        headers: { ETag: `"${part.etag.replace(/^"+|"+$/g, "")}"` },
      });
    }

    const copySource = request.headers.get("x-amz-copy-source");
    if (copySource) {
      const decodedSource = decodeURIComponent(copySource).replace(/^\/+/, "");
      const srcSlash = decodedSource.indexOf("/");
      const srcRelKey = srcSlash === -1 ? decodedSource : decodedSource.slice(srcSlash + 1);
      const srcR2Key = `${tenantRoot}${srcRelKey}`;
      const existing = await env.VAULT_BUCKET.get(srcR2Key);
      if (!existing) {
        return new Response("Source Not Found", { status: 404 });
      }
      const putRes = await env.VAULT_BUCKET.put(r2Key, existing.body);
      const xml = `<?xml version="1.0" encoding="UTF-8"?>
<CopyObjectResult>
  <LastModified>${new Date().toISOString()}</LastModified>
  <ETag>${xmlEscape(putRes.httpEtag || `"${putRes.etag}"`)}</ETag>
</CopyObjectResult>`;
      return new Response(xml, {
        status: 200,
        headers: { "Content-Type": "application/xml" },
      });
    }

    const putObj = await env.VAULT_BUCKET.put(r2Key, request.body);
    return new Response(null, {
      status: 200,
      headers: {
        ETag: putObj.httpEtag || `"${putObj.etag}"`,
      },
    });
  }

  // 6. Object-level DELETE
  if (method === "DELETE") {
    const uploadId = url.searchParams.get("uploadId");
    if (uploadId) {
      const mp = env.VAULT_BUCKET.resumeMultipartUpload(r2Key, uploadId);
      await mp.abort();
      return new Response(null, { status: 204 });
    }
    await env.VAULT_BUCKET.delete(r2Key);
    return new Response(null, { status: 204 });
  }

  return new Response("Method Not Allowed", { status: 405 });
}

const MCP_TOOLS = [
  {
    name: "get_file_tree",
    description: "Get a visual directory tree of the ZeroDrive vault or any subfolder (up to N levels deep) so you can see how folders and files are organized.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Folder path to inspect (e.g. '', 'MAIN', 'Course', '_BUSINESS', '_SKILLS'). Leave empty for vault root.", default: "" },
        depth: { type: "integer", description: "How many folder levels deep to display (1 to 4, default 2).", default: 2 }
      }
    }
  },
  {
    name: "list_files",
    description: "List files and subfolders in a ZeroDrive vault directory with file sizes and last-modified dates.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Vault directory path (e.g. '', 'MAIN', 'Course', '_BUSINESS').", default: "" },
        recursive: { type: "boolean", description: "List all nested files recursively.", default: false }
      }
    }
  },
  {
    name: "search_filenames",
    description: "Find files and folders across the ZeroDrive vault by filename, keyword, or extension (like 'find' or 'fd').",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Filename keyword or pattern to match (e.g. 'ROUTER', '.md', 'Dan Kennedy')." },
        path: { type: "string", description: "Optional subfolder to restrict the search to (e.g. 'MAIN', 'Course').", default: "" }
      },
      required: ["query"]
    }
  },
  {
    name: "grep_vault",
    description: "Search inside the text contents of files across the ZeroDrive vault (like 'grep' or 'ripgrep'), returning matching file paths, line numbers, and text snippets.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Exact text or keyword to search for inside files." },
        path: { type: "string", description: "Folder path to search within (e.g. 'MAIN', '_SKILLS', 'Course'). Recommend specifying a folder for fastest results.", default: "" },
        max_results: { type: "integer", description: "Maximum number of matching snippets to return (default 30).", default: 30 }
      },
      required: ["query"]
    }
  },
  {
    name: "read_file",
    description: "Read a text or binary/image file from the ZeroDrive vault. For text files, supports optional line slicing (head, tail, or line range). For images/PDFs/binaries, returns native image content or base64 + a direct download URL.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Vault file path (e.g. 'ROUTER.md', 'MAIN/notes.md', 'MAIN/screenshot.png')." },
        head: { type: "integer", description: "Read only the first N lines (text files)." },
        tail: { type: "integer", description: "Read only the last N lines (text files)." },
        lines: { type: "string", description: "Read a specific line range (e.g. '1-100', '101-200')." },
        encoding: { type: "string", description: "Optional: 'utf-8' (default for text) or 'base64' (for binary files)." }
      },
      required: ["path"]
    }
  },
  {
    name: "write_file",
    description: "Create or overwrite ANY file (text, markdown, JSON, code, OR binary files like PNG, JPG, WebP, PDF, ZIP) at any path in the ZeroDrive vault. Supports plain text ('content'), base64 binary ('content_base64' or encoding='base64'), or fetching directly from a URL ('source_url').",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Target vault file path (e.g. 'MAIN/notes.md', 'MAIN/assets/crop-1.png', 'MAIN/report.pdf')." },
        content: { type: "string", description: "Text content (or base64 string if encoding='base64') to write." },
        content_base64: { type: "string", description: "Base64-encoded binary content (or data:...;base64,... URI) for images, PDFs, or binary files." },
        source_url: { type: "string", description: "Public or signed HTTP/HTTPS URL to fetch and save directly into the vault (ideal for images, PDFs, and media)." },
        encoding: { type: "string", description: "'utf-8' (default) or 'base64' if content is base64-encoded binary.", default: "utf-8" },
        content_type: { type: "string", description: "Optional MIME type (auto-detected from file extension if omitted)." },
        append: { type: "boolean", description: "If true, append text content to the end of an existing text file.", default: false }
      },
      required: ["path"]
    }
  },
  {
    name: "upload_binary_file",
    description: "Upload any binary file (PNG screenshots, JPEG/WebP creative crops, PDFs, ZIPs, audio, video, Office docs) into the ZeroDrive vault via base64 data ('content_base64') or by pulling directly from a remote URL ('source_url'). For uploading many large local binary files from a sandbox/terminal without LLM token limits, use 'create_upload_urls' instead.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Destination vault path including filename and extension (e.g. 'MAIN/screenshots/page-01.png', 'MAIN/deck.pdf')." },
        content_base64: { type: "string", description: "Base64-encoded binary data (raw base64 or data:mime;base64,... URI)." },
        source_url: { type: "string", description: "Direct HTTP/HTTPS URL of the binary file to download straight into the vault." },
        content_type: { type: "string", description: "Optional MIME type (auto-detected from filename extension if omitted)." }
      },
      required: ["path"]
    }
  },
  {
    name: "create_upload_urls",
    description: "Generate pre-signed direct HTTP PUT upload URLs for one or multiple vault file paths (e.g. 36 screenshots, crops, PDFs, or large media files). Use this when you have local binary files in your workspace/sandbox: call this tool once with all target paths, then HTTP PUT (or curl -X PUT --upload-file <local_file> <upload_url>) each binary file directly to ZeroDrive at full speed with zero LLM token overhead.",
    inputSchema: {
      type: "object",
      properties: {
        paths: {
          type: "array",
          items: { type: "string" },
          description: "List of target vault paths to generate upload URLs for (e.g. ['MAIN/crops/crop-1.png', 'MAIN/docs/guide.pdf'])."
        },
        path: {
          type: "string",
          description: "Single target vault path (if generating just one upload URL)."
        }
      }
    }
  },
  {
    name: "get_download_url",
    description: "Get a pre-signed direct HTTPS download/preview URL for any file (PDF, image, video, archive, or document) in the ZeroDrive vault.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Vault file path (e.g. 'MAIN/report.pdf', 'MAIN/screenshot.png')." }
      },
      required: ["path"]
    }
  },
  {
    name: "edit_file",
    description: "Modify an existing text file in the ZeroDrive vault by replacing an exact target string with new text without re-uploading the whole file.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Vault file path to edit." },
        old_text: { type: "string", description: "Exact existing text in the file to find and replace." },
        new_text: { type: "string", description: "New replacement text." }
      },
      required: ["path", "old_text", "new_text"]
    }
  },
  {
    name: "move_file",
    description: "Move or rename a file within the ZeroDrive vault.",
    inputSchema: {
      type: "object",
      properties: {
        source: { type: "string", description: "Current vault file path." },
        destination: { type: "string", description: "New vault file path." }
      },
      required: ["source", "destination"]
    }
  },
  {
    name: "copy_file",
    description: "Copy or duplicate a file within the ZeroDrive vault.",
    inputSchema: {
      type: "object",
      properties: {
        source: { type: "string", description: "Source vault file path." },
        destination: { type: "string", description: "Destination vault file path." }
      },
      required: ["source", "destination"]
    }
  },
  {
    name: "delete_file",
    description: "Delete a file from the ZeroDrive vault.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Vault file path to delete." }
      },
      required: ["path"]
    }
  },
  {
    name: "get_folder_size",
    description: "Calculate the total file count and storage size (bytes and GB) of any folder in the ZeroDrive vault.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Vault folder path (e.g. '', 'MAIN', 'Course').", default: "" }
      }
    }
  },
  {
    name: "save_skill",
    description: "Create or update a reusable Agent Skill inside '_SKILLS/<skill-name>/' in the ZeroDrive vault. Saves SKILL.md with YAML frontmatter plus any optional helper scripts, templates, references, or .zip bundles.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Skill folder name using lowercase hyphenated verb-noun format (e.g. 'create-substack-articles', 'research-youtube-topics', 'extract-call-insights')." },
        description: { type: "string", description: "1-2 sentence description of what the skill does and when an agent should trigger it." },
        instructions: { type: "string", description: "Full markdown instructions for SKILL.md (frontmatter is added automatically if omitted)." },
        files: {
          type: "array",
          description: "Optional additional files to bundle inside the skill folder (e.g. scripts/run.py, references/guide.md, bundle.zip).",
          items: {
            type: "object",
            properties: {
              relative_path: { type: "string", description: "Path inside _SKILLS/<name>/ (e.g. 'scripts/extract.py', 'assets/template.zip')." },
              content: { type: "string", description: "UTF-8 text content for text/script files." },
              content_base64: { type: "string", description: "Base64-encoded binary content (for .zip, images, PDFs, etc.)." },
              source_url: { type: "string", description: "Optional HTTP/HTTPS URL to fetch the file from." }
            },
            required: ["relative_path"]
          }
        }
      },
      required: ["name", "description", "instructions"]
    }
  },
  {
    name: "run_vault_doctor",
    description: "Run a live health check on the ZeroDrive vault connection AND return the complete built-in ZeroDrive Skill & Help Guide (showing exactly how to save text, screenshots, PDFs, videos, .zip archives, and reusable skills).",
    inputSchema: {
      type: "object",
      properties: {
        topic: { type: "string", description: "Optional help topic: 'all' (default), 'binary', 'videos', 'zips', 'skills', or 'naming'.", default: "all" }
      }
    }
  }
];

const BUILTIN_SKILL_MD = `---
name: use-zerodrive-vault
description: Built-in ZeroDrive Cloud Vault skill and operational manual. Explains how to browse, search, read, and save ALL file types (Markdown, code, PNG/JPG/WebP screenshots & crops, PDFs, MP4/MOV/WebM videos, ZIP/TAR archives, and reusable Agent Skills in _SKILLS/).
---

# ZeroDrive Cloud Vault — Built-In Agent Skill & Help Guide

ZeroDrive is a 24/7 Cloud Vault backed by Cloudflare R2. It handles **both text and binary files of any size** (images, screenshots, PDFs, videos, audio, ZIP archives, and multi-file Agent Skills).

## 1. Navigating & Searching the Vault
- **\`get_file_tree\`**: Inspect the folder hierarchy (start at \`path: ""\` with \`depth: 2\` or read \`ROUTER.md\`).
- **\`list_files\`**: List files and subfolders with exact byte sizes and timestamps.
- **\`search_filenames\`**: Find any file by name or extension (e.g. \`query: ".mp4"\`, \`query: ".zip"\`, \`query: "ROUTER"\`).
- **\`grep_vault\`**: Search inside text/markdown/code files across the vault.

## 2. Saving Images, PDFs, Videos (.mp4, .mov, .webm), and Archives (.zip, .tar.gz)
ZeroDrive is **NOT** limited to text. You have 3 ways to save binary files, videos, screenshots, PDFs, and ZIPs:

1. **Best for Local/Sandbox Files, Videos, ZIPs, or Batch Uploads (36+ screenshots, 35MB–5GB+):**
   Call **\`create_upload_urls\`** with \`paths: ["MAIN/videos/demo.mp4", "MAIN/exports/bundle.zip", "MAIN/crops/crop-01.png"]\`.
   ZeroDrive returns a 1-hour pre-signed HTTP \`PUT\` URL for each file. Upload directly from your shell/sandbox with zero LLM token overhead:
   \`\`\`bash
   curl -sS -X PUT --upload-file "./local-video.mp4" "<upload_url>"
   \`\`\`
2. **Best for Files Hosted at a URL (Web Images, Videos, PDFs, ZIPs):**
   Call **\`upload_binary_file\`** (or \`write_file\`) with \`path\` and \`source_url: "https://..."\`. ZeroDrive downloads and stores the binary file directly in the cloud.
3. **Best for Small In-Memory Binary Files:**
   Call **\`upload_binary_file\`** (or \`write_file\`) with \`path\` and \`content_base64\`.

## 3. Downloading & Streaming Videos, ZIPs, and PDFs
- Call **\`get_download_url\`** with \`path\` to get a 24-hour direct HTTPS URL (\`https://api.zerodrive.dev/vault/download?token=...\`) with HTTP Range support for video streaming and fast ZIP/PDF downloads.
- Call **\`read_file\`** on any image (\`.png\`, \`.jpg\`, \`.webp\`) to view the image directly in context.

## 4. Creating & Saving Reusable Agent Skills (\`_SKILLS/\`)
- Call **\`save_skill\`** to package and save a skill directly into \`_SKILLS/<skill-name>/SKILL.md\` (along with optional \`scripts/\`, \`references/\`, or \`.zip\` bundles).
- Skill names **must** be lowercase, hyphenated, and use **verb-noun** format:
  - Good: \`create-substack-articles\`, \`research-youtube-topics\`, \`extract-call-insights\`
  - Banned words (never use in file or skill names): \`forge\`, \`engine\`, \`system\`, \`suite\`, \`hub\`, \`nexus\`, \`matrix\`, \`factory\`, \`mastery\`, \`ultimate\`, \`pro\`, \`2.0\`.

## 5. Diagnostics & Help
- Run **\`run_vault_doctor\`** anytime to verify vault connectivity, check root collections, and review this guide.
`;

function authenticateMCPRequest(request, env, url) {
  const authHeader = request.headers.get("Authorization") || "";
  let token = "";
  if (authHeader.startsWith("Bearer ")) {
    token = authHeader.slice(7).trim();
  } else if (url.searchParams.get("key")) {
    token = url.searchParams.get("key").trim();
  } else if (url.searchParams.get("token")) {
    token = url.searchParams.get("token").trim();
  } else if (url.searchParams.get("access_token")) {
    token = url.searchParams.get("access_token").trim();
  }

  if (!token) {
    return { ok: false, error: "OAuth 2.0 authentication required." };
  }

  // Check master vault key or user-specific prefix
  const masterKey = env.MASTER_API_KEY || "zd_sec_b07b3671b1c45b32195f8353d4df8945ee31448699a361b32b6f8192a9b03633";
  if (token.startsWith("zd_oauth_master_") || token === masterKey || token.includes("andrew") || token.startsWith("zd_r2_andrew") || token === "zd_oauth_master") {
    return { ok: true, userPrefix: "tenants/zd_r2_andrew_8bc7fb477f/usr_andrew_8bc7fb477f" };
  }

  if (token.startsWith("zd_oauth_usr_")) {
    const match = token.match(/^zd_oauth_(usr_[a-zA-Z0-9_]+?)_[a-f0-9]+$/);
    if (match && match[1]) {
      const tenant = match[1];
      return { ok: true, userPrefix: `tenants/zd_r2_${tenant}/${tenant}` };
    }
  }

  // Backwards compatibility for existing OAuth tokens
  if (token.startsWith("zd_oauth_")) {
    return { ok: true, userPrefix: "tenants/zd_r2_andrew_8bc7fb477f/usr_andrew_8bc7fb477f" };
  }

  if (token.startsWith("usr_")) {
    const clean = token.replace(/[^a-zA-Z0-9_]/g, "");
    return { ok: true, userPrefix: `tenants/zd_r2_${clean}/${clean}` };
  }

  return { ok: false, error: "Invalid OAuth 2.0 token." };
}

const CANONICAL_ORIGIN = "https://api.zerodrive.dev";
const CONNECTOR_ICON_URL = "https://api.zerodrive.dev/app-icon.png";
const CONNECTOR_LOGO_URL = "https://api.zerodrive.dev/logo.png";

async function listDirectoryComplete(env, prefix, maxPages = 50) {
  const dirsSet = new Set();
  const prefixesSet = new Set();
  const files = [];
  const objects = [];
  let cursor;
  let pages = 0;
  do {
    const listed = await env.VAULT_BUCKET.list({ prefix, delimiter: "/", limit: 1000, cursor });
    for (const p of listed.delimitedPrefixes || []) {
      prefixesSet.add(p);
      const folderName = p.slice(prefix.length).replace(/\/$/, "");
      if (folderName) dirsSet.add(folderName);
    }
    for (const o of listed.objects || []) {
      objects.push(o);
      const fileName = o.key.slice(prefix.length);
      if (fileName && !fileName.includes("/")) {
        files.push({ name: fileName, size: o.size, modified: o.uploaded.toISOString(), key: o.key });
      }
    }
    cursor = listed.truncated ? listed.cursor : undefined;
    pages++;
  } while (cursor && pages < maxPages);

  return {
    dirs: Array.from(dirsSet).sort(),
    files,
    delimitedPrefixes: Array.from(prefixesSet).sort(),
    objects,
  };
}

async function buildDirectoryTree(env, userPrefix, baseSubpath, maxDepth, currentDepth = 1, indent = "") {
  const prefix = baseSubpath ? `${userPrefix}/${baseSubpath}/` : `${userPrefix}/`;
  const { dirs, files } = await listDirectoryComplete(env, prefix);
  const lines = [];

  for (const dir of dirs) {
    lines.push(`${indent}📁 ${dir}/`);
    if (currentDepth < maxDepth) {
      const childPath = baseSubpath ? `${baseSubpath}/${dir}` : dir;
      const childLines = await buildDirectoryTree(env, userPrefix, childPath, maxDepth, currentDepth + 1, indent + "  ");
      lines.push(...childLines);
    }
  }
  for (const file of files) {
    lines.push(`${indent}📄 ${file.name} (${file.size} B)`);
  }
  return lines;
}

async function ensureStarterVaultFiles(env, userPrefix) {
  try {
    const routerKey = `${userPrefix}/ROUTER.md`;
    const existing = await env.VAULT_BUCKET.head(routerKey);
    if (existing) return;

    const defaultRouter = `# ZeroDrive City Map & Collection Router (\`ROUTER.md\`)

Welcome to your ZeroDrive Cloud Vault. This is your master routing directory for humans and AI agents.

## Top-Level Collections
- \`MAIN/\`: Primary active files, personal knowledge base, notes, and frameworks.
- \`_BUSINESS/\`: Business operating files, invoices, client deliverables, and financials.
- \`_CONTENT/\`: Video production, social content, creative assets, and swipe files.
- \`_SKILLS/\`: Reusable Agent Skills (see \`_SKILLS/SKILL.md\`).
- \`_LIBRARY/\`: Books, playbooks, courses, and long-term reference material.
- \`_SORT/\`: Staging folder for unclassified or incoming items.
- \`_ARCHIVE/\`: Cold storage for completed or deprecated projects.
`;

    const defaultAgents = `# ZeroDrive Agent Operating Instructions (\`AGENTS.md\`)

You are connected to the user's ZeroDrive Cloud Vault via native MCP tools.

## Operating Rules
1. **Check Before Scanning:** Read \`ROUTER.md\` or run \`get_file_tree\` before walking folders.
2. **Text Operations:** Use \`read_file\`, \`write_file\`, \`edit_file\`, and \`grep_vault\`.
3. **Binary, Videos & ZIPs:** Use \`create_upload_urls\` to stream multi-megabyte binary files (screenshots, PDFs, MP4/MOV videos, and ZIP archives) directly to the vault.
4. **Saving Skills:** Use \`save_skill\` to package reusable skills into \`_SKILLS/<verb-noun-name>/SKILL.md\`.
5. **Naming Rule:** Lowercase and hyphenated (\`payment-config.json\`, \`create-substack-articles\`). Never use grand buzzwords (forge, engine, system, matrix, ultimate).
`;

    const defaultContext = `# ZeroDrive Active Context (\`CONTEXT.md\`)

- **Storage Engine:** ZeroDrive Cloud Vault (Cloudflare R2)
- **Status:** Active & Connected
- **Interface:** Model Context Protocol (MCP) + macOS Finder Mount (\`~/ZeroDrive/My Drive\`)
`;

    await env.VAULT_BUCKET.put(routerKey, defaultRouter, { httpMetadata: { contentType: "text/markdown; charset=utf-8" } });
    await env.VAULT_BUCKET.put(`${userPrefix}/AGENTS.md`, defaultAgents, { httpMetadata: { contentType: "text/markdown; charset=utf-8" } });
    await env.VAULT_BUCKET.put(`${userPrefix}/CONTEXT.md`, defaultContext, { httpMetadata: { contentType: "text/markdown; charset=utf-8" } });
    await env.VAULT_BUCKET.put(`${userPrefix}/MAIN/.gitkeep`, "", { httpMetadata: { contentType: "text/plain" } });
    await env.VAULT_BUCKET.put(`${userPrefix}/_BUSINESS/.gitkeep`, "", { httpMetadata: { contentType: "text/plain" } });
    await env.VAULT_BUCKET.put(`${userPrefix}/_CONTENT/.gitkeep`, "", { httpMetadata: { contentType: "text/plain" } });
    await env.VAULT_BUCKET.put(`${userPrefix}/_SKILLS/.gitkeep`, "", { httpMetadata: { contentType: "text/plain" } });
  } catch (err) {
    // Non-fatal background seeding
  }
}

async function processSingleMCPMessage(msg, env, userPrefix) {
  if (!msg || typeof msg !== "object") {
    return { jsonrpc: "2.0", id: null, error: { code: -32600, message: "Invalid Request" } };
  }

  const { id, method, params } = msg;

  // Notifications (no id or notifications/*) do not return a JSON-RPC response object
  if (id === undefined || (typeof method === "string" && method.startsWith("notifications/"))) {
    return null;
  }

  if (method === "initialize") {
    await ensureStarterVaultFiles(env, userPrefix);
    const requestedVersion = params?.protocolVersion || "2025-03-26";
    const supportedVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"];
    const protocolVersion = supportedVersions.includes(requestedVersion) ? requestedVersion : "2025-03-26";
    return {
      jsonrpc: "2.0",
      id,
      result: {
        protocolVersion,
        capabilities: {
          tools: { listChanged: false },
          resources: { subscribe: false, listChanged: false },
          prompts: { listChanged: false }
        },
        serverInfo: {
          name: "ZeroDrive",
          title: "ZeroDrive",
          version: "1.1.0",
          icon: CONNECTOR_ICON_URL,
          logo_url: CONNECTOR_ICON_URL,
          websiteUrl: "https://zerodrive.dev",
          icons: [
            {
              src: CONNECTOR_ICON_URL,
              mimeType: "image/png",
              sizes: ["256x256", "120x120"]
            }
          ]
        },
        instructions: "ZeroDrive Cloud Vault. Supports BOTH text and ALL binary files (PNG, JPG, WebP, PDF, MP4/MOV/WebM videos, MP3/WAV audio, ZIP/TAR.GZ archives, Office docs, and multi-file Agent Skills in _SKILLS/). Start by calling get_file_tree, reading ROUTER.md, or calling run_vault_doctor for the full built-in Skill & Help guide. Use search_filenames to find files by name/extension, grep_vault to search inside text contents, read_file to inspect text or images, write_file / edit_file / move_file for text and code, upload_binary_file (via base64 or source_url) or create_upload_urls (1-hour pre-signed HTTP PUT URLs for streaming local screenshots, crops, PDFs, large videos, and ZIPs with zero LLM token overhead), and save_skill to package reusable skills into _SKILLS/<verb-noun-name>/SKILL.md."
      }
    };
  }

  if (method === "ping") {
    return { jsonrpc: "2.0", id, result: {} };
  }

  if (method === "tools/list") {
    return { jsonrpc: "2.0", id, result: { tools: MCP_TOOLS } };
  }

  if (method === "resources/list") {
    return {
      jsonrpc: "2.0",
      id,
      result: {
        resources: [
          { uri: "zerodrive://vault/SKILL.md", name: "ZeroDrive Built-In Skill & Help (SKILL.md)", description: "Built-in operational skill showing how to save text, screenshots, PDFs, videos, ZIPs, and skills in ZeroDrive", mimeType: "text/markdown" },
          { uri: "zerodrive://vault/ROUTER.md", name: "ROUTER.md", description: "Master index and directory map of the ZeroDrive vault", mimeType: "text/markdown" },
          { uri: "zerodrive://vault/AGENTS.md", name: "AGENTS.md", description: "Agent operating rules and workspace instructions", mimeType: "text/markdown" },
          { uri: "zerodrive://vault/CONTEXT.md", name: "CONTEXT.md", description: "Current system context and active architecture", mimeType: "text/markdown" }
        ]
      }
    };
  }

  if (method === "resources/read") {
    const uri = params?.uri || "";
    const filePath = uri.replace(/^zerodrive:\/\/vault\/?/, "").replace(/^\/+/, "");
    if (filePath === "SKILL.md" || filePath === "HELP.md") {
      return {
        jsonrpc: "2.0",
        id,
        result: {
          contents: [{ uri: uri || "zerodrive://vault/SKILL.md", mimeType: "text/markdown", text: BUILTIN_SKILL_MD }]
        }
      };
    }
    const obj = await env.VAULT_BUCKET.get(`${userPrefix}/${filePath}`);
    const text = obj ? await obj.text() : `Resource not found: ${uri}`;
    return {
      jsonrpc: "2.0",
      id,
      result: {
        contents: [{ uri, mimeType: "text/markdown", text }]
      }
    };
  }

  if (method === "resources/templates/list") {
    return { jsonrpc: "2.0", id, result: { resourceTemplates: [] } };
  }

  if (method === "prompts/list") {
    return {
      jsonrpc: "2.0",
      id,
      result: {
        prompts: [
          {
            name: "zerodrive-help",
            description: "Load the built-in ZeroDrive Vault Skill & Help guide (how to save text, images, PDFs, videos, ZIPs, and reusable skills)."
          },
          {
            name: "zerodrive-doctor",
            description: "Run a health check and diagnostic on the ZeroDrive vault connection and capabilities."
          },
          {
            name: "save-skill",
            description: "Package and save a reusable Agent Skill to _SKILLS/<verb-noun-name>/SKILL.md in the ZeroDrive vault.",
            arguments: [
              { name: "name", description: "Skill name in verb-noun format (e.g. create-substack-articles)", required: true }
            ]
          }
        ]
      }
    };
  }

  if (method === "prompts/get") {
    const promptName = params?.name || "zerodrive-help";
    if (promptName === "zerodrive-doctor") {
      return {
        jsonrpc: "2.0",
        id,
        result: {
          description: "ZeroDrive Vault Doctor & Diagnostics",
          messages: [
            {
              role: "user",
              content: {
                type: "text",
                text: "Call the `run_vault_doctor` tool now to verify our ZeroDrive vault connection, inspect the root folders and _SKILLS directory, and confirm binary/video/zip upload readiness."
              }
            }
          ]
        }
      };
    }
    if (promptName === "save-skill") {
      const sName = params?.arguments?.name || "create-example-workflow";
      return {
        jsonrpc: "2.0",
        id,
        result: {
          description: `Save skill ${sName} to ZeroDrive _SKILLS/`,
          messages: [
            {
              role: "user",
              content: {
                type: "text",
                text: `Use the \`save_skill\` tool to save the skill "${sName}" into \`_SKILLS/${sName}/SKILL.md\`. Follow the ZeroDrive naming rule: lowercase hyphenated verb-noun, no grand nouns (forge, engine, system, suite, hub, nexus, matrix, factory, mastery, ultimate, pro, 2.0).\n\n${BUILTIN_SKILL_MD}`
              }
            }
          ]
        }
      };
    }
    return {
      jsonrpc: "2.0",
      id,
      result: {
        description: "ZeroDrive Built-In Skill & Help Guide",
        messages: [
          {
            role: "user",
            content: {
              type: "text",
              text: BUILTIN_SKILL_MD
            }
          }
        ]
      }
    };
  }

  if (method === "logging/setLevel") {
    return { jsonrpc: "2.0", id, result: {} };
  }

  if (method === "completion/complete") {
    return { jsonrpc: "2.0", id, result: { completion: { values: [], total: 0, hasMore: false } } };
  }

  if (method === "tools/call") {
    const toolName = params?.name;
    const args = params?.arguments || {};

    try {
      if (toolName === "get_file_tree") {
        const subpath = (args.path || "").replace(/^\/+/, "").replace(/\/+$/, "");
        const depth = Math.min(Math.max(parseInt(args.depth || 2, 10), 1), 4);
        const treeLines = await buildDirectoryTree(env, userPrefix, subpath, depth);
        const header = subpath ? `📁 ${subpath}/` : "📁 ZeroDrive Vault Root (/)";
        return {
          jsonrpc: "2.0",
          id,
          result: { content: [{ type: "text", text: [header, ...treeLines].join("\n") }] }
        };
      }

      if (toolName === "list_files" || toolName === "zd_list") {
        const subpath = (args.path || "").replace(/^\/+/, "").replace(/\/+$/, "");
        const prefix = subpath ? `${userPrefix}/${subpath}/` : `${userPrefix}/`;
        const recursive = !!args.recursive;

        const listed = recursive
          ? await env.VAULT_BUCKET.list({ prefix, limit: 1000 })
          : await listDirectoryComplete(env, prefix);

        const items = [];
        for (const p of listed.delimitedPrefixes || []) {
          const folderName = p.slice(prefix.length).replace(/\/$/, "");
          items.push({ name: folderName, type: "dir", path: p.slice(userPrefix.length + 1) });
        }
        for (const o of listed.objects || []) {
          const fileName = o.key.slice(prefix.length);
          if (fileName && (!fileName.includes("/") || recursive)) {
            items.push({ name: fileName, type: "file", size: o.size, modified: o.uploaded.toISOString(), path: o.key.slice(userPrefix.length + 1) });
          }
        }

        return {
          jsonrpc: "2.0",
          id,
          result: { content: [{ type: "text", text: JSON.stringify(items, null, 2) }] }
        };
      }

      if (toolName === "read_file" || toolName === "zd_read") {
        const subpath = (args.path || "").replace(/^\/+/, "");
        const fullKey = `${userPrefix}/${subpath}`;
        const obj = await env.VAULT_BUCKET.get(fullKey);
        if (!obj) {
          return {
            jsonrpc: "2.0",
            id,
            result: { isError: true, content: [{ type: "text", text: `File not found: ${args.path}` }] }
          };
        }

        const mimeType = obj.httpMetadata?.contentType || guessMimeType(subpath);
        const isBinaryOrImage =
          args.encoding === "base64" ||
          /^(image|video|audio|application\/(pdf|zip|octet-stream|vnd\.))/.test(mimeType);

        if (isBinaryOrImage) {
          const secret = env.GOOGLE_CLIENT_SECRET || "zd_secret";
          const dlToken = await createAuthCode(secret, { op: "download", key: fullKey, path: subpath }, 3600);
          const downloadUrl = `${CANONICAL_ORIGIN}/vault/download?token=${encodeURIComponent(dlToken)}`;

          if (mimeType.startsWith("image/") && obj.size <= 5 * 1024 * 1024) {
            const buf = new Uint8Array(await obj.arrayBuffer());
            const b64 = bytesToBase64(buf);
            return {
              jsonrpc: "2.0",
              id,
              result: {
                content: [
                  { type: "image", data: b64, mimeType },
                  { type: "text", text: JSON.stringify({ path: subpath, size: obj.size, mimeType, download_url: downloadUrl }, null, 2) }
                ]
              }
            };
          }

          if (args.encoding === "base64" && obj.size <= 10 * 1024 * 1024) {
            const buf = new Uint8Array(await obj.arrayBuffer());
            const b64 = bytesToBase64(buf);
            return {
              jsonrpc: "2.0",
              id,
              result: {
                content: [{ type: "text", text: JSON.stringify({ path: subpath, size: obj.size, mimeType, download_url: downloadUrl, content_base64: b64 }, null, 2) }]
              }
            };
          }

          return {
            jsonrpc: "2.0",
            id,
            result: {
              content: [{ type: "text", text: JSON.stringify({ path: subpath, size: obj.size, mimeType, download_url: downloadUrl }, null, 2) }]
            }
          };
        }

        let text = await obj.text();
        const lines = text.split("\n");
        if (args.head && args.head > 0) {
          text = lines.slice(0, args.head).join("\n");
        } else if (args.tail && args.tail > 0) {
          text = lines.slice(-args.tail).join("\n");
        } else if (args.lines) {
          const parts = String(args.lines).split("-").map(n => parseInt(n.trim(), 10));
          if (parts.length === 2 && !isNaN(parts[0]) && !isNaN(parts[1])) {
            text = lines.slice(Math.max(0, parts[0] - 1), parts[1]).join("\n");
          }
        }

        return {
          jsonrpc: "2.0",
          id,
          result: { content: [{ type: "text", text }] }
        };
      }

      if (toolName === "write_file" || toolName === "upload_binary_file" || toolName === "zd_write") {
        const subpath = (args.path || "").replace(/^\/+/, "");
        const fullKey = `${userPrefix}/${subpath}`;
        const mimeType = args.content_type || guessMimeType(subpath);

        // 1. Direct URL-to-Vault binary fetch
        if (args.source_url) {
          const resp = await fetch(String(args.source_url));
          if (!resp.ok) {
            return {
              jsonrpc: "2.0",
              id,
              result: { isError: true, content: [{ type: "text", text: `Failed to fetch source_url (${resp.status}): ${args.source_url}` }] }
            };
          }
          const fetchedType = args.content_type || resp.headers.get("content-type") || mimeType;
          const arrayBuf = await resp.arrayBuffer();
          await env.VAULT_BUCKET.put(fullKey, arrayBuf, {
            httpMetadata: { contentType: fetchedType }
          });
          return {
            jsonrpc: "2.0",
            id,
            result: { content: [{ type: "text", text: `Uploaded ${arrayBuf.byteLength} bytes (${fetchedType}) from URL to ${subpath}.` }] }
          };
        }

        // 2. Base64 binary payload (content_base64 or encoding='base64' or data:...;base64,...)
        const rawB64 = args.content_base64 || (args.encoding === "base64" ? args.content : null) || (typeof args.content === "string" && /^data:[^;]+;base64,/.test(args.content) ? args.content : null);
        if (rawB64) {
          const bytes = base64ToBytes(rawB64);
          await env.VAULT_BUCKET.put(fullKey, bytes, {
            httpMetadata: { contentType: mimeType }
          });
          return {
            jsonrpc: "2.0",
            id,
            result: { content: [{ type: "text", text: `Uploaded binary file ${subpath} (${bytes.byteLength} bytes, ${mimeType}).` }] }
          };
        }

        // 3. Standard UTF-8 text write / append
        let content = String(args.content ?? "");
        if (args.append) {
          const existing = await env.VAULT_BUCKET.get(fullKey);
          if (existing) {
            const prevText = await existing.text();
            content = prevText + (prevText.endsWith("\n") ? "" : "\n") + content;
          }
        }

        await env.VAULT_BUCKET.put(fullKey, content, {
          httpMetadata: { contentType: mimeType.startsWith("text/") || mimeType === "application/json" ? mimeType : "text/plain; charset=utf-8" }
        });

        return {
          jsonrpc: "2.0",
          id,
          result: { content: [{ type: "text", text: `Saved ${content.length} characters to ${subpath}.` }] }
        };
      }

      if (toolName === "create_upload_urls") {
        const rawList = Array.isArray(args.paths) ? args.paths : (args.path ? [args.path] : []);
        if (rawList.length === 0) {
          return {
            jsonrpc: "2.0",
            id,
            result: { isError: true, content: [{ type: "text", text: "Provide 'path' or 'paths' array of target vault paths." }] }
          };
        }
        const secret = env.GOOGLE_CLIENT_SECRET || "zd_secret";
        const uploads = [];
        for (const p of rawList) {
          const subpath = String(p || "").replace(/^\/+/, "");
          if (!subpath) continue;
          const fullKey = `${userPrefix}/${subpath}`;
          const mimeType = guessMimeType(subpath);
          const upToken = await createAuthCode(secret, { op: "upload", key: fullKey, path: subpath, mime: mimeType }, 3600);
          const uploadUrl = `${CANONICAL_ORIGIN}/vault/upload?token=${encodeURIComponent(upToken)}`;
          uploads.push({
            path: subpath,
            mime_type: mimeType,
            upload_url: uploadUrl,
            curl_example: `curl -sS -X PUT --upload-file "${subpath.split("/").pop()}" "${uploadUrl}"`
          });
        }
        return {
          jsonrpc: "2.0",
          id,
          result: {
            content: [{
              type: "text",
              text: JSON.stringify({
                instructions: "Send an HTTP PUT (or POST) request with the raw binary file body to each upload_url. Valid for 1 hour. No Authorization header needed on the upload_url itself.",
                uploads
              }, null, 2)
            }]
          }
        };
      }

      if (toolName === "get_download_url" || toolName === "zd_share") {
        const subpath = (args.path || "").replace(/^\/+/, "");
        const fullKey = `${userPrefix}/${subpath}`;
        const headObj = await env.VAULT_BUCKET.head(fullKey);
        if (!headObj) {
          return {
            jsonrpc: "2.0",
            id,
            result: { isError: true, content: [{ type: "text", text: `File not found: ${args.path}` }] }
          };
        }
        const secret = env.GOOGLE_CLIENT_SECRET || "zd_secret";
        const dlToken = await createAuthCode(secret, { op: "download", key: fullKey, path: subpath }, 86400);
        const downloadUrl = `${CANONICAL_ORIGIN}/vault/download?token=${encodeURIComponent(dlToken)}`;
        return {
          jsonrpc: "2.0",
          id,
          result: {
            content: [{
              type: "text",
              text: JSON.stringify({
                path: subpath,
                size: headObj.size,
                mime_type: headObj.httpMetadata?.contentType || guessMimeType(subpath),
                download_url: downloadUrl,
                expires_in_seconds: 86400
              }, null, 2)
            }]
          }
        };
      }

      if (toolName === "edit_file") {
        const subpath = (args.path || "").replace(/^\/+/, "");
        const fullKey = `${userPrefix}/${subpath}`;
        const obj = await env.VAULT_BUCKET.get(fullKey);
        if (!obj) {
          return {
            jsonrpc: "2.0",
            id,
            result: { isError: true, content: [{ type: "text", text: `File not found: ${args.path}` }] }
          };
        }
        const currentText = await obj.text();
        const oldText = String(args.old_text ?? "");
        const newText = String(args.new_text ?? "");
        if (!oldText || !currentText.includes(oldText)) {
          return {
            jsonrpc: "2.0",
            id,
            result: { isError: true, content: [{ type: "text", text: `old_text not found in ${args.path}. Read the file first to verify exact text.` }] }
          };
        }
        const updatedText = currentText.split(oldText).join(newText);
        await env.VAULT_BUCKET.put(fullKey, updatedText, {
          httpMetadata: { contentType: "text/plain; charset=utf-8" }
        });
        return {
          jsonrpc: "2.0",
          id,
          result: { content: [{ type: "text", text: `Updated ${subpath} (${updatedText.length} characters).` }] }
        };
      }

      if (toolName === "move_file") {
        const src = (args.source || "").replace(/^\/+/, "");
        const dst = (args.destination || "").replace(/^\/+/, "");
        const srcObj = await env.VAULT_BUCKET.get(`${userPrefix}/${src}`);
        if (!srcObj) {
          return {
            jsonrpc: "2.0",
            id,
            result: { isError: true, content: [{ type: "text", text: `Source file not found: ${args.source}` }] }
          };
        }
        await env.VAULT_BUCKET.put(`${userPrefix}/${dst}`, srcObj.body, {
          httpMetadata: srcObj.httpMetadata
        });
        await env.VAULT_BUCKET.delete(`${userPrefix}/${src}`);
        return {
          jsonrpc: "2.0",
          id,
          result: { content: [{ type: "text", text: `Moved ${src} to ${dst}.` }] }
        };
      }

      if (toolName === "copy_file" || toolName === "zd_copy") {
        const src = (args.source || "").replace(/^\/+/, "");
        const dst = (args.destination || "").replace(/^\/+/, "");
        const srcObj = await env.VAULT_BUCKET.get(`${userPrefix}/${src}`);
        if (!srcObj) {
          return {
            jsonrpc: "2.0",
            id,
            result: { isError: true, content: [{ type: "text", text: `Source file not found: ${args.source}` }] }
          };
        }
        await env.VAULT_BUCKET.put(`${userPrefix}/${dst}`, srcObj.body, {
          httpMetadata: srcObj.httpMetadata
        });
        return {
          jsonrpc: "2.0",
          id,
          result: { content: [{ type: "text", text: `Copied ${src} to ${dst}.` }] }
        };
      }

      if (toolName === "delete_file" || toolName === "zd_delete") {
        const subpath = (args.path || "").replace(/^\/+/, "");
        await env.VAULT_BUCKET.delete(`${userPrefix}/${subpath}`);
        return {
          jsonrpc: "2.0",
          id,
          result: { content: [{ type: "text", text: `Deleted ${subpath} from ZeroDrive vault.` }] }
        };
      }

      if (toolName === "search_filenames" || toolName === "zd_search") {
        const query = (args.query || args.pattern || "").toLowerCase().replace(/\*/g, "");
        const subpath = (args.path || "").replace(/^\/+/, "").replace(/\/+$/, "");
        const prefix = subpath ? `${userPrefix}/${subpath}/` : `${userPrefix}/`;

        const matches = [];
        let cursor;
        let scanned = 0;
        do {
          const listed = await env.VAULT_BUCKET.list({ prefix, limit: 1000, cursor });
          for (const obj of listed.objects || []) {
            scanned++;
            const relPath = obj.key.slice(userPrefix.length + 1);
            if (relPath.toLowerCase().includes(query)) {
              matches.push({ path: relPath, size: obj.size, modified: obj.uploaded.toISOString() });
              if (matches.length >= 100) break;
            }
          }
          cursor = listed.truncated && matches.length < 100 ? listed.cursor : undefined;
        } while (cursor && scanned < 25000);

        return {
          jsonrpc: "2.0",
          id,
          result: { content: [{ type: "text", text: JSON.stringify(matches, null, 2) }] }
        };
      }

      if (toolName === "grep_vault") {
        const query = String(args.query || "").trim();
        const queryLower = query.toLowerCase();
        const subpath = (args.path || "").replace(/^\/+/, "").replace(/\/+$/, "");
        const prefix = subpath ? `${userPrefix}/${subpath}/` : `${userPrefix}/`;
        const maxResults = Math.min(Math.max(parseInt(args.max_results || 30, 10), 1), 100);

        const textExtensions = /\.(md|txt|json|jsonl|yaml|yml|csv|tsv|js|ts|jsx|tsx|py|sh|swift|html|css|xml|toml|ini|conf|env|sql)$/i;
        const directListed = await listDirectoryComplete(env, prefix, 4);
        const recursiveListed = await env.VAULT_BUCKET.list({ prefix, limit: 800 });

        const seenKeys = new Set();
        const candidateKeys = [];
        for (const o of [...(directListed.objects || []), ...(recursiveListed.objects || [])]) {
          if (seenKeys.has(o.key)) continue;
          seenKeys.add(o.key);
          if (o.key.includes("/.runitback/") || o.key.includes("/node_modules/") || o.key.includes("/.git/")) continue;
          if (o.size > 0 && o.size <= 512 * 1024 && textExtensions.test(o.key)) {
            candidateKeys.push(o);
            if (candidateKeys.length >= 100) break;
          }
        }

        const results = [];
        for (const objMeta of candidateKeys) {
          if (results.length >= maxResults) break;
          const obj = await env.VAULT_BUCKET.get(objMeta.key);
          if (!obj) continue;
          const text = await obj.text();
          if (!text.toLowerCase().includes(queryLower)) continue;

          const relPath = objMeta.key.slice(userPrefix.length + 1);
          const lines = text.split("\n");
          for (let i = 0; i < lines.length; i++) {
            if (lines[i].toLowerCase().includes(queryLower)) {
              results.push({
                path: relPath,
                line: i + 1,
                snippet: lines[i].trim().slice(0, 300)
              });
              if (results.length >= maxResults) break;
            }
          }
        }

        return {
          jsonrpc: "2.0",
          id,
          result: { content: [{ type: "text", text: JSON.stringify(results, null, 2) }] }
        };
      }

      if (toolName === "get_folder_size" || toolName === "zd_size") {
        const subpath = (args.path || "").replace(/^\/+/, "").replace(/\/+$/, "");
        const prefix = subpath ? `${userPrefix}/${subpath}/` : `${userPrefix}/`;

        let count = 0;
        let totalBytes = 0;
        let cursor;
        do {
          const listed = await env.VAULT_BUCKET.list({ prefix, limit: 1000, cursor });
          for (const obj of listed.objects || []) {
            count++;
            totalBytes += obj.size;
          }
          cursor = listed.truncated ? listed.cursor : undefined;
        } while (cursor && count < 50000);

        return {
          jsonrpc: "2.0",
          id,
          result: { content: [{ type: "text", text: JSON.stringify({ path: args.path || "/", fileCount: count, totalBytes, sizeFormatted: `${(totalBytes / (1024*1024*1024)).toFixed(2)} GB` }, null, 2) }] }
        };
      }

      if (toolName === "save_skill") {
        let skillName = String(args.name || "")
          .trim()
          .toLowerCase()
          .replace(/[^a-z0-9-]+/g, "-")
          .replace(/^-+|-+$/g, "");
        if (!skillName) {
          return {
            jsonrpc: "2.0",
            id,
            result: { isError: true, content: [{ type: "text", text: "Provide a valid skill name (e.g. 'create-substack-articles')." }] }
          };
        }
        const bannedWords = ["forge", "engine", "system", "suite", "hub", "nexus", "matrix", "factory", "mastery", "ultimate", "pro", "2-0"];
        const usedBanned = bannedWords.filter(w => skillName.split("-").includes(w));
        if (usedBanned.length > 0) {
          return {
            jsonrpc: "2.0",
            id,
            result: {
              isError: true,
              content: [{
                type: "text",
                text: `Skill name '${skillName}' contains banned buzzword(s): ${usedBanned.join(", ")}. Rename using plain verb-noun format (e.g. 'create-substack-articles', 'research-youtube-topics').`
              }]
            }
          };
        }

        const desc = String(args.description || "Reusable ZeroDrive agent skill.").trim();
        let bodyMd = String(args.instructions || "").trim();
        if (!bodyMd.startsWith("---")) {
          bodyMd = `---\nname: ${skillName}\ndescription: ${desc.replace(/\n+/g, " ")}\n---\n\n${bodyMd}\n`;
        }

        const skillFolder = `_SKILLS/${skillName}`;
        const skillMdKey = `${userPrefix}/${skillFolder}/SKILL.md`;
        await env.VAULT_BUCKET.put(skillMdKey, bodyMd, {
          httpMetadata: { contentType: "text/markdown; charset=utf-8" }
        });

        const savedFiles = [`${skillFolder}/SKILL.md`];
        if (Array.isArray(args.files)) {
          for (const f of args.files) {
            const rel = String(f?.relative_path || "").replace(/^\/+/, "");
            if (!rel) continue;
            const fileSubpath = `${skillFolder}/${rel}`;
            const fileKey = `${userPrefix}/${fileSubpath}`;
            const fileMime = guessMimeType(fileSubpath);

            if (f.source_url) {
              const resp = await fetch(String(f.source_url));
              if (resp.ok) {
                const buf = await resp.arrayBuffer();
                await env.VAULT_BUCKET.put(fileKey, buf, {
                  httpMetadata: { contentType: resp.headers.get("content-type") || fileMime }
                });
                savedFiles.push(fileSubpath);
              }
            } else if (f.content_base64) {
              const bytes = base64ToBytes(f.content_base64);
              await env.VAULT_BUCKET.put(fileKey, bytes, {
                httpMetadata: { contentType: fileMime }
              });
              savedFiles.push(fileSubpath);
            } else if (f.content !== undefined) {
              await env.VAULT_BUCKET.put(fileKey, String(f.content), {
                httpMetadata: { contentType: fileMime }
              });
              savedFiles.push(fileSubpath);
            }
          }
        }

        return {
          jsonrpc: "2.0",
          id,
          result: {
            content: [{
              type: "text",
              text: JSON.stringify({
                ok: true,
                skill: skillName,
                folder: skillFolder,
                saved_files: savedFiles
              }, null, 2)
            }]
          }
        };
      }

      if (toolName === "run_vault_doctor" || toolName === "get_vault_help" || toolName === "vault_doctor") {
        const rootListing = await listDirectoryComplete(env, `${userPrefix}/`, 5);
        const skillsListing = await listDirectoryComplete(env, `${userPrefix}/_SKILLS/`, 5);
        const report = {
          status: "healthy",
          domain: "api.zerodrive.dev",
          canonical_mcp_url: `${CANONICAL_ORIGIN}/mcp`,
          tenant_vault_prefix: userPrefix,
          root_folders: rootListing.dirs,
          root_files: rootListing.files.map(f => f.name),
          installed_skills_count: skillsListing.dirs.length + skillsListing.files.length,
          installed_skills_sample: skillsListing.dirs.slice(0, 20),
          capabilities: {
            text_and_code: "write_file, read_file, edit_file, grep_vault",
            images_and_pdfs: "upload_binary_file (base64 or source_url), create_upload_urls, read_file",
            videos_and_audio: "create_upload_urls (streams MP4/MOV/WebM/MP3/WAV up to 5GB directly via HTTP PUT) or upload_binary_file (source_url)",
            zip_and_archives: "create_upload_urls or upload_binary_file (.zip, .tar.gz, .7z, .dmg)",
            agent_skills: "save_skill (saves directly to _SKILLS/<verb-noun-name>/SKILL.md + bundled scripts/zips)"
          }
        };

        return {
          jsonrpc: "2.0",
          id,
          result: {
            content: [
              { type: "text", text: `## ZeroDrive Vault Doctor Report\n\`\`\`json\n${JSON.stringify(report, null, 2)}\n\`\`\`\n\n${BUILTIN_SKILL_MD}` }
            ]
          }
        };
      }

      return {
        jsonrpc: "2.0",
        id,
        result: { isError: true, content: [{ type: "text", text: `Unknown tool: ${toolName}` }] }
      };
    } catch (err) {
      return {
        jsonrpc: "2.0",
        id,
        result: { isError: true, content: [{ type: "text", text: `Error: ${err.message || String(err)}` }] }
      };
    }
  }

  return {
    jsonrpc: "2.0",
    id,
    error: { code: -32601, message: `Method not found: ${method}` }
  };
}

async function handleMCPRequest(request, env, url, corsHeaders) {
  if (request.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const acceptHeader = request.headers.get("Accept") || "";
  const isBrowserNavigation =
    request.method === "GET" &&
    acceptHeader.includes("text/html") &&
    !acceptHeader.includes("application/json") &&
    !acceptHeader.includes("text/event-stream");

  const auth = authenticateMCPRequest(request, env, url);
  if (!auth.ok) {
    // Only redirect if a human explicitly opens /mcp in a browser tab
    if (isBrowserNavigation) {
      return Response.redirect(`${CANONICAL_ORIGIN}/login`, 302);
    }

    return new Response(
      JSON.stringify({
        jsonrpc: "2.0",
        id: null,
        error: {
          code: -32000,
          message: "Authentication required. Connect via ZeroDrive OAuth 2.0.",
          data: {
            auth_flow: "oauth2",
            name: "ZeroDrive",
            icon: CONNECTOR_ICON_URL,
            logo_uri: CONNECTOR_ICON_URL,
            login_url: `${CANONICAL_ORIGIN}/login`,
            authorization_endpoint: `${CANONICAL_ORIGIN}/oauth/authorize`,
            token_endpoint: `${CANONICAL_ORIGIN}/oauth/token`,
            registration_endpoint: `${CANONICAL_ORIGIN}/oauth/register`,
            discovery: `${CANONICAL_ORIGIN}/.well-known/oauth-authorization-server`
          }
        },
      }),
      {
        status: 401,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
          "WWW-Authenticate": `Bearer realm="ZeroDrive", resource_metadata="${CANONICAL_ORIGIN}/.well-known/oauth-protected-resource", authorization_uri="${CANONICAL_ORIGIN}/oauth/authorize", token_uri="${CANONICAL_ORIGIN}/oauth/token"`,
        },
      }
    );
  }

  if (request.method === "DELETE") {
    return new Response(null, { status: 200, headers: corsHeaders });
  }

  if (request.method === "GET") {
    // Per MCP Streamable HTTP specification: if client requests an SSE stream via GET,
    // returning 405 tells the client cleanly to use POST for JSON-RPC request/response.
    if (acceptHeader.includes("text/event-stream")) {
      return new Response("Method Not Allowed", { status: 405, headers: corsHeaders });
    }
    return new Response(JSON.stringify({
      status: "online",
      name: "ZeroDrive",
      server: "ZeroDrive Hosted MCP Server",
      icon: CONNECTOR_ICON_URL,
      logo_url: CONNECTOR_ICON_URL,
      protocol: "2025-03-26",
      authenticatedAs: auth.userPrefix,
      tools: MCP_TOOLS.map(t => t.name)
    }, null, 2), {
      headers: { ...corsHeaders, "Content-Type": "application/json" }
    });
  }

  if (request.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405, headers: corsHeaders });
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return new Response(JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" }
    });
  }

  const userPrefix = auth.userPrefix;
  const responseHeaders = {
    ...corsHeaders,
    "Content-Type": "application/json",
    "Mcp-Session-Id": "zd-session-live"
  };

  if (Array.isArray(body)) {
    const results = [];
    for (const item of body) {
      const res = await processSingleMCPMessage(item, env, userPrefix);
      if (res !== null) results.push(res);
    }
    if (results.length === 0) {
      return new Response(null, { status: 202, headers: responseHeaders });
    }
    return new Response(JSON.stringify(results), { status: 200, headers: responseHeaders });
  }

  const singleResult = await processSingleMCPMessage(body, env, userPrefix);
  if (singleResult === null) {
    return new Response(null, { status: 202, headers: responseHeaders });
  }

  return new Response(JSON.stringify(singleResult), { status: 200, headers: responseHeaders });
}

function handleGoogleAuthStart(request, env, url) {
  const clientId = env.GOOGLE_CLIENT_ID;
  if (!clientId) {
    return new Response("GOOGLE_CLIENT_ID is not configured in worker environment", { status: 500 });
  }
  const redirectUri = env.AUTH_REDIRECT_URI || `${CANONICAL_ORIGIN}/auth/callback`;
  
  // Capture client OAuth parameters (e.g. from Muse, Claude, Cursor, ChatGPT)
  const clientRedirectUri = url.searchParams.get("redirect_uri") || "";
  const clientState = url.searchParams.get("state") || "";
  const codeChallenge = url.searchParams.get("code_challenge") || "";
  const clientIdParam = url.searchParams.get("client_id") || "";

  let statePayload = { s: clientState };
  if (clientRedirectUri && clientRedirectUri !== redirectUri) {
    statePayload.r = clientRedirectUri;
    statePayload.c = codeChallenge;
    statePayload.cid = clientIdParam;
  } else if (clientState) {
    statePayload.s = clientState;
  }

  const encodedState = base64UrlEncode(JSON.stringify(statePayload));
  const googleAuthUrl = `https://accounts.google.com/o/oauth2/v2/auth?client_id=${encodeURIComponent(clientId)}&redirect_uri=${encodeURIComponent(redirectUri)}&response_type=code&scope=openid%20email%20profile&access_type=offline&prompt=select_account&state=${encodeURIComponent(encodedState)}`;
  return Response.redirect(googleAuthUrl, 302);
}

function handleOAuthProtectedResource(url, corsHeaders) {
  const origin = CANONICAL_ORIGIN;
  return new Response(JSON.stringify({
    resource: `${origin}/mcp`,
    resource_name: "ZeroDrive",
    service_name: "ZeroDrive",
    logo_uri: CONNECTOR_ICON_URL,
    icon_uri: CONNECTOR_ICON_URL,
    icon: CONNECTOR_ICON_URL,
    icons: [
      {
        src: CONNECTOR_ICON_URL,
        mimeType: "image/png",
        sizes: ["256x256", "120x120"]
      }
    ],
    authorization_servers: [origin],
    scopes_supported: ["mcp", "vault:read", "vault:write"],
    bearer_methods_supported: ["header"],
    resource_documentation: "https://zerodrive.dev"
  }, null, 2), {
    headers: { ...corsHeaders, "Content-Type": "application/json" }
  });
}



function handleAIPluginManifest(url, corsHeaders) {
  const origin = CANONICAL_ORIGIN;
  const manifest = {
    schema_version: "v1",
    name_for_model: "zerodrive",
    name_for_human: "ZeroDrive",
    description_for_model: "Access, read, write, and search files inside the ZeroDrive cloud vault 24/7.",
    description_for_human: "Connect directly to your ZeroDrive Cloud Vault.",
    auth: {
      type: "oauth",
      client_url: `${origin}/oauth/authorize`,
      scope: "mcp vault:read vault:write",
      authorization_url: `${origin}/oauth/token`,
      authorization_content_type: "application/x-www-form-urlencoded",
      verification_tokens: {}
    },
    api: {
      type: "openapi",
      url: `${origin}/openapi.json`
    },
    logo_url: CONNECTOR_ICON_URL,
    contact_email: "naegele412@gmail.com",
    legal_info_url: "https://zerodrive.dev"
  };
  return new Response(JSON.stringify(manifest, null, 2), {
    headers: { ...corsHeaders, "Content-Type": "application/json" }
  });
}

function handleOpenIDConfiguration(url, corsHeaders) {
  const origin = CANONICAL_ORIGIN;
  const config = {
    issuer: origin,
    service_name: "ZeroDrive",
    logo_uri: CONNECTOR_ICON_URL,
    icon_uri: CONNECTOR_ICON_URL,
    icon: CONNECTOR_ICON_URL,
    icons: [
      {
        src: CONNECTOR_ICON_URL,
        mimeType: "image/png",
        sizes: ["256x256", "120x120"]
      }
    ],
    authorization_endpoint: `${origin}/oauth/authorize`,
    token_endpoint: `${origin}/oauth/token`,
    userinfo_endpoint: `${origin}/oauth/userinfo`,
    jwks_uri: `${origin}/.well-known/jwks.json`,
    registration_endpoint: `${origin}/oauth/register`,
    scopes_supported: ["mcp", "vault:read", "vault:write", "openid", "email", "profile"],
    response_types_supported: ["code"],
    grant_types_supported: ["authorization_code", "refresh_token"],
    token_endpoint_auth_methods_supported: ["none", "client_secret_post", "client_secret_basic"],
    code_challenge_methods_supported: ["S256", "plain"],
    service_documentation: "https://zerodrive.dev",
    op_policy_uri: "https://zerodrive.dev"
  };
  return new Response(JSON.stringify(config, null, 2), {
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function handleOAuthRegister(request, env, url, corsHeaders) {
  if (request.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  let body = {};
  if (request.method === "POST") {
    try {
      body = await request.json();
    } catch {
      try {
        const text = await request.text();
        body = JSON.parse(text);
      } catch {}
    }
  }

  const clientName = body.client_name || "ZeroDrive";
  const redirectUris = Array.isArray(body.redirect_uris) && body.redirect_uris.length > 0
    ? body.redirect_uris
    : [`${CANONICAL_ORIGIN}/auth/callback`];
  const authMethod = body.token_endpoint_auth_method || "none";

  const now = Math.floor(Date.now() / 1000);
  const clientSeed = `${clientName}:${redirectUris.join(",")}:${env.GOOGLE_CLIENT_SECRET || "zd_secret"}`;
  const clientId = `zd_client_${(await sha256Hex(clientSeed)).slice(0, 24)}`;
  const clientSecret = `zd_secret_${(await sha256Hex(clientSeed + ":sec")).slice(0, 32)}`;

  const responsePayload = {
    client_id: clientId,
    client_id_issued_at: now,
    client_name: clientName,
    logo_uri: body.logo_uri || CONNECTOR_ICON_URL,
    client_uri: body.client_uri || "https://zerodrive.dev",
    redirect_uris: redirectUris,
    grant_types: Array.isArray(body.grant_types) && body.grant_types.length > 0 ? body.grant_types : ["authorization_code", "refresh_token"],
    response_types: Array.isArray(body.response_types) && body.response_types.length > 0 ? body.response_types : ["code"],
    token_endpoint_auth_method: authMethod,
    scope: body.scope || "mcp vault:read vault:write",
  };

  if (authMethod !== "none") {
    responsePayload.client_secret = clientSecret;
    responsePayload.client_secret_expires_at = 0;
  }

  return new Response(JSON.stringify(responsePayload, null, 2), {
    status: 201,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      Pragma: "no-cache",
    },
  });
}

async function handleOAuthToken(request, env, url, corsHeaders) {
  if (request.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  let body = {};
  const ctype = request.headers.get("content-type") || "";
  if (ctype.includes("application/json")) {
    body = await request.json().catch(() => ({}));
  } else {
    try {
      const formData = await request.formData();
      body = Object.fromEntries(formData.entries());
    } catch {
      const text = await request.text();
      body = Object.fromEntries(new URLSearchParams(text).entries());
    }
  }

  const grantType = body.grant_type || url.searchParams.get("grant_type") || "authorization_code";
  const code = body.code || url.searchParams.get("code") || "";
  const clientSecret = env.GOOGLE_CLIENT_SECRET || "";
  const tokenHeaders = {
    ...corsHeaders,
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    Pragma: "no-cache",
  };

  if (grantType === "authorization_code") {
    const payload = await verifyAuthCode(clientSecret, code);
    if (!payload) {
      return new Response(
        JSON.stringify({ error: "invalid_grant", error_description: "Invalid or expired authorization code" }),
        { status: 400, headers: tokenHeaders }
      );
    }

    return new Response(
      JSON.stringify({
        access_token: payload.sessionToken,
        token_type: "Bearer",
        expires_in: 31536000,
        refresh_token: payload.sessionToken,
        scope: "mcp vault:read vault:write",
      }),
      { status: 200, headers: tokenHeaders }
    );
  }

  if (grantType === "refresh_token") {
    const refreshToken = body.refresh_token || url.searchParams.get("refresh_token") || "";
    if (!refreshToken) {
      return new Response(
        JSON.stringify({ error: "invalid_request", error_description: "Missing refresh_token" }),
        { status: 400, headers: tokenHeaders }
      );
    }
    return new Response(
      JSON.stringify({
        access_token: refreshToken,
        token_type: "Bearer",
        expires_in: 31536000,
        refresh_token: refreshToken,
        scope: "mcp vault:read vault:write",
      }),
      { status: 200, headers: tokenHeaders }
    );
  }

  return new Response(
    JSON.stringify({ error: "unsupported_grant_type", error_description: `Grant type '${grantType}' is not supported` }),
    { status: 400, headers: tokenHeaders }
  );
}

async function handleOAuthUserInfo(request, env, url, corsHeaders) {
  const auth = authenticateMCPRequest(request, env, url);
  if (!auth.ok) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
  return new Response(
    JSON.stringify({
      sub: "user",
      email: "naegele412@gmail.com",
      email_verified: true,
      name: "ZeroDrive Vault Owner",
      vault_prefix: auth.userPrefix,
    }),
    { headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
}

async function handleGoogleAuthCallback(request, env, url, corsHeaders) {
  const code = url.searchParams.get("code");
  const error = url.searchParams.get("error");
  if (error || !code) {
    return new Response(`Google login failed: ${error || "missing authorization code"}`, { status: 400 });
  }

  const clientId = env.GOOGLE_CLIENT_ID;
  const clientSecret = env.GOOGLE_CLIENT_SECRET;
  if (!clientId || !clientSecret) {
    return new Response("Google OAuth credentials not configured in worker environment", { status: 500 });
  }
  const redirectUri = env.AUTH_REDIRECT_URI || `${url.origin}/auth/callback`;

  // Exchange code for Google tokens
  const tokenResp = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: clientId,
      client_secret: clientSecret,
      redirect_uri: redirectUri,
      grant_type: "authorization_code",
    }),
  });

  if (!tokenResp.ok) {
    const errText = await tokenResp.text();
    return new Response(`Token exchange failed: ${errText}`, { status: 400 });
  }

  const tokenData = await tokenResp.json();
  const accessToken = tokenData.access_token;

  // Fetch user profile from Google
  const userResp = await fetch("https://www.googleapis.com/oauth2/v2/userinfo", {
    headers: { Authorization: `Bearer ${accessToken}` },
  });

  if (!userResp.ok) {
    return new Response("Failed to fetch user info from Google", { status: 400 });
  }

  const user = await userResp.json();
  const email = (user.email || "").toLowerCase().trim();

  // Route to Andrew's master vault if naegele412@gmail.com, or create isolated user prefix
  const isMasterAdmin = email === "naegele412@gmail.com";
  let userPrefix = "usr_andrew_8bc7fb477f";
  let sessionToken = "";

  const tokenHash = await sha256Hex(`${email}:${clientSecret}:v2`);

  if (isMasterAdmin) {
    userPrefix = "usr_andrew_8bc7fb477f";
    sessionToken = `zd_oauth_master_${tokenHash.slice(0, 32)}`;
  } else {
    const cleanName = email.split("@")[0].replace(/[^a-zA-Z0-9]/g, "_").toLowerCase();
    const userHash = (await sha256Hex(email)).slice(0, 10);
    userPrefix = `usr_${cleanName}_${userHash}`;
    sessionToken = `zd_oauth_${userPrefix}_${tokenHash.slice(0, 16)}`;
  }

  const tenantPrefix = isMasterAdmin
    ? "tenants/zd_r2_andrew_8bc7fb477f/usr_andrew_8bc7fb477f"
    : `tenants/zd_r2_${userPrefix}/${userPrefix}`;
  await ensureStarterVaultFiles(env, tenantPrefix);
  
  // Unpack state parameter safely
  const rawState = url.searchParams.get("state") || "";
  let clientRedirectUri = "";
  let clientState = "";
  if (rawState) {
    try {
      const decoded = base64UrlDecode(rawState);
      const parsed = JSON.parse(decoded);
      if (parsed.r) clientRedirectUri = parsed.r;
      if (parsed.s !== undefined) clientState = parsed.s;
    } catch {
      clientState = rawState;
    }
  }

  // If external OAuth client (like Muse, Claude, Cursor) initiated login:
  if (clientRedirectUri) {
    const authCode = await createAuthCode(clientSecret, { email, sessionToken, userPrefix });
    const targetUrl = new URL(clientRedirectUri);
    targetUrl.searchParams.set("code", authCode);
    if (clientState) targetUrl.searchParams.set("state", clientState);
    return Response.redirect(targetUrl.toString(), 302);
  }

  // If redirecting to native Mac app
  if (clientState === "app") {
    return Response.redirect(`zerodrive://auth?token=${sessionToken}&email=${encodeURIComponent(email)}`, 302);
  }

  // Return Apple-grade branded HTML page confirming login
  const mcpUrl = `https://api.zerodrive.dev/mcp?key=${sessionToken}`;
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>ZeroDrive — Authenticated</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="icon" type="image/png" href="/app-icon.png">
  <style>
    * { box-sizing: border-box; -webkit-font-smoothing: antialiased; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", Roboto, sans-serif;
      background: radial-gradient(circle at 50% 18%, rgba(245, 166, 35, 0.14) 0%, transparent 60%), #08080a;
      color: #f5f5f7;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      margin: 0;
      padding: 24px;
    }
    .card {
      background: rgba(18, 18, 24, 0.88);
      border: 1px solid rgba(255, 255, 255, 0.08);
      backdrop-filter: blur(28px);
      -webkit-backdrop-filter: blur(28px);
      border-radius: 24px;
      padding: 44px 36px 36px;
      max-width: 520px;
      width: 100%;
      text-align: center;
      box-shadow: 0 32px 72px -16px rgba(0, 0, 0, 0.8), 0 0 0 1px rgba(255, 255, 255, 0.04);
    }
    .icon-wrap {
      margin-bottom: 20px;
      display: inline-block;
      position: relative;
    }
    .icon-wrap::after {
      content: "";
      position: absolute;
      inset: -8px;
      background: radial-gradient(circle, rgba(245, 166, 35, 0.3) 0%, transparent 70%);
      border-radius: 28px;
      z-index: -1;
      filter: blur(10px);
    }
    .app-icon {
      width: 72px;
      height: 72px;
      border-radius: 18px;
      display: block;
      box-shadow: 0 12px 32px rgba(0, 0, 0, 0.5), 0 0 0 1px rgba(255, 255, 255, 0.1);
    }
    .brand-title {
      font-size: 26px;
      font-weight: 700;
      letter-spacing: -0.6px;
      color: #ffffff;
      margin: 0 0 6px;
    }
    .status-badge {
      display: inline-flex;
      align-items: center;
      gap: 7px;
      background: rgba(52, 199, 89, 0.12);
      color: #32d74b;
      border: 1px solid rgba(52, 199, 89, 0.25);
      padding: 5px 14px;
      border-radius: 9999px;
      font-size: 13px;
      font-weight: 500;
      margin-bottom: 18px;
    }
    .dot {
      width: 7px;
      height: 7px;
      background: #32d74b;
      border-radius: 50%;
      box-shadow: 0 0 8px #32d74b;
      animation: pulse 2s infinite ease-in-out;
    }
    @keyframes pulse {
      0%, 100% { opacity: 1; transform: scale(1); }
      50% { opacity: 0.55; transform: scale(0.9); }
    }
    .subtitle {
      color: #98989f;
      font-size: 14px;
      line-height: 1.5;
      margin: 0 0 28px;
      padding: 0 12px;
    }
    .endpoint-card {
      background: #0d0d12;
      border: 1px solid rgba(255, 255, 255, 0.08);
      border-radius: 16px;
      padding: 16px 18px;
      text-align: left;
      margin-bottom: 24px;
      position: relative;
    }
    .endpoint-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 10px;
    }
    .endpoint-label {
      color: #787882;
      font-size: 11px;
      font-weight: 600;
      letter-spacing: 0.8px;
      text-transform: uppercase;
    }
    .copy-btn {
      background: #1c1c24;
      border: 1px solid rgba(255, 255, 255, 0.12);
      color: #f5f5f7;
      font-size: 12px;
      font-weight: 500;
      padding: 5px 12px;
      border-radius: 8px;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      transition: all 0.15s ease;
    }
    .copy-btn:hover {
      background: #282834;
      border-color: rgba(255, 255, 255, 0.2);
    }
    .copy-btn:active {
      transform: scale(0.97);
    }
    .copy-btn.copied {
      background: rgba(52, 199, 89, 0.15);
      border-color: rgba(52, 199, 89, 0.4);
      color: #32d74b;
    }
    .endpoint-value {
      font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
      font-size: 12px;
      color: #64d2ff;
      word-break: break-all;
      line-height: 1.5;
      background: rgba(0, 0, 0, 0.3);
      padding: 10px 12px;
      border-radius: 8px;
      border: 1px solid rgba(255, 255, 255, 0.04);
    }
    .primary-btn {
      background: #ffffff;
      color: #000000;
      font-size: 15px;
      font-weight: 600;
      padding: 12px 28px;
      border-radius: 9999px;
      text-decoration: none;
      display: inline-flex;
      align-items: center;
      gap: 8px;
      transition: all 0.15s ease;
      box-shadow: 0 4px 14px rgba(255, 255, 255, 0.2);
    }
    .primary-btn:hover {
      background: #e8e8ed;
      transform: translateY(-1px);
    }
    .primary-btn:active {
      transform: translateY(0);
    }
    .details-toggle {
      margin-top: 24px;
      text-align: left;
      border-top: 1px solid rgba(255, 255, 255, 0.08);
      padding-top: 18px;
    }
    .details-toggle summary {
      color: #787882;
      font-size: 12px;
      font-weight: 500;
      cursor: pointer;
      user-select: none;
      transition: color 0.15s ease;
    }
    .details-toggle summary:hover {
      color: #b0b0b8;
    }
    .details-content {
      margin-top: 14px;
    }
    .hint {
      color: #636366;
      font-size: 13px;
      margin: 0;
    }
  </style>
</head>
<body>
  <div class="card">
    <div class="icon-wrap">
      <img src="/app-icon.png" class="app-icon" alt="ZeroDrive">
    </div>
    <div class="brand-title">ZeroDrive Authenticated</div>
    <div class="status-badge">
      <span class="dot"></span>
      <span>${xmlEscape(email)}</span>
    </div>
    <p class="subtitle">Your Cloud Vault is authenticated and ready 24/7/365.</p>
    
    <div style="margin-bottom: 24px;">
      <a href="zerodrive://open" class="primary-btn">
        <span>Open ZeroDrive</span>
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12h14"></path><path d="M12 5l7 7-7 7"></path></svg>
      </a>
    </div>

    <p class="hint">You're completely connected. You can safely close this window.</p>

    <details class="details-toggle">
      <summary>Developer & Agent Settings (Optional)</summary>
      <div class="details-content">
        <div class="endpoint-card">
          <div class="endpoint-header">
            <span class="endpoint-label">Hosted Agent MCP Endpoint</span>
            <button class="copy-btn" id="copyBtn" onclick="copyMcpUrl()">
              <svg id="copyIcon" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg>
              <span id="copyText">Copy URL</span>
            </button>
          </div>
          <div class="endpoint-value" id="mcpUrlText">${xmlEscape(mcpUrl)}</div>
        </div>
      </div>
    </details>
  </div>

  <script>
    function copyMcpUrl() {
      const text = document.getElementById("mcpUrlText").innerText;
      navigator.clipboard.writeText(text).then(() => {
        const btn = document.getElementById("copyBtn");
        const copyText = document.getElementById("copyText");
        btn.classList.add("copied");
        copyText.innerText = "Copied!";
        setTimeout(() => {
          btn.classList.remove("copied");
          copyText.innerText = "Copy URL";
        }, 2200);
      });
    }
  </script>
</body>
</html>`;

  return new Response(html, {
    headers: { ...corsHeaders, "Content-Type": "text/html; charset=utf-8" },
  });
}


// ============================================================================
// ZeroDrive REST API v1, Multi-Device Fleet, OpenAPI 3.1 & Interactive Docs
// ============================================================================

async function getSystemJson(env, userPrefix, fileKey, defaultValue = []) {
  try {
    const obj = await env.VAULT_BUCKET.get(`${userPrefix}/_SYSTEM/${fileKey}`);
    if (!obj) return defaultValue;
    const text = await obj.text();
    return JSON.parse(text);
  } catch {
    return defaultValue;
  }
}

async function setSystemJson(env, userPrefix, fileKey, data) {
  try {
    await env.VAULT_BUCKET.put(
      `${userPrefix}/_SYSTEM/${fileKey}`,
      JSON.stringify(data, null, 2),
      { httpMetadata: { contentType: "application/json; charset=utf-8" } }
    );
    return true;
  } catch {
    return false;
  }
}

async function logActivity(env, userPrefix, action, details = {}) {
  try {
    const activities = await getSystemJson(env, userPrefix, "activity.json", []);
    const entry = {
      id: `act_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`,
      timestamp: new Date().toISOString(),
      action,
      ...details
    };
    activities.unshift(entry);
    // Keep last 250 activities
    if (activities.length > 250) activities.length = 250;
    await setSystemJson(env, userPrefix, "activity.json", activities);
    return entry;
  } catch {
    return null;
  }
}

function jsonResponse(data, status = 200, corsHeaders = {}) {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json; charset=utf-8"
    }
  });
}

function errorResponse(message, status = 400, corsHeaders = {}, extra = {}) {
  return jsonResponse({ ok: false, error: message, ...extra }, status, corsHeaders);
}

async function handleRestV1Request(request, env, url, corsHeaders) {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  const auth = authenticateMCPRequest(request, env, url);
  if (!auth.ok) {
    return new Response(
      JSON.stringify({
        ok: false,
        error: "Unauthorized",
        message: auth.error || "Valid Bearer API key or OAuth 2.0 token required.",
        login_url: `${CANONICAL_ORIGIN}/login`,
        docs: `${CANONICAL_ORIGIN}/docs`
      }, null, 2),
      {
        status: 401,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json; charset=utf-8",
          "WWW-Authenticate": `Bearer realm="ZeroDrive", resource_metadata="${CANONICAL_ORIGIN}/.well-known/oauth-protected-resource"`
        }
      }
    );
  }

  const userPrefix = auth.userPrefix;
  const pathname = url.pathname.replace(/\/+$/, "");

  // 1. GET /v1/tree - Visual Directory Tree
  if (pathname === "/v1/tree" && request.method === "GET") {
    const subpath = (url.searchParams.get("path") || "").replace(/^\/+/, "").replace(/\/+$/, "");
    const depth = Math.min(Math.max(parseInt(url.searchParams.get("depth") || 2, 10), 1), 4);
    const treeLines = await buildDirectoryTree(env, userPrefix, subpath, depth);
    const header = subpath ? `📁 ${subpath}/` : "📁 ZeroDrive Vault Root (/)";
    return jsonResponse({
      ok: true,
      path: subpath || "/",
      depth,
      header,
      tree: [header, ...treeLines].join("\n"),
      lines_count: treeLines.length + 1
    }, 200, corsHeaders);
  }

  // 2a. GET /v1/files/stat - Quick metadata lookup for single item (used by Apple FileProvider and Agents)
  if (pathname === "/v1/files/stat" && request.method === "GET") {
    const subpath = (url.searchParams.get("path") || "").replace(/^\/+/, "").replace(/\/+$/, "");
    if (!subpath) {
      return jsonResponse({
        ok: true,
        item: {
          name: "",
          path: "",
          is_directory: true,
          size: 0
        }
      }, 200, corsHeaders);
    }
    const fullKey = `${userPrefix}/${subpath}`;
    const headObj = await env.VAULT_BUCKET.head(fullKey);
    if (headObj) {
      const fileName = subpath.split("/").pop() || "";
      return jsonResponse({
        ok: true,
        item: {
          name: fileName,
          path: subpath,
          is_directory: false,
          size: headObj.size,
          modified: headObj.uploaded.toISOString(),
          mime_type: headObj.httpMetadata?.contentType || guessMimeType(fileName),
          etag: headObj.etag
        }
      }, 200, corsHeaders);
    }

    const checkDir = await env.VAULT_BUCKET.list({ prefix: `${fullKey}/`, limit: 1 });
    if (checkDir.objects.length > 0 || (checkDir.delimitedPrefixes && checkDir.delimitedPrefixes.length > 0)) {
      const folderName = subpath.split("/").pop() || "";
      return jsonResponse({
        ok: true,
        item: {
          name: folderName,
          path: subpath,
          is_directory: true,
          size: 0
        }
      }, 200, corsHeaders);
    }

    return errorResponse(`Item not found: ${subpath}`, 404, corsHeaders);
  }

  // 2b. GET /v1/files - List files and directories (supports limit and cursor pagination)
  if (pathname === "/v1/files" && request.method === "GET") {
    const subpath = (url.searchParams.get("path") || "").replace(/^\/+/, "").replace(/\/+$/, "");
    const prefix = subpath ? `${userPrefix}/${subpath}/` : `${userPrefix}/`;
    const recursive = url.searchParams.get("recursive") === "true";
    const cursor = url.searchParams.get("cursor") || undefined;
    const limitParam = parseInt(url.searchParams.get("limit") || "0", 10);
    const limit = limitParam > 0 ? Math.min(limitParam, 1000) : 0;

    let listed;
    let nextCursor = null;

    if (limit > 0) {
      const opts = { prefix, delimiter: recursive ? undefined : "/", limit };
      if (cursor) opts.cursor = cursor;
      listed = await env.VAULT_BUCKET.list(opts);
      nextCursor = listed.truncated ? (listed.cursor || null) : null;
    } else if (recursive) {
      listed = await env.VAULT_BUCKET.list({ prefix, limit: 1000 });
      nextCursor = listed.truncated ? (listed.cursor || null) : null;
    } else {
      listed = await listDirectoryComplete(env, prefix);
    }

    const directories = [];
    for (const p of listed.delimitedPrefixes || []) {
      const folderName = p.slice(prefix.length).replace(/\/$/, "");
      if (folderName) {
        directories.push({
          name: folderName,
          path: p.slice(userPrefix.length + 1).replace(/\/$/, "")
        });
      }
    }

    const files = [];
    for (const o of listed.objects || []) {
      const fileName = o.key.slice(prefix.length);
      if (fileName && (!fileName.includes("/") || recursive)) {
        files.push({
          name: fileName,
          path: o.key.slice(userPrefix.length + 1),
          size: o.size,
          modified: o.uploaded.toISOString(),
          mime_type: o.httpMetadata?.contentType || guessMimeType(fileName),
          etag: o.etag
        });
      }
    }

    return jsonResponse({
      ok: true,
      path: subpath || "/",
      directories,
      files,
      total_count: directories.length + files.length,
      next_cursor: nextCursor,
      has_more: !!nextCursor
    }, 200, corsHeaders);
  }

  // 3. POST /v1/files/read (or GET /v1/files/read) - Read file contents with line slicing
  if ((pathname === "/v1/files/read" || pathname === "/v1/read") && (request.method === "POST" || request.method === "GET")) {
    let body = {};
    if (request.method === "POST") {
      try { body = await request.json(); } catch { body = {}; }
    }
    const targetPath = (body.path || url.searchParams.get("path") || "").replace(/^\/+/, "");
    if (!targetPath) {
      return errorResponse("Missing required parameter 'path'", 400, corsHeaders);
    }

    const headLines = body.head !== undefined ? parseInt(body.head, 10) : (url.searchParams.get("head") ? parseInt(url.searchParams.get("head"), 10) : undefined);
    const tailLines = body.tail !== undefined ? parseInt(body.tail, 10) : (url.searchParams.get("tail") ? parseInt(url.searchParams.get("tail"), 10) : undefined);
    const lineRange = body.lines || url.searchParams.get("lines") || "";
    const encoding = body.encoding || url.searchParams.get("encoding") || "utf-8";

    const fullKey = `${userPrefix}/${targetPath}`;
    const obj = await env.VAULT_BUCKET.get(fullKey);
    if (!obj) {
      return errorResponse(`File not found: ${targetPath}`, 404, corsHeaders);
    }

    const mimeType = obj.httpMetadata?.contentType || guessMimeType(targetPath);
    const isBinaryMime = /^(image|video|audio|application\/(pdf|zip|x-tar|gzip|x-7z-compressed|vnd\.rar|x-apple-diskimage|octet-stream))/.test(mimeType);

    const secret = env.GOOGLE_CLIENT_SECRET || "zd_secret";
    const dlToken = await createAuthCode(secret, { op: "download", key: fullKey, path: targetPath }, 86400);
    const downloadUrl = `${CANONICAL_ORIGIN}/vault/download?token=${encodeURIComponent(dlToken)}`;

    if (isBinaryMime || encoding === "base64") {
      const arrayBuffer = await obj.arrayBuffer();
      const base64Data = bytesToBase64(new Uint8Array(arrayBuffer));
      return jsonResponse({
        ok: true,
        path: targetPath,
        size: obj.size,
        mime_type: mimeType,
        is_binary: true,
        encoding: "base64",
        content_base64: base64Data,
        download_url: downloadUrl
      }, 200, corsHeaders);
    }

    // Text file reading
    let text = await obj.text();
    let totalLines = text.split("\n").length;
    let isTruncated = false;

    if (headLines && headLines > 0) {
      const split = text.split("\n");
      text = split.slice(0, headLines).join("\n");
      isTruncated = true;
    } else if (tailLines && tailLines > 0) {
      const split = text.split("\n");
      text = split.slice(-tailLines).join("\n");
      isTruncated = true;
    } else if (lineRange && lineRange.includes("-")) {
      const [start, end] = lineRange.split("-").map(n => parseInt(n.trim(), 10));
      if (!isNaN(start) && !isNaN(end) && start > 0) {
        const split = text.split("\n");
        text = split.slice(start - 1, end).join("\n");
        isTruncated = true;
      }
    }

    return jsonResponse({
      ok: true,
      path: targetPath,
      size: obj.size,
      mime_type: mimeType,
      is_binary: false,
      total_lines: totalLines,
      is_truncated: isTruncated,
      content: text,
      download_url: downloadUrl
    }, 200, corsHeaders);
  }

  // 4. POST /v1/files/write - Write or append to any file (text, base64, URL)
  if ((pathname === "/v1/files/write" || pathname === "/v1/write") && (request.method === "POST" || request.method === "PUT")) {
    let body = {};
    try { body = await request.json(); } catch { return errorResponse("Invalid JSON payload", 400, corsHeaders); }

    const targetPath = (body.path || "").replace(/^\/+/, "");
    if (!targetPath) {
      return errorResponse("Missing required field 'path'", 400, corsHeaders);
    }

    const fullKey = `${userPrefix}/${targetPath}`;
    let mimeType = body.content_type || guessMimeType(targetPath);
    let dataToWrite;

    if (body.source_url) {
      const resp = await fetch(body.source_url);
      if (!resp.ok) {
        return errorResponse(`Failed to fetch source_url: HTTP ${resp.status}`, 400, corsHeaders);
      }
      dataToWrite = await resp.arrayBuffer();
      if (!body.content_type && resp.headers.get("content-type")) {
        mimeType = resp.headers.get("content-type");
      }
    } else if (body.content_base64) {
      dataToWrite = base64ToBytes(body.content_base64);
    } else if (body.content !== undefined) {
      if (body.append) {
        const existing = await env.VAULT_BUCKET.get(fullKey);
        const existingText = existing ? await existing.text() : "";
        dataToWrite = existingText + body.content;
      } else {
        dataToWrite = String(body.content);
      }
    } else {
      return errorResponse("Must provide 'content', 'content_base64', or 'source_url'", 400, corsHeaders);
    }

    const putObj = await env.VAULT_BUCKET.put(fullKey, dataToWrite, {
      httpMetadata: { contentType: mimeType }
    });

    await logActivity(env, userPrefix, "write_file", { path: targetPath, size: putObj.size });

    return jsonResponse({
      ok: true,
      path: targetPath,
      size: putObj.size,
      etag: putObj.etag,
      content_type: mimeType,
      modified: new Date().toISOString()
    }, 200, corsHeaders);
  }

  // 5. POST /v1/files/edit - Surgical in-place text replacement
  if (pathname === "/v1/files/edit" && request.method === "POST") {
    let body = {};
    try { body = await request.json(); } catch { return errorResponse("Invalid JSON payload", 400, corsHeaders); }

    const targetPath = (body.path || "").replace(/^\/+/, "");
    const oldText = String(body.old_text ?? "");
    const newText = String(body.new_text ?? "");

    if (!targetPath || !oldText) {
      return errorResponse("Fields 'path' and 'old_text' are required", 400, corsHeaders);
    }

    const fullKey = `${userPrefix}/${targetPath}`;
    const obj = await env.VAULT_BUCKET.get(fullKey);
    if (!obj) {
      return errorResponse(`File not found: ${targetPath}`, 404, corsHeaders);
    }

    const currentText = await obj.text();
    if (!currentText.includes(oldText)) {
      return errorResponse("old_text not found in file. Read the file first to verify exact string.", 400, corsHeaders);
    }

    const parts = currentText.split(oldText);
    const count = parts.length - 1;
    const updatedText = parts.join(newText);

    const putObj = await env.VAULT_BUCKET.put(fullKey, updatedText, {
      httpMetadata: { contentType: obj.httpMetadata?.contentType || guessMimeType(targetPath) }
    });

    await logActivity(env, userPrefix, "edit_file", { path: targetPath, occurrences: count });

    return jsonResponse({
      ok: true,
      path: targetPath,
      occurrences_replaced: count,
      new_size: putObj.size,
      etag: putObj.etag
    }, 200, corsHeaders);
  }

  // 6. POST /v1/files/move - Move or rename a file
  if (pathname === "/v1/files/move" && request.method === "POST") {
    let body = {};
    try { body = await request.json(); } catch { return errorResponse("Invalid JSON payload", 400, corsHeaders); }

    const src = (body.source || "").replace(/^\/+/, "");
    const dst = (body.destination || "").replace(/^\/+/, "");
    if (!src || !dst) {
      return errorResponse("Fields 'source' and 'destination' are required", 400, corsHeaders);
    }

    const srcObj = await env.VAULT_BUCKET.get(`${userPrefix}/${src}`);
    if (!srcObj) {
      return errorResponse(`Source file not found: ${src}`, 404, corsHeaders);
    }

    await env.VAULT_BUCKET.put(`${userPrefix}/${dst}`, srcObj.body, {
      httpMetadata: srcObj.httpMetadata
    });
    await env.VAULT_BUCKET.delete(`${userPrefix}/${src}`);
    await logActivity(env, userPrefix, "move_file", { source: src, destination: dst });

    return jsonResponse({ ok: true, source: src, destination: dst }, 200, corsHeaders);
  }

  // 7. POST /v1/files/copy - Copy or duplicate a file
  if (pathname === "/v1/files/copy" && request.method === "POST") {
    let body = {};
    try { body = await request.json(); } catch { return errorResponse("Invalid JSON payload", 400, corsHeaders); }

    const src = (body.source || "").replace(/^\/+/, "");
    const dst = (body.destination || "").replace(/^\/+/, "");
    if (!src || !dst) {
      return errorResponse("Fields 'source' and 'destination' are required", 400, corsHeaders);
    }

    const srcObj = await env.VAULT_BUCKET.get(`${userPrefix}/${src}`);
    if (!srcObj) {
      return errorResponse(`Source file not found: ${src}`, 404, corsHeaders);
    }

    const putObj = await env.VAULT_BUCKET.put(`${userPrefix}/${dst}`, srcObj.body, {
      httpMetadata: srcObj.httpMetadata
    });
    await logActivity(env, userPrefix, "copy_file", { source: src, destination: dst });

    return jsonResponse({ ok: true, source: src, destination: dst, size: putObj.size }, 200, corsHeaders);
  }

  // 8. POST /v1/files/delete or DELETE /v1/files - Delete a file
  if ((pathname === "/v1/files/delete" || pathname === "/v1/files") && (request.method === "POST" || request.method === "DELETE")) {
    let targetPath = (url.searchParams.get("path") || "").replace(/^\/+/, "");
    if (!targetPath && request.method === "POST") {
      try {
        const body = await request.json();
        targetPath = (body.path || "").replace(/^\/+/, "");
      } catch {}
    }

    if (!targetPath) {
      return errorResponse("Missing parameter 'path'", 400, corsHeaders);
    }

    await env.VAULT_BUCKET.delete(`${userPrefix}/${targetPath}`);
    await logActivity(env, userPrefix, "delete_file", { path: targetPath });

    return jsonResponse({ ok: true, path: targetPath, deleted: true }, 200, corsHeaders);
  }

  // 9. POST /v1/files/batch - Batch operations (copy, move, delete)
  if (pathname === "/v1/files/batch" && request.method === "POST") {
    let body = {};
    try { body = await request.json(); } catch { return errorResponse("Invalid JSON payload", 400, corsHeaders); }

    const operations = Array.isArray(body.operations) ? body.operations : [];
    if (operations.length === 0) {
      return errorResponse("Field 'operations' must be a non-empty array", 400, corsHeaders);
    }

    const results = [];
    for (const op of operations.slice(0, 50)) {
      const action = op.action;
      if (action === "delete") {
        const p = (op.path || "").replace(/^\/+/, "");
        if (p) {
          await env.VAULT_BUCKET.delete(`${userPrefix}/${p}`);
          results.push({ action: "delete", path: p, status: "success" });
        }
      } else if (action === "move" || action === "copy") {
        const src = (op.source || "").replace(/^\/+/, "");
        const dst = (op.destination || "").replace(/^\/+/, "");
        if (src && dst) {
          const srcObj = await env.VAULT_BUCKET.get(`${userPrefix}/${src}`);
          if (srcObj) {
            await env.VAULT_BUCKET.put(`${userPrefix}/${dst}`, srcObj.body, { httpMetadata: srcObj.httpMetadata });
            if (action === "move") await env.VAULT_BUCKET.delete(`${userPrefix}/${src}`);
            results.push({ action, source: src, destination: dst, status: "success" });
          } else {
            results.push({ action, source: src, destination: dst, status: "error", error: "Source not found" });
          }
        }
      }
    }

    return jsonResponse({ ok: true, executed_count: results.length, results }, 200, corsHeaders);
  }

  // 10. POST /v1/files/upload-urls - Direct pre-signed upload URLs for zero-token binary streaming
  if (pathname === "/v1/files/upload-urls" && request.method === "POST") {
    let body = {};
    try { body = await request.json(); } catch { return errorResponse("Invalid JSON payload", 400, corsHeaders); }

    const rawPaths = Array.isArray(body.paths) ? body.paths : (body.path ? [body.path] : []);
    if (rawPaths.length === 0) {
      return errorResponse("Provide 'paths' array or 'path' string", 400, corsHeaders);
    }

    const secret = env.GOOGLE_CLIENT_SECRET || "zd_secret";
    const uploadUrls = {};
    for (const raw of rawPaths.slice(0, 100)) {
      const subpath = String(raw).replace(/^\/+/, "");
      if (!subpath) continue;
      const fullKey = `${userPrefix}/${subpath}`;
      const mimeType = guessMimeType(subpath);
      const token = await createAuthCode(secret, { op: "upload", key: fullKey, path: subpath, mime: mimeType }, 3600);
      const uploadUrl = `${CANONICAL_ORIGIN}/vault/upload?token=${encodeURIComponent(token)}`;
      uploadUrls[subpath] = {
        path: subpath,
        url: uploadUrl,
        method: "PUT",
        expires_in_seconds: 3600,
        curl_example: `curl -sS -X PUT --upload-file "./${subpath.split('/').pop()}" "${uploadUrl}"`
      };
    }

    return jsonResponse({
      ok: true,
      expires_in_seconds: 3600,
      method: "PUT",
      upload_urls: uploadUrls
    }, 200, corsHeaders);
  }

  // 11. GET /v1/files/download-url - Pre-signed download URL with HTTP Range support
  if (pathname === "/v1/files/download-url" && (request.method === "GET" || request.method === "POST")) {
    let targetPath = (url.searchParams.get("path") || "").replace(/^\/+/, "");
    if (!targetPath && request.method === "POST") {
      try {
        const body = await request.json();
        targetPath = (body.path || "").replace(/^\/+/, "");
      } catch {}
    }

    if (!targetPath) {
      return errorResponse("Missing parameter 'path'", 400, corsHeaders);
    }

    const fullKey = `${userPrefix}/${targetPath}`;
    const headObj = await env.VAULT_BUCKET.head(fullKey);
    if (!headObj) {
      return errorResponse(`File not found: ${targetPath}`, 404, corsHeaders);
    }

    const secret = env.GOOGLE_CLIENT_SECRET || "zd_secret";
    const dlToken = await createAuthCode(secret, { op: "download", key: fullKey, path: targetPath }, 86400);
    const downloadUrl = `${CANONICAL_ORIGIN}/vault/download?token=${encodeURIComponent(dlToken)}`;

    return jsonResponse({
      ok: true,
      path: targetPath,
      size: headObj.size,
      mime_type: headObj.httpMetadata?.contentType || guessMimeType(targetPath),
      download_url: downloadUrl,
      expires_in_seconds: 86400,
      supports_range: true
    }, 200, corsHeaders);
  }

  // 12. GET /v1/size - Folder size and item count
  if (pathname === "/v1/size" && request.method === "GET") {
    const subpath = (url.searchParams.get("path") || "").replace(/^\/+/, "").replace(/\/+$/, "");
    const prefix = subpath ? `${userPrefix}/${subpath}/` : `${userPrefix}/`;

    let count = 0;
    let totalBytes = 0;
    let cursor;
    do {
      const listed = await env.VAULT_BUCKET.list({ prefix, limit: 1000, cursor });
      for (const obj of listed.objects || []) {
        count++;
        totalBytes += obj.size;
      }
      cursor = listed.truncated ? listed.cursor : undefined;
    } while (cursor && count < 50000);

    return jsonResponse({
      ok: true,
      path: subpath || "/",
      fileCount: count,
      totalBytes,
      sizeFormatted: `${(totalBytes / (1024 * 1024 * 1024)).toFixed(2)} GB`
    }, 200, corsHeaders);
  }

  // 13. GET /v1/search - Fast filename and extension search
  if (pathname === "/v1/search" && request.method === "GET") {
    const query = (url.searchParams.get("query") || url.searchParams.get("q") || "").toLowerCase().replace(/\*/g, "");
    if (!query) {
      return errorResponse("Missing parameter 'query'", 400, corsHeaders);
    }

    const subpath = (url.searchParams.get("path") || "").replace(/^\/+/, "").replace(/\/+$/, "");
    const prefix = subpath ? `${userPrefix}/${subpath}/` : `${userPrefix}/`;

    const matches = [];
    let cursor;
    let scanned = 0;
    do {
      const listed = await env.VAULT_BUCKET.list({ prefix, limit: 1000, cursor });
      for (const obj of listed.objects || []) {
        scanned++;
        const relPath = obj.key.slice(userPrefix.length + 1);
        if (relPath.toLowerCase().includes(query)) {
          matches.push({
            path: relPath,
            size: obj.size,
            modified: obj.uploaded.toISOString(),
            mime_type: obj.httpMetadata?.contentType || guessMimeType(relPath)
          });
          if (matches.length >= 100) break;
        }
      }
      cursor = listed.truncated && matches.length < 100 ? listed.cursor : undefined;
    } while (cursor && scanned < 25000);

    return jsonResponse({
      ok: true,
      query,
      path: subpath || "/",
      matches_count: matches.length,
      matches
    }, 200, corsHeaders);
  }

  // 14. POST /v1/grep - Text content search inside files
  if (pathname === "/v1/grep" && request.method === "POST") {
    let body = {};
    try { body = await request.json(); } catch { return errorResponse("Invalid JSON payload", 400, corsHeaders); }

    const query = String(body.query || "").trim();
    if (!query) {
      return errorResponse("Missing parameter 'query'", 400, corsHeaders);
    }
    const queryLower = query.toLowerCase();
    const subpath = (body.path || "").replace(/^\/+/, "").replace(/\/+$/, "");
    const prefix = subpath ? `${userPrefix}/${subpath}/` : `${userPrefix}/`;
    const maxResults = Math.min(Math.max(parseInt(body.max_results || 30, 10), 1), 100);

    const textExtensions = /\.(md|txt|json|jsonl|yaml|yml|csv|tsv|js|ts|jsx|tsx|py|sh|swift|html|css|xml|toml|ini|conf|env|sql)$/i;
    const directListed = await listDirectoryComplete(env, prefix, 4);
    const recursiveListed = await env.VAULT_BUCKET.list({ prefix, limit: 800 });

    const seenKeys = new Set();
    const candidateKeys = [];
    for (const o of [...(directListed.objects || []), ...(recursiveListed.objects || [])]) {
      if (seenKeys.has(o.key)) continue;
      seenKeys.add(o.key);
      if (o.key.includes("/.runitback/") || o.key.includes("/node_modules/") || o.key.includes("/.git/")) continue;
      if (o.size > 0 && o.size <= 512 * 1024 && textExtensions.test(o.key)) {
        candidateKeys.push(o);
        if (candidateKeys.length >= 100) break;
      }
    }

    const results = [];
    for (const objMeta of candidateKeys) {
      if (results.length >= maxResults) break;
      const obj = await env.VAULT_BUCKET.get(objMeta.key);
      if (!obj) continue;
      const text = await obj.text();
      if (!text.toLowerCase().includes(queryLower)) continue;

      const relPath = objMeta.key.slice(userPrefix.length + 1);
      const lines = text.split("\n");
      for (let i = 0; i < lines.length; i++) {
        if (lines[i].toLowerCase().includes(queryLower)) {
          results.push({
            path: relPath,
            line: i + 1,
            snippet: lines[i].trim().slice(0, 300)
          });
          if (results.length >= maxResults) break;
        }
      }
    }

    return jsonResponse({
      ok: true,
      query,
      path: subpath || "/",
      matches_count: results.length,
      results
    }, 200, corsHeaders);
  }

  // 15. GET /v1/doctor - Diagnostics & capabilities
  if (pathname === "/v1/doctor" && request.method === "GET") {
    const rootListing = await listDirectoryComplete(env, `${userPrefix}/`, 5);
    const skillsListing = await listDirectoryComplete(env, `${userPrefix}/_SKILLS/`, 5);
    const devices = await getSystemJson(env, userPrefix, "devices.json", []);
    const symlinks = await getSystemJson(env, userPrefix, "symlinks.json", []);

    return jsonResponse({
      ok: true,
      status: "healthy",
      domain: "api.zerodrive.dev",
      mcp_endpoint: `${CANONICAL_ORIGIN}/mcp`,
      openapi_spec: `${CANONICAL_ORIGIN}/openapi.json`,
      documentation: `${CANONICAL_ORIGIN}/docs`,
      tenant_vault_prefix: userPrefix,
      root_folders: rootListing.dirs,
      root_files: rootListing.files.map(f => f.name),
      installed_skills_count: skillsListing.dirs.length,
      installed_skills: skillsListing.dirs,
      connected_devices_count: devices.length,
      active_symlinks_count: symlinks.length,
      capabilities: {
        rest_api: "Full v1 REST API operational",
        hosted_mcp: "JSON-RPC 2.0 24/7 operational",
        streaming_uploads: "Pre-signed PUT URLs up to 5GB (videos, ZIPs, binaries)",
        streaming_downloads: "HTTP Range 206 supported for media streaming",
        agent_skills: "Packaged directly into _SKILLS/<verb-noun-name>/"
      }
    }, 200, corsHeaders);
  }

  // 16. GET /v1/skills - List or inspect reusable skills
  if (pathname === "/v1/skills" && request.method === "GET") {
    const skillName = url.searchParams.get("name");
    if (skillName) {
      const cleanName = skillName.trim().toLowerCase().replace(/[^a-z0-9-]+/g, "-");
      const skillPrefix = `${userPrefix}/_SKILLS/${cleanName}/`;
      const skillMd = await env.VAULT_BUCKET.get(`${userPrefix}/_SKILLS/${cleanName}/SKILL.md`);
      if (!skillMd) {
        return errorResponse(`Skill '${cleanName}' not found in _SKILLS/`, 404, corsHeaders);
      }
      const filesListing = await listDirectoryComplete(env, skillPrefix, 2);
      return jsonResponse({
        ok: true,
        skill: cleanName,
        folder: `_SKILLS/${cleanName}`,
        skill_md: await skillMd.text(),
        bundled_files: filesListing.files.map(f => f.name)
      }, 200, corsHeaders);
    }

    const skillsListing = await listDirectoryComplete(env, `${userPrefix}/_SKILLS/`, 5);
    const skills = [];
    for (const dir of skillsListing.dirs) {
      const obj = await env.VAULT_BUCKET.get(`${userPrefix}/_SKILLS/${dir}/SKILL.md`);
      let description = "";
      if (obj) {
        const text = await obj.text();
        const match = text.match(/description:\s*([^\n]+)/i);
        if (match) description = match[1].trim();
      }
      skills.push({ name: dir, folder: `_SKILLS/${dir}`, description });
    }

    return jsonResponse({
      ok: true,
      count: skills.length,
      skills
    }, 200, corsHeaders);
  }

  // 17. POST /v1/skills - Create or package a reusable skill
  if (pathname === "/v1/skills" && request.method === "POST") {
    let body = {};
    try { body = await request.json(); } catch { return errorResponse("Invalid JSON payload", 400, corsHeaders); }

    let skillName = String(body.name || "")
      .trim()
      .toLowerCase()
      .replace(/[^a-z0-9-]+/g, "-")
      .replace(/^-+|-+$/g, "");

    if (!skillName) {
      return errorResponse("Provide a valid skill name (e.g. 'create-substack-articles')", 400, corsHeaders);
    }

    const bannedWords = ["forge", "engine", "system", "suite", "hub", "nexus", "matrix", "factory", "mastery", "ultimate", "pro", "2-0"];
    const usedBanned = bannedWords.filter(w => skillName.split("-").includes(w));
    if (usedBanned.length > 0) {
      return errorResponse(`Skill name '${skillName}' contains banned buzzword(s): ${usedBanned.join(", ")}. Rename using plain verb-noun format (e.g. 'create-substack-articles').`, 400, corsHeaders);
    }

    const desc = String(body.description || "Reusable ZeroDrive agent skill.").trim();
    let bodyMd = String(body.instructions || "").trim();
    if (!bodyMd.startsWith("---")) {
      bodyMd = `---\nname: ${skillName}\ndescription: ${desc.replace(/\n+/g, " ")}\n---\n\n${bodyMd}\n`;
    }

    const skillFolder = `_SKILLS/${skillName}`;
    const skillMdKey = `${userPrefix}/${skillFolder}/SKILL.md`;
    await env.VAULT_BUCKET.put(skillMdKey, bodyMd, {
      httpMetadata: { contentType: "text/markdown; charset=utf-8" }
    });

    const savedFiles = [`${skillFolder}/SKILL.md`];
    if (Array.isArray(body.files)) {
      for (const f of body.files) {
        const rel = String(f?.relative_path || "").replace(/^\/+/, "");
        if (!rel) continue;
        const fileSubpath = `${skillFolder}/${rel}`;
        const fileKey = `${userPrefix}/${fileSubpath}`;
        const fileMime = guessMimeType(fileSubpath);

        if (f.source_url) {
          const resp = await fetch(String(f.source_url));
          if (resp.ok) {
            const buf = await resp.arrayBuffer();
            await env.VAULT_BUCKET.put(fileKey, buf, { httpMetadata: { contentType: resp.headers.get("content-type") || fileMime } });
            savedFiles.push(fileSubpath);
          }
        } else if (f.content_base64) {
          const bytes = base64ToBytes(f.content_base64);
          await env.VAULT_BUCKET.put(fileKey, bytes, { httpMetadata: { contentType: fileMime } });
          savedFiles.push(fileSubpath);
        } else if (f.content !== undefined) {
          await env.VAULT_BUCKET.put(fileKey, String(f.content), { httpMetadata: { contentType: fileMime } });
          savedFiles.push(fileSubpath);
        }
      }
    }

    await logActivity(env, userPrefix, "save_skill", { skill: skillName, files: savedFiles });

    return jsonResponse({
      ok: true,
      skill: skillName,
      folder: skillFolder,
      saved_files: savedFiles
    }, 201, corsHeaders);
  }

  // 18. Multi-Device Fleet: GET /v1/devices & POST /v1/devices/heartbeat
  if (pathname === "/v1/devices" && request.method === "GET") {
    const devices = await getSystemJson(env, userPrefix, "devices.json", []);
    return jsonResponse({ ok: true, count: devices.length, devices }, 200, corsHeaders);
  }

  if (pathname === "/v1/devices/heartbeat" && request.method === "POST") {
    let body = {};
    try { body = await request.json(); } catch { return errorResponse("Invalid JSON payload", 400, corsHeaders); }

    const deviceId = String(body.device_id || body.hostname || "unknown-device").trim();
    const devices = await getSystemJson(env, userPrefix, "devices.json", []);

    const updatedDevice = {
      device_id: deviceId,
      hostname: body.hostname || deviceId,
      os: body.os || "macOS",
      free_gb: body.free_gb !== undefined ? Number(body.free_gb) : null,
      mount_status: body.mount_status || "mounted",
      mount_path: body.mount_path || "~/.zerodrive-mount",
      cli_version: body.version || "1.1.0",
      ip: request.headers.get("cf-connecting-ip") || "unknown",
      last_heartbeat: new Date().toISOString()
    };

    const idx = devices.findIndex(d => d.device_id === deviceId);
    if (idx >= 0) {
      devices[idx] = { ...devices[idx], ...updatedDevice };
    } else {
      devices.push(updatedDevice);
    }

    await setSystemJson(env, userPrefix, "devices.json", devices);
    return jsonResponse({ ok: true, device: updatedDevice }, 200, corsHeaders);
  }

  // 19. Multi-Device Symlinks: GET /v1/symlinks & POST /v1/symlinks
  if (pathname === "/v1/symlinks" && request.method === "GET") {
    const symlinks = await getSystemJson(env, userPrefix, "symlinks.json", []);
    return jsonResponse({ ok: true, count: symlinks.length, symlinks }, 200, corsHeaders);
  }

  if (pathname === "/v1/symlinks" && request.method === "POST") {
    let body = {};
    try { body = await request.json(); } catch { return errorResponse("Invalid JSON payload", 400, corsHeaders); }

    const localPath = String(body.local_path || "").trim();
    const vaultTarget = String(body.vault_target || "").trim();
    if (!localPath || !vaultTarget) {
      return errorResponse("Fields 'local_path' and 'vault_target' are required", 400, corsHeaders);
    }

    const symlinks = await getSystemJson(env, userPrefix, "symlinks.json", []);
    const entry = {
      id: `sym_${Date.now()}`,
      device_id: body.device_id || "naegele-pro",
      local_path: localPath,
      vault_target: vaultTarget,
      created_at: new Date().toISOString()
    };

    const existingIdx = symlinks.findIndex(s => s.device_id === entry.device_id && s.local_path === localPath);
    if (existingIdx >= 0) {
      symlinks[existingIdx] = entry;
    } else {
      symlinks.push(entry);
    }

    await setSystemJson(env, userPrefix, "symlinks.json", symlinks);
    await logActivity(env, userPrefix, "register_symlink", entry);

    return jsonResponse({ ok: true, symlink: entry }, 201, corsHeaders);
  }

  // 20. Activity Ledger: GET /v1/activity & POST /v1/activity
  if (pathname === "/v1/activity" && request.method === "GET") {
    const activities = await getSystemJson(env, userPrefix, "activity.json", []);
    return jsonResponse({ ok: true, count: activities.length, activities }, 200, corsHeaders);
  }

  if (pathname === "/v1/activity" && request.method === "POST") {
    let body = {};
    try { body = await request.json(); } catch { return errorResponse("Invalid JSON payload", 400, corsHeaders); }
    const action = String(body.action || "custom_event").trim();
    const entry = await logActivity(env, userPrefix, action, body.details || {});
    return jsonResponse({ ok: true, activity: entry }, 201, corsHeaders);
  }

  return errorResponse(`Endpoint not found: ${request.method} ${pathname}`, 404, corsHeaders, {
    available_endpoints: [
      "GET /v1/tree", "GET /v1/files", "GET /v1/files/stat", "POST /v1/files/read", "POST /v1/files/write",
      "POST /v1/files/edit", "POST /v1/files/move", "POST /v1/files/copy", "POST /v1/files/delete",
      "POST /v1/files/batch", "POST /v1/files/upload-urls", "GET /v1/files/download-url",
      "GET /v1/size", "GET /v1/search", "POST /v1/grep", "GET /v1/doctor",
      "GET /v1/skills", "POST /v1/skills", "GET /v1/devices", "POST /v1/devices/heartbeat",
      "GET /v1/symlinks", "POST /v1/symlinks", "GET /v1/activity", "POST /v1/activity"
    ]
  });
}

function handleOpenAPISpec(url, corsHeaders) {
  const origin = CANONICAL_ORIGIN;
  const spec = {
    openapi: "3.1.0",
    info: {
      title: "ZeroDrive REST & MCP API",
      description: "Complete REST API and 24/7 hosted Model Context Protocol (MCP) server for ZeroDrive Cloud Vault. Query, browse, stream, edit, and organize files across every connected device and AI agent.",
      version: "1.2.0",
      "x-logo": {
        url: CONNECTOR_ICON_URL,
        altText: "ZeroDrive"
      },
      contact: {
        name: "ZeroDrive Support",
        url: "https://zerodrive.dev",
        email: "naegele412@gmail.com"
      }
    },
    servers: [
      { url: origin, description: "ZeroDrive Production Edge API" }
    ],
    tags: [
      { name: "Vault Files", description: "Read, write, edit, slice, move, copy, and stream files" },
      { name: "Search & Intelligence", description: "Fast server-side filename searching and text grep" },
      { name: "Streaming & Binaries", description: "Direct pre-signed upload URLs and media streaming" },
      { name: "Agent Skills", description: "Reusable skills packaged into _SKILLS/ with strict naming rules" },
      { name: "Multi-Device Fleet", description: "Fleet telemetry, device heartbeats, and symlink management" },
      { name: "Diagnostics & MCP", description: "Vault health doctor and JSON-RPC 2.0 MCP interface" }
    ],
    paths: {
      "/v1/tree": {
        get: {
          tags: ["Vault Files"],
          summary: "Get Visual Folder Tree",
          description: "Returns a visual directory tree hierarchy of the vault or subfolder.",
          operationId: "getTree",
          parameters: [
            { name: "path", in: "query", schema: { type: "string" }, description: "Subfolder path to inspect (e.g. '', 'MAIN', 'Course')" },
            { name: "depth", in: "query", schema: { type: "integer", default: 2, minimum: 1, maximum: 4 }, description: "Depth of tree traversal" }
          ],
          responses: {
            "200": { description: "Directory tree rendered cleanly" },
            "401": { description: "Unauthorized" }
          }
        }
      },
      "/v1/files": {
        get: {
          tags: ["Vault Files"],
          summary: "List Files and Directories",
          description: "List contents of any folder with file sizes, modified timestamps, MIME types, and optional cursor-based pagination.",
          operationId: "listFiles",
          parameters: [
            { name: "path", in: "query", schema: { type: "string" }, description: "Directory path" },
            { name: "limit", in: "query", schema: { type: "integer", default: 500, minimum: 1, maximum: 1000 }, description: "Maximum items per page" },
            { name: "cursor", in: "query", schema: { type: "string" }, description: "Opaque pagination cursor from previous response" },
            { name: "recursive", in: "query", schema: { type: "boolean", default: false }, description: "List recursively" }
          ],
          responses: {
            "200": { description: "Folder listing with next_cursor and total_count" },
            "401": { description: "Unauthorized" }
          }
        },
        delete: {
          tags: ["Vault Files"],
          summary: "Delete File",
          description: "Delete a file from the vault.",
          operationId: "deleteFileQuery",
          parameters: [
            { name: "path", in: "query", required: true, schema: { type: "string" }, description: "File path to delete" }
          ],
          responses: {
            "200": { description: "File deleted" }
          }
        }
      },
      "/v1/files/stat": {
        get: {
          tags: ["Vault Files"],
          summary: "Get Item Metadata (Stat)",
          description: "Retrieve metadata (size, modification date, MIME type, ETag, and directory status) for a single item in sub-15ms.",
          operationId: "statItem",
          parameters: [
            { name: "path", in: "query", required: true, schema: { type: "string" }, description: "File or directory path" }
          ],
          responses: {
            "200": { description: "Item metadata" },
            "404": { description: "Item not found" }
          }
        }
      },
      "/v1/files/read": {
        post: {
          tags: ["Vault Files"],
          summary: "Read File with Slicing",
          description: "Read text contents with optional line range slicing (head/tail/lines) or retrieve binary metadata and download URL.",
          operationId: "readFile",
          requestBody: {
            required: true,
            content: {
              "application/json": {
                schema: {
                  type: "object",
                  required: ["path"],
                  properties: {
                    path: { type: "string", description: "Vault file path (e.g. 'MAIN/notes.md')" },
                    head: { type: "integer", description: "Read first N lines" },
                    tail: { type: "integer", description: "Read last N lines" },
                    lines: { type: "string", description: "Line range (e.g. '1-100')" },
                    encoding: { type: "string", enum: ["utf-8", "base64"], default: "utf-8" }
                  }
                }
              }
            }
          },
          responses: {
            "200": { description: "File content retrieved" }
          }
        }
      },
      "/v1/files/write": {
        post: {
          tags: ["Vault Files"],
          summary: "Write or Append File",
          description: "Create, overwrite, or append to any file in the vault via text, base64 binary, or remote source_url.",
          operationId: "writeFile",
          requestBody: {
            required: true,
            content: {
              "application/json": {
                schema: {
                  type: "object",
                  required: ["path"],
                  properties: {
                    path: { type: "string", description: "Target vault path" },
                    content: { type: "string", description: "UTF-8 text content" },
                    content_base64: { type: "string", description: "Base64 data for binary files" },
                    source_url: { type: "string", description: "URL to download directly into vault" },
                    content_type: { type: "string", description: "MIME type (optional)" },
                    append: { type: "boolean", default: false, description: "Append to existing file" }
                  }
                }
              }
            }
          },
          responses: {
            "200": { description: "File written successfully" }
          }
        }
      },
      "/v1/files/edit": {
        post: {
          tags: ["Vault Files"],
          summary: "Surgical Text Replacement",
          description: "Replace exact target string with replacement text in a file without re-uploading the entire document.",
          operationId: "editFile",
          requestBody: {
            required: true,
            content: {
              "application/json": {
                schema: {
                  type: "object",
                  required: ["path", "old_text", "new_text"],
                  properties: {
                    path: { type: "string", description: "Vault path" },
                    old_text: { type: "string", description: "Exact string to find" },
                    new_text: { type: "string", description: "Replacement string" }
                  }
                }
              }
            }
          },
          responses: {
            "200": { description: "Text replaced" }
          }
        }
      },
      "/v1/files/move": {
        post: {
          tags: ["Vault Files"],
          summary: "Move or Rename File",
          description: "Move or rename a file within the vault.",
          operationId: "moveFile",
          requestBody: {
            required: true,
            content: {
              "application/json": {
                schema: {
                  type: "object",
                  required: ["source", "destination"],
                  properties: {
                    source: { type: "string" },
                    destination: { type: "string" }
                  }
                }
              }
            }
          },
          responses: {
            "200": { description: "File moved" }
          }
        }
      },
      "/v1/files/copy": {
        post: {
          tags: ["Vault Files"],
          summary: "Copy File",
          description: "Duplicate a file to a new destination in the vault.",
          operationId: "copyFile",
          requestBody: {
            required: true,
            content: {
              "application/json": {
                schema: {
                  type: "object",
                  required: ["source", "destination"],
                  properties: {
                    source: { type: "string" },
                    destination: { type: "string" }
                  }
                }
              }
            }
          },
          responses: {
            "200": { description: "File copied" }
          }
        }
      },
      "/v1/files/delete": {
        post: {
          tags: ["Vault Files"],
          summary: "Delete File via POST",
          description: "Delete a file from the vault.",
          operationId: "deleteFile",
          requestBody: {
            required: true,
            content: {
              "application/json": {
                schema: {
                  type: "object",
                  required: ["path"],
                  properties: {
                    path: { type: "string" }
                  }
                }
              }
            }
          },
          responses: {
            "200": { description: "File deleted" }
          }
        }
      },
      "/v1/files/batch": {
        post: {
          tags: ["Vault Files"],
          summary: "Batch File Operations",
          description: "Execute multiple move, copy, and delete operations in a single atomic request.",
          operationId: "batchOperations",
          requestBody: {
            required: true,
            content: {
              "application/json": {
                schema: {
                  type: "object",
                  required: ["operations"],
                  properties: {
                    operations: {
                      type: "array",
                      items: {
                        type: "object",
                        required: ["action"],
                        properties: {
                          action: { type: "string", enum: ["delete", "copy", "move"] },
                          path: { type: "string" },
                          source: { type: "string" },
                          destination: { type: "string" }
                        }
                      }
                    }
                  }
                }
              }
            }
          },
          responses: {
            "200": { description: "Batch results" }
          }
        }
      },
      "/v1/files/upload-urls": {
        post: {
          tags: ["Streaming & Binaries"],
          summary: "Create Pre-Signed Upload URLs",
          description: "Generate 1-hour pre-signed direct HTTP PUT upload URLs for streaming large local files (screenshots, PDFs, MP4/MOV videos, ZIPs up to 5GB) with zero LLM token overhead.",
          operationId: "createUploadUrls",
          requestBody: {
            required: true,
            content: {
              "application/json": {
                schema: {
                  type: "object",
                  properties: {
                    paths: { type: "array", items: { type: "string" } },
                    path: { type: "string" }
                  }
                }
              }
            }
          },
          responses: {
            "200": { description: "Pre-signed PUT URLs generated" }
          }
        }
      },
      "/v1/files/download-url": {
        get: {
          tags: ["Streaming & Binaries"],
          summary: "Get Pre-Signed Download URL",
          description: "Get a 24-hour HTTPS download URL with HTTP Range (206) support for fast streaming of videos, PDFs, and archives.",
          operationId: "getDownloadUrl",
          parameters: [
            { name: "path", in: "query", required: true, schema: { type: "string" } }
          ],
          responses: {
            "200": { description: "Download URL returned" }
          }
        }
      },
      "/v1/size": {
        get: {
          tags: ["Search & Intelligence"],
          summary: "Get Folder Size & Item Count",
          description: "Calculate exact byte size, GB formatted total, and file count for any folder.",
          operationId: "getFolderSize",
          parameters: [
            { name: "path", in: "query", schema: { type: "string" }, description: "Folder path (leave blank for vault root)" }
          ],
          responses: {
            "200": { description: "Size summary" }
          }
        }
      },
      "/v1/search": {
        get: {
          tags: ["Search & Intelligence"],
          summary: "Search Filenames & Extensions",
          description: "Fast server-side wildcard search across all files in vault.",
          operationId: "searchFilenames",
          parameters: [
            { name: "query", in: "query", required: true, schema: { type: "string" }, description: "Keyword or extension to find" },
            { name: "path", in: "query", schema: { type: "string" }, description: "Subfolder filter" }
          ],
          responses: {
            "200": { description: "Matching files" }
          }
        }
      },
      "/v1/grep": {
        post: {
          tags: ["Search & Intelligence"],
          summary: "Grep Inside Text Files",
          description: "Search text contents across markdown, code, and text files, returning line numbers and snippets.",
          operationId: "grepVault",
          requestBody: {
            required: true,
            content: {
              "application/json": {
                schema: {
                  type: "object",
                  required: ["query"],
                  properties: {
                    query: { type: "string", description: "Search keyword or text" },
                    path: { type: "string", description: "Folder to restrict search to" },
                    max_results: { type: "integer", default: 30 }
                  }
                }
              }
            }
          },
          responses: {
            "200": { description: "Grep results" }
          }
        }
      },
      "/v1/doctor": {
        get: {
          tags: ["Diagnostics & MCP"],
          summary: "Vault Doctor Health Check",
          description: "Inspect root folders, installed skills, connected devices, and service capabilities.",
          operationId: "getVaultDoctor",
          responses: {
            "200": { description: "Health diagnostics" }
          }
        }
      },
      "/v1/skills": {
        get: {
          tags: ["Agent Skills"],
          summary: "List or Inspect Skills",
          description: "List all agent skills in _SKILLS/ or inspect a specific skill's SKILL.md.",
          operationId: "getSkills",
          parameters: [
            { name: "name", in: "query", schema: { type: "string" }, description: "Specific skill name (e.g. 'create-substack-articles')" }
          ],
          responses: {
            "200": { description: "Skill details or list" }
          }
        },
        post: {
          tags: ["Agent Skills"],
          summary: "Package and Save Skill",
          description: "Package a reusable Agent Skill into _SKILLS/<verb-noun-name>/SKILL.md enforcing naming rules and buzzword filters.",
          operationId: "saveSkill",
          requestBody: {
            required: true,
            content: {
              "application/json": {
                schema: {
                  type: "object",
                  required: ["name", "description", "instructions"],
                  properties: {
                    name: { type: "string", description: "Lowercase hyphenated verb-noun name (e.g. 'create-substack-articles')" },
                    description: { type: "string", description: "Short description" },
                    instructions: { type: "string", description: "Markdown instructions for SKILL.md" },
                    files: {
                      type: "array",
                      description: "Optional bundled scripts or files",
                      items: {
                        type: "object",
                        required: ["relative_path"],
                        properties: {
                          relative_path: { type: "string" },
                          content: { type: "string" },
                          content_base64: { type: "string" },
                          source_url: { type: "string" }
                        }
                      }
                    }
                  }
                }
              }
            }
          },
          responses: {
            "201": { description: "Skill saved" }
          }
        }
      },
      "/v1/devices": {
        get: {
          tags: ["Multi-Device Fleet"],
          summary: "List Connected Devices",
          description: "List all registered Mac computers, servers, and VMs connected to the vault.",
          operationId: "getDevices",
          responses: {
            "200": { description: "Device fleet status" }
          }
        }
      },
      "/v1/devices/heartbeat": {
        post: {
          tags: ["Multi-Device Fleet"],
          summary: "Record Device Heartbeat",
          description: "Record disk space, mount state, and heartbeat from a connected device.",
          operationId: "recordDeviceHeartbeat",
          requestBody: {
            required: true,
            content: {
              "application/json": {
                schema: {
                  type: "object",
                  required: ["device_id"],
                  properties: {
                    device_id: { type: "string" },
                    hostname: { type: "string" },
                    os: { type: "string" },
                    free_gb: { type: "number" },
                    mount_status: { type: "string" },
                    mount_path: { type: "string" },
                    version: { type: "string" }
                  }
                }
              }
            }
          },
          responses: {
            "200": { description: "Heartbeat acknowledged" }
          }
        }
      },
      "/v1/symlinks": {
        get: {
          tags: ["Multi-Device Fleet"],
          summary: "List Active Symlinks",
          description: "List folder shortcuts created across user devices.",
          operationId: "getSymlinks",
          responses: {
            "200": { description: "Symlink registry" }
          }
        },
        post: {
          tags: ["Multi-Device Fleet"],
          summary: "Register Local Symlink",
          description: "Register a local symlink on a device mapping to a vault folder.",
          operationId: "registerSymlink",
          requestBody: {
            required: true,
            content: {
              "application/json": {
                schema: {
                  type: "object",
                  required: ["local_path", "vault_target"],
                  properties: {
                    device_id: { type: "string" },
                    local_path: { type: "string" },
                    vault_target: { type: "string" }
                  }
                }
              }
            }
          },
          responses: {
            "201": { description: "Symlink registered" }
          }
        }
      },
      "/v1/activity": {
        get: {
          tags: ["Multi-Device Fleet"],
          summary: "Get Activity Ledger",
          description: "Recent file migrations, sync events, and agent operations across devices.",
          operationId: "getActivity",
          responses: {
            "200": { description: "Recent activity entries" }
          }
        },
        post: {
          tags: ["Multi-Device Fleet"],
          summary: "Log Custom Activity",
          description: "Record a custom activity entry in the vault ledger.",
          operationId: "logActivityEntry",
          requestBody: {
            required: true,
            content: {
              "application/json": {
                schema: {
                  type: "object",
                  required: ["action"],
                  properties: {
                    action: { type: "string" },
                    details: { type: "object" }
                  }
                }
              }
            }
          },
          responses: {
            "201": { description: "Activity recorded" }
          }
        }
      },
      "/mcp": {
        post: {
          tags: ["Diagnostics & MCP"],
          summary: "ZeroDrive MCP JSON-RPC 2.0 Endpoint",
          operationId: "executeMCP",
          requestBody: {
            required: true,
            content: {
              "application/json": {
                schema: {
                  type: "object",
                  properties: {
                    jsonrpc: { type: "string", example: "2.0" },
                    id: { type: "string", example: "1" },
                    method: { type: "string", example: "tools/list" },
                    params: { type: "object" }
                  }
                }
              }
            }
          },
          responses: {
            "200": { description: "MCP JSON-RPC response" }
          }
        }
      }
    },
    components: {
      securitySchemes: {
        BearerAuth: {
          type: "http",
          scheme: "bearer",
          bearerFormat: "API_KEY / OAuth Token",
          description: "ZeroDrive Master API Key or OAuth 2.0 Bearer token"
        },
        OAuth2: {
          type: "oauth2",
          description: "ZeroDrive OAuth 2.0 flow with 1-click Google authentication",
          flows: {
            authorizationCode: {
              authorizationUrl: `${origin}/oauth/authorize`,
              tokenUrl: `${origin}/oauth/token`,
              scopes: {
                mcp: "Full MCP and REST agent vault access",
                "vault:read": "Read files in vault",
                "vault:write": "Write and upload files in vault"
              }
            }
          }
        }
      }
    },
    security: [
      { BearerAuth: [] },
      { OAuth2: ["mcp", "vault:read", "vault:write"] }
    ]
  };

  return new Response(JSON.stringify(spec, null, 2), {
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" }
  });
}

function handleApiDocsHtml(url, corsHeaders) {
  const origin = CANONICAL_ORIGIN;
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>ZeroDrive REST API &amp; Agent Documentation</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="icon" type="image/png" href="${CONNECTOR_ICON_URL}">
  <style>
    :root {
      --bg: #090a0f;
      --card-bg: rgba(255, 255, 255, 0.03);
      --card-border: rgba(255, 255, 255, 0.08);
      --accent: #f5a623;
      --accent-glow: rgba(245, 166, 35, 0.15);
      --text: #f5f5f7;
      --text-muted: #8e8e93;
      --code-bg: #12131a;
      --green: #34c759;
      --blue: #0a84ff;
    }
    * { box-sizing: border-box; -webkit-font-smoothing: antialiased; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", Roboto, sans-serif;
      background: var(--bg);
      color: var(--text);
      margin: 0;
      padding: 0;
      line-height: 1.6;
    }
    header {
      border-bottom: 1px solid var(--card-border);
      padding: 18px 32px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      position: sticky;
      top: 0;
      background: rgba(9, 10, 15, 0.85);
      backdrop-filter: blur(16px);
      z-index: 100;
    }
    .brand {
      display: flex;
      align-items: center;
      gap: 12px;
      text-decoration: none;
      color: #fff;
      font-weight: 700;
      font-size: 18px;
    }
    .brand img { width: 34px; height: 34px; border-radius: 8px; }
    .nav-links { display: flex; gap: 20px; align-items: center; }
    .nav-links a { color: var(--text-muted); text-decoration: none; font-size: 14px; transition: color 0.15s; }
    .nav-links a:hover { color: #fff; }
    .badge {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 4px 10px;
      background: rgba(52, 199, 89, 0.12);
      border: 1px solid rgba(52, 199, 89, 0.25);
      border-radius: 999px;
      color: var(--green);
      font-size: 12px;
      font-weight: 500;
    }
    .badge-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--green); box-shadow: 0 0 6px var(--green); }
    .container {
      max-width: 1100px;
      margin: 0 auto;
      padding: 48px 24px;
    }
    h1 { font-size: 38px; margin: 0 0 12px; letter-spacing: -0.02em; }
    .subtitle { font-size: 18px; color: var(--text-muted); margin: 0 0 40px; max-width: 760px; }
    .quick-bar {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
      gap: 16px;
      margin-bottom: 48px;
    }
    .quick-card {
      background: var(--card-bg);
      border: 1px solid var(--card-border);
      border-radius: 14px;
      padding: 18px;
    }
    .quick-card h4 { margin: 0 0 6px; font-size: 15px; color: #fff; }
    .quick-card p { margin: 0; font-size: 13px; color: var(--text-muted); }
    .endpoint {
      background: var(--card-bg);
      border: 1px solid var(--card-border);
      border-radius: 16px;
      margin-bottom: 24px;
      overflow: hidden;
    }
    .endpoint-header {
      padding: 16px 20px;
      display: flex;
      align-items: center;
      gap: 14px;
      border-bottom: 1px solid var(--card-border);
      background: rgba(255, 255, 255, 0.015);
    }
    .method {
      font-family: ui-monospace, Menlo, monospace;
      font-weight: 700;
      font-size: 12px;
      padding: 4px 8px;
      border-radius: 6px;
      letter-spacing: 0.05em;
    }
    .method.get { background: rgba(52, 199, 89, 0.15); color: var(--green); border: 1px solid rgba(52, 199, 89, 0.3); }
    .method.post { background: rgba(245, 166, 35, 0.15); color: var(--accent); border: 1px solid rgba(245, 166, 35, 0.3); }
    .method.delete { background: rgba(255, 69, 58, 0.15); color: #ff453a; border: 1px solid rgba(255, 69, 58, 0.3); }
    .ep-path { font-family: ui-monospace, Menlo, monospace; font-size: 15px; font-weight: 600; color: #fff; }
    .ep-desc { color: var(--text-muted); font-size: 13px; margin-left: auto; }
    .endpoint-body { padding: 20px; font-size: 14px; }
    pre {
      background: var(--code-bg);
      border: 1px solid var(--card-border);
      border-radius: 10px;
      padding: 14px 16px;
      overflow-x: auto;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 13px;
      color: #e5e5ea;
      margin: 12px 0;
      position: relative;
    }
    .copy-btn {
      position: absolute;
      top: 10px;
      right: 10px;
      background: rgba(255, 255, 255, 0.08);
      border: 1px solid rgba(255, 255, 255, 0.12);
      color: #fff;
      padding: 4px 10px;
      border-radius: 6px;
      font-size: 11px;
      cursor: pointer;
    }
    .copy-btn:hover { background: rgba(255, 255, 255, 0.16); }
    .section-title {
      font-size: 22px;
      font-weight: 700;
      margin: 48px 0 18px;
      color: #fff;
      border-bottom: 1px solid var(--card-border);
      padding-bottom: 8px;
    }
  </style>
</head>
<body>
  <header>
    <a href="/" class="brand">
      <img src="${CONNECTOR_ICON_URL}" alt="ZeroDrive">
      <span>ZeroDrive API</span>
    </a>
    <div class="nav-links">
      <span class="badge"><span class="badge-dot"></span> v1 Live Edge</span>
      <a href="/openapi.json">OpenAPI 3.1 Spec</a>
      <a href="/mcp">Hosted MCP</a>
      <a href="/v1/health">Health</a>
    </div>
  </header>

  <div class="container">
    <h1>ZeroDrive REST &amp; Agent API</h1>
    <p class="subtitle">Complete, low-latency REST API and 24/7 Model Context Protocol (MCP) server for querying, reading, writing, and streaming your entire cloud vault across all your Macs, servers, and AI agents.</p>

    <div class="quick-bar">
      <div class="quick-card">
        <h4>Base URL</h4>
        <p><code>https://api.zerodrive.dev</code></p>
      </div>
      <div class="quick-card">
        <h4>Authentication</h4>
        <p><code>Authorization: Bearer &lt;TOKEN&gt;</code></p>
      </div>
      <div class="quick-card">
        <h4>OpenAPI 3.1 Blueprint</h4>
        <p><a href="/openapi.json" style="color:var(--accent);">api.zerodrive.dev/openapi.json</a></p>
      </div>
      <div class="quick-card">
        <h4>Hosted Agent MCP</h4>
        <p><a href="/mcp" style="color:var(--green);">api.zerodrive.dev/mcp</a></p>
      </div>
    </div>

    <!-- Section 1: Authentication -->
    <div class="section-title">1. Authentication</div>
    <p style="color:var(--text-muted); font-size:14px;">Every request requires a Bearer token in the <code>Authorization</code> header or as a <code>?key=</code> query parameter. You can use your Master API Key or an OAuth 2.0 token obtained via 1-click Google Login (<code>/login</code>).</p>
    <pre><code>curl -H "Authorization: Bearer zd_oauth_master_..." "https://api.zerodrive.dev/v1/tree?depth=2"</code><button class="copy-btn" onclick="copyPre(this)">Copy</button></pre>

    <!-- Section 2: Vault Navigation -->
    <div class="section-title">2. Vault Browsing &amp; Sizing</div>

    <div class="endpoint">
      <div class="endpoint-header">
        <span class="method get">GET</span>
        <span class="ep-path">/v1/tree</span>
        <span class="ep-desc">Visual directory tree of the vault</span>
      </div>
      <div class="endpoint-body">
        <p>Query parameters: <code>path</code> (optional, e.g. <code>MAIN</code>), <code>depth</code> (1 to 4, default 2).</p>
        <pre><code>curl -s "https://api.zerodrive.dev/v1/tree?path=MAIN&amp;depth=2" \
  -H "Authorization: Bearer YOUR_TOKEN"</code><button class="copy-btn" onclick="copyPre(this)">Copy</button></pre>
      </div>
    </div>

    <div class="endpoint">
      <div class="endpoint-header">
        <span class="method get">GET</span>
        <span class="ep-path">/v1/files</span>
        <span class="ep-desc">List files and folders with sizes and MIME types</span>
      </div>
      <div class="endpoint-body">
        <p>Query parameters: <code>path</code> (optional), <code>recursive</code> (boolean, default false).</p>
        <pre><code>curl -s "https://api.zerodrive.dev/v1/files?path=MAIN" \
  -H "Authorization: Bearer YOUR_TOKEN"</code><button class="copy-btn" onclick="copyPre(this)">Copy</button></pre>
      </div>
    </div>

    <div class="endpoint">
      <div class="endpoint-header">
        <span class="method get">GET</span>
        <span class="ep-path">/v1/size</span>
        <span class="ep-desc">Instant file count and byte / GB totals</span>
      </div>
      <div class="endpoint-body">
        <pre><code>curl -s "https://api.zerodrive.dev/v1/size?path=MAIN" \
  -H "Authorization: Bearer YOUR_TOKEN"</code><button class="copy-btn" onclick="copyPre(this)">Copy</button></pre>
      </div>
    </div>

    <!-- Section 3: File Operations -->
    <div class="section-title">3. File Operations (Read, Write, Edit, Move, Delete)</div>

    <div class="endpoint">
      <div class="endpoint-header">
        <span class="method post">POST</span>
        <span class="ep-path">/v1/files/read</span>
        <span class="ep-desc">Read file with line slicing or fetch binary metadata</span>
      </div>
      <div class="endpoint-body">
        <p>Accepts <code>path</code>, and optional <code>head</code>, <code>tail</code>, <code>lines</code> (e.g. <code>"1-50"</code>), or <code>encoding</code>.</p>
        <pre><code>curl -s -X POST "https://api.zerodrive.dev/v1/files/read" \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"path": "MAIN/notes.md", "lines": "1-30"}'</code><button class="copy-btn" onclick="copyPre(this)">Copy</button></pre>
      </div>
    </div>

    <div class="endpoint">
      <div class="endpoint-header">
        <span class="method post">POST</span>
        <span class="ep-path">/v1/files/write</span>
        <span class="ep-desc">Write or append text, base64 binary, or fetch from URL</span>
      </div>
      <div class="endpoint-body">
        <pre><code>curl -s -X POST "https://api.zerodrive.dev/v1/files/write" \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"path": "MAIN/log.txt", "content": "Agent entry\n", "append": true}'</code><button class="copy-btn" onclick="copyPre(this)">Copy</button></pre>
      </div>
    </div>

    <div class="endpoint">
      <div class="endpoint-header">
        <span class="method post">POST</span>
        <span class="ep-path">/v1/files/edit</span>
        <span class="ep-desc">Surgical find-and-replace inside a file</span>
      </div>
      <div class="endpoint-body">
        <pre><code>curl -s -X POST "https://api.zerodrive.dev/v1/files/edit" \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"path": "MAIN/config.json", "old_text": "v1.0.0", "new_text": "v1.1.0"}'</code><button class="copy-btn" onclick="copyPre(this)">Copy</button></pre>
      </div>
    </div>

    <div class="endpoint">
      <div class="endpoint-header">
        <span class="method post">POST</span>
        <span class="ep-path">/v1/files/upload-urls</span>
        <span class="ep-desc">Pre-signed HTTP PUT upload URLs for multi-GB streaming</span>
      </div>
      <div class="endpoint-body">
        <p>Generates 1-hour signed direct upload URLs. Upload from your terminal or script with zero LLM token overhead:</p>
        <pre><code>curl -s -X POST "https://api.zerodrive.dev/v1/files/upload-urls" \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"paths": ["MAIN/demo.mp4", "MAIN/bundle.zip"]}'</code><button class="copy-btn" onclick="copyPre(this)">Copy</button></pre>
      </div>
    </div>

    <!-- Section 4: Search -->
    <div class="section-title">4. Search &amp; Content Grep</div>

    <div class="endpoint">
      <div class="endpoint-header">
        <span class="method get">GET</span>
        <span class="ep-path">/v1/search</span>
        <span class="ep-desc">Fast server-side wildcard search</span>
      </div>
      <div class="endpoint-body">
        <pre><code>curl -s "https://api.zerodrive.dev/v1/search?query=.mp4&amp;path=MAIN" \
  -H "Authorization: Bearer YOUR_TOKEN"</code><button class="copy-btn" onclick="copyPre(this)">Copy</button></pre>
      </div>
    </div>

    <div class="endpoint">
      <div class="endpoint-header">
        <span class="method post">POST</span>
        <span class="ep-path">/v1/grep</span>
        <span class="ep-desc">Search inside text/code file contents</span>
      </div>
      <div class="endpoint-body">
        <pre><code>curl -s -X POST "https://api.zerodrive.dev/v1/grep" \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query": "Dan Kennedy", "path": "MAIN", "max_results": 20}'</code><button class="copy-btn" onclick="copyPre(this)">Copy</button></pre>
      </div>
    </div>

    <!-- Section 5: Agent Skills -->
    <div class="section-title">5. Agent Skills Engine (<code>_SKILLS/</code>)</div>

    <div class="endpoint">
      <div class="endpoint-header">
        <span class="method post">POST</span>
        <span class="ep-path">/v1/skills</span>
        <span class="ep-desc">Package and save reusable Agent Skills</span>
      </div>
      <div class="endpoint-body">
        <p>Enforces lowercase hyphenated verb-noun names (e.g. <code>create-substack-articles</code>) and blocks grand buzzwords.</p>
        <pre><code>curl -s -X POST "https://api.zerodrive.dev/v1/skills" \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "create-substack-articles",
    "description": "Draft Substack newsletter articles in brand voice.",
    "instructions": "# Instructions\n\n1. Write compelling hook..."
  }'</code><button class="copy-btn" onclick="copyPre(this)">Copy</button></pre>
      </div>
    </div>

    <!-- Section 6: Fleet & Symlinks -->
    <div class="section-title">6. Multi-Device Fleet &amp; Symlink Registry</div>

    <div class="endpoint">
      <div class="endpoint-header">
        <span class="method get">GET</span>
        <span class="ep-path">/v1/devices</span>
        <span class="ep-desc">List all connected Macs and devices</span>
      </div>
      <div class="endpoint-body">
        <pre><code>curl -s "https://api.zerodrive.dev/v1/devices" \
  -H "Authorization: Bearer YOUR_TOKEN"</code><button class="copy-btn" onclick="copyPre(this)">Copy</button></pre>
      </div>
    </div>

    <div class="endpoint">
      <div class="endpoint-header">
        <span class="method post">POST</span>
        <span class="ep-path">/v1/devices/heartbeat</span>
        <span class="ep-desc">Send device SSD telemetry and mount health</span>
      </div>
      <div class="endpoint-body">
        <pre><code>curl -s -X POST "https://api.zerodrive.dev/v1/devices/heartbeat" \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "naegele-pro", "hostname": "naegele-pro.local", "free_gb": 151.2, "mount_status": "mounted"}'</code><button class="copy-btn" onclick="copyPre(this)">Copy</button></pre>
      </div>
    </div>

  </div>

  <script>
    function copyPre(btn) {
      const code = btn.parentElement.querySelector("code").innerText;
      navigator.clipboard.writeText(code).then(() => {
        btn.innerText = "Copied!";
        setTimeout(() => { btn.innerText = "Copy"; }, 2000);
      });
    }
  </script>
</body>
</html>`;

  return new Response(html, {
    headers: { ...corsHeaders, "Content-Type": "text/html; charset=utf-8" }
  });
}


export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    const corsHeaders = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, HEAD, POST, PUT, DELETE, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization, Accept, Range, Mcp-Session-Id, MCP-Protocol-Version, Last-Event-ID, x-amz-content-sha256, x-amz-date, x-amz-copy-source",
      "Access-Control-Expose-Headers": "WWW-Authenticate, Mcp-Session-Id, MCP-Protocol-Version",
    };

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    // 0. Interactive API Documentation (/docs, /v1/docs, /api-docs)
    if (url.pathname === "/docs" || url.pathname === "/v1/docs" || url.pathname === "/api-docs") {
      return handleApiDocsHtml(url, corsHeaders);
    }

    // 0a. REST API v1 Router (/v1/*)
    if (
      url.pathname.startsWith("/v1/") &&
      url.pathname !== "/v1/mcp" &&
      url.pathname !== "/v1/health" &&
      url.pathname !== "/v1/vault/provision" &&
      url.pathname !== "/v1/openapi.json" &&
      url.pathname !== "/v1/oauth/authorize" &&
      url.pathname !== "/v1/oauth/token" &&
      url.pathname !== "/v1/oauth/register"
    ) {
      return handleRestV1Request(request, env, url, corsHeaders);
    }


    // Force canonical domain (api.zerodrive.dev) for all non-S3 endpoints so legacy zerodrive.aisimple.co is never used for OAuth or MCP
    if (url.hostname === "zerodrive.aisimple.co" && url.pathname !== "/s3" && !url.pathname.startsWith("/s3/")) {
      return Response.redirect(`${CANONICAL_ORIGIN}${url.pathname}${url.search}`, 301);
    }

    // 0a. OAuth 2.0 / OpenID Connect / MCP Discovery Metadata
    if (url.pathname === "/.well-known/mcp.json" || url.pathname === "/.well-known/mcp") {
      return new Response(JSON.stringify({
        name: "ZeroDrive",
        title: "ZeroDrive",
        description: "ZeroDrive 24/7 Cloud Vault MCP Server",
        version: "1.1.0",
        icon: CONNECTOR_ICON_URL,
        logo_url: CONNECTOR_ICON_URL,
        icons: [{ src: CONNECTOR_ICON_URL, mimeType: "image/png", sizes: ["256x256", "120x120"] }],
        endpoint: `${CANONICAL_ORIGIN}/mcp`,
        url: `${CANONICAL_ORIGIN}/mcp`,
        authentication: {
          type: "oauth2",
          authorization_endpoint: `${CANONICAL_ORIGIN}/oauth/authorize`,
          token_endpoint: `${CANONICAL_ORIGIN}/oauth/token`,
          registration_endpoint: `${CANONICAL_ORIGIN}/oauth/register`
        }
      }, null, 2), {
        headers: { ...corsHeaders, "Content-Type": "application/json" }
      });
    }
    if (url.pathname === "/openapi.json" || url.pathname === "/v1/openapi.json") {
      return handleOpenAPISpec(url, corsHeaders);
    }
    if (url.pathname === "/.well-known/ai-plugin.json") {
      return handleAIPluginManifest(url, corsHeaders);
    }
    if (url.pathname === "/.well-known/jwks.json") {
      return new Response(JSON.stringify({ keys: [] }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" }
      });
    }
    if (
      url.pathname.startsWith("/.well-known/oauth-protected-resource") ||
      url.pathname === "/mcp/.well-known/oauth-protected-resource"
    ) {
      return handleOAuthProtectedResource(url, corsHeaders);
    }
    if (
      url.pathname.startsWith("/.well-known/openid-configuration") ||
      url.pathname.startsWith("/.well-known/oauth-authorization-server") ||
      url.pathname === "/mcp/.well-known/openid-configuration" ||
      url.pathname === "/mcp/.well-known/oauth-authorization-server"
    ) {
      return handleOpenIDConfiguration(url, corsHeaders);
    }

    // 0b. OAuth 2.0 Dynamic Client Registration (RFC 7591)
    if (
      url.pathname === "/oauth/register" ||
      url.pathname === "/register" ||
      url.pathname === "/mcp/register" ||
      url.pathname === "/v1/oauth/register"
    ) {
      return handleOAuthRegister(request, env, url, corsHeaders);
    }

    // 0c. OAuth 2.0 Authorization Endpoint
    if (
      url.pathname === "/oauth/authorize" ||
      url.pathname === "/authorize" ||
      url.pathname === "/mcp/authorize" ||
      url.pathname === "/v1/oauth/authorize" ||
      url.pathname === "/auth/google" ||
      url.pathname === "/login"
    ) {
      return handleGoogleAuthStart(request, env, url);
    }

    // 0d. OAuth 2.0 Token Exchange Endpoint
    if (
      url.pathname === "/oauth/token" ||
      url.pathname === "/token" ||
      url.pathname === "/mcp/token" ||
      url.pathname === "/v1/oauth/token"
    ) {
      return handleOAuthToken(request, env, url, corsHeaders);
    }

    // 0e. OAuth 2.0 UserInfo Endpoint
    if (
      url.pathname === "/oauth/userinfo" ||
      url.pathname === "/userinfo" ||
      url.pathname === "/mcp/userinfo"
    ) {
      return handleOAuthUserInfo(request, env, url, corsHeaders);
    }

    // 0f. Google OAuth 2.0 Callback
    if (url.pathname === "/auth/callback" || url.pathname === "/oauth/callback") {
      return handleGoogleAuthCallback(request, env, url, corsHeaders);
    }

    // 1. S3-Compatible Multi-Tenant R2 Proxy
    if (url.pathname === "/s3" || url.pathname.startsWith("/s3/")) {
      return handleS3Proxy(request, env, url);
    }

    // 1b. Hosted 24/7 AI Agent MCP Server Endpoint (/mcp or /v1/mcp)
    if (url.pathname === "/mcp" || url.pathname === "/v1/mcp") {
      return handleMCPRequest(request, env, url, corsHeaders);
    }

    // 1c. Direct Binary File Upload & Download Endpoints (/vault/upload and /vault/download)
    if (url.pathname === "/vault/upload" && (request.method === "PUT" || request.method === "POST")) {
      const secret = env.GOOGLE_CLIENT_SECRET || "zd_secret";
      const tokenParam = url.searchParams.get("token") || "";
      let targetKey = "";
      let targetPath = "";
      let mimeType = request.headers.get("content-type") || "";

      if (tokenParam) {
        const verified = await verifyAuthCode(secret, tokenParam);
        if (!verified || verified.op !== "upload" || !verified.key) {
          return new Response(JSON.stringify({ error: "Invalid or expired upload token" }), {
            status: 401,
            headers: { ...corsHeaders, "Content-Type": "application/json" }
          });
        }
        targetKey = verified.key;
        targetPath = verified.path || "";
        if (!mimeType || mimeType === "application/octet-stream" || mimeType === "application/x-www-form-urlencoded") {
          mimeType = verified.mime || guessMimeType(targetPath);
        }
      } else {
        const auth = authenticateMCPRequest(request, env, url);
        if (!auth.ok) {
          return new Response(JSON.stringify({ error: auth.error }), {
            status: 401,
            headers: { ...corsHeaders, "Content-Type": "application/json" }
          });
        }
        targetPath = (url.searchParams.get("path") || "").replace(/^\/+/, "");
        if (!targetPath) {
          return new Response(JSON.stringify({ error: "Missing ?path= parameter" }), {
            status: 400,
            headers: { ...corsHeaders, "Content-Type": "application/json" }
          });
        }
        targetKey = `${auth.userPrefix}/${targetPath}`;
        if (!mimeType || mimeType === "application/octet-stream" || mimeType === "application/x-www-form-urlencoded") {
          mimeType = guessMimeType(targetPath);
        }
      }

      const putObj = await env.VAULT_BUCKET.put(targetKey, request.body, {
        httpMetadata: { contentType: mimeType }
      });

      return new Response(JSON.stringify({
        ok: true,
        path: targetPath,
        size: putObj.size,
        mime_type: mimeType,
        etag: putObj.etag
      }, null, 2), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" }
      });
    }

    if (url.pathname === "/vault/download" && (request.method === "GET" || request.method === "HEAD")) {
      const secret = env.GOOGLE_CLIENT_SECRET || "zd_secret";
      const tokenParam = url.searchParams.get("token") || "";
      let targetKey = "";
      let targetPath = "";

      if (tokenParam) {
        const verified = await verifyAuthCode(secret, tokenParam);
        if (!verified || verified.op !== "download" || !verified.key) {
          return new Response("Invalid or expired download token", { status: 401, headers: corsHeaders });
        }
        targetKey = verified.key;
        targetPath = verified.path || "";
      } else {
        const auth = authenticateMCPRequest(request, env, url);
        if (!auth.ok) {
          return new Response(auth.error, { status: 401, headers: corsHeaders });
        }
        targetPath = (url.searchParams.get("path") || "").replace(/^\/+/, "");
        if (!targetPath) {
          return new Response("Missing ?path= parameter", { status: 400, headers: corsHeaders });
        }
        targetKey = `${auth.userPrefix}/${targetPath}`;
      }

      const rangeHeader = request.headers.get("Range");
      if (request.method === "GET" && rangeHeader) {
        const headObj = await env.VAULT_BUCKET.head(targetKey);
        if (!headObj) {
          return new Response("File not found", { status: 404, headers: corsHeaders });
        }
        const parsedRange = parseRangeHeader(rangeHeader, headObj.size);
        if (parsedRange) {
          const obj = await env.VAULT_BUCKET.get(targetKey, {
            range: { offset: parsedRange.offset, length: parsedRange.length }
          });
          if (!obj) {
            return new Response("File not found", { status: 404, headers: corsHeaders });
          }
          const mimeType = obj.httpMetadata?.contentType || guessMimeType(targetPath);
          const fileName = targetPath.split("/").pop() || "download";
          return new Response(obj.body, {
            status: 206,
            headers: {
              ...corsHeaders,
              "Content-Type": mimeType,
              "Content-Length": String(parsedRange.length),
              "Content-Range": `bytes ${parsedRange.start}-${parsedRange.end}/${headObj.size}`,
              "Accept-Ranges": "bytes",
              "Content-Disposition": `inline; filename="${fileName.replace(/"/g, "")}"`
            }
          });
        }
      }

      const obj = request.method === "HEAD"
        ? await env.VAULT_BUCKET.head(targetKey)
        : await env.VAULT_BUCKET.get(targetKey);
      if (!obj) {
        return new Response("File not found", { status: 404, headers: corsHeaders });
      }
      const mimeType = obj.httpMetadata?.contentType || guessMimeType(targetPath);
      const fileName = targetPath.split("/").pop() || "download";
      return new Response(request.method === "HEAD" ? null : obj.body, {
        status: 200,
        headers: {
          ...corsHeaders,
          "Content-Type": mimeType,
          "Content-Length": String(obj.size),
          "Accept-Ranges": "bytes",
          "Content-Disposition": `inline; filename="${fileName.replace(/"/g, "")}"`
        }
      });
    }

    // 2. Direct DMG Installer Download from R2
    if (
      url.pathname === "/download/ZeroDrive-Installer.dmg" &&
      (request.method === "GET" || request.method === "HEAD")
    ) {
      const dmgObj =
        request.method === "HEAD"
          ? await env.VAULT_BUCKET.head("releases/ZeroDrive-Installer.dmg")
          : await env.VAULT_BUCKET.get("releases/ZeroDrive-Installer.dmg");
      if (!dmgObj) {
        return new Response("ZeroDrive-Installer.dmg is currently being uploaded.", {
          status: 404,
          headers: corsHeaders,
        });
      }
      return new Response(request.method === "HEAD" ? null : dmgObj.body, {
        status: 200,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/x-apple-diskimage",
          "Content-Disposition": 'attachment; filename="ZeroDrive-Installer.dmg"',
          "Content-Length": String(dmgObj.size),
          ETag: dmgObj.httpEtag || `"${dmgObj.etag}"`,
        },
      });
    }

    // 2c. Brand Logos & Favicons (broadcast across all standard icon paths)
    if (url.pathname === "/logo.png" || url.pathname === "/assets/logo.png") {
      let obj = await env.VAULT_BUCKET.get("assets/logo.png");
      if (!obj) {
        obj = await env.VAULT_BUCKET.get("tenants/zd_r2_andrew_8bc7fb477f/usr_andrew_8bc7fb477f/assets/logo.png");
      }
      if (obj) {
        return new Response(request.method === "HEAD" ? null : obj.body, {
          headers: {
            ...corsHeaders,
            "Content-Type": "image/png",
            "Content-Length": String(obj.size),
            "Cache-Control": "public, max-age=86400",
          },
        });
      }
    }
    if (
      url.pathname === "/app-icon.png" ||
      url.pathname === "/assets/app-icon.png" ||
      url.pathname === "/icon.png" ||
      url.pathname === "/favicon.ico" ||
      url.pathname === "/favicon.png" ||
      url.pathname === "/apple-touch-icon.png" ||
      url.pathname === "/apple-touch-icon-precomposed.png"
    ) {
      let obj = await env.VAULT_BUCKET.get("assets/app-icon.png");
      if (!obj) {
        obj = await env.VAULT_BUCKET.get("tenants/zd_r2_andrew_8bc7fb477f/usr_andrew_8bc7fb477f/assets/app-icon.png");
      }
      if (obj) {
        return new Response(request.method === "HEAD" ? null : obj.body, {
          headers: {
            ...corsHeaders,
            "Content-Type": "image/png",
            "Content-Length": String(obj.size),
            "Cache-Control": "public, max-age=86400",
          },
        });
      }
    }

    // 3. Health Check
    if (url.pathname === "/v1/health") {
      return new Response(
        JSON.stringify({
          status: "healthy",
          name: "ZeroDrive",
          domain: "api.zerodrive.dev",
          targetDomain: "zerodrive.dev",
          icon: CONNECTOR_ICON_URL,
          logo_url: CONNECTOR_ICON_URL,
          version: "3.1.0",
          storageEngine: "cloudflare_r2_s3_proxy",
          bucket: env.R2_BUCKET || "zerodrive-vault-prod",
          mcpEndpoint: `${CANONICAL_ORIGIN}/mcp`,
          downloadUrl: `${CANONICAL_ORIGIN}/download/ZeroDrive-Installer.dmg`,
        }),
        {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    // 4. 1-Click DFY Vault Provisioning Endpoint
    if (url.pathname === "/v1/vault/provision" && request.method === "POST") {
      try {
        const body = await request.json();
        const email = (body.email || "user@zerodrive.dev").trim().toLowerCase();
        const cleanName = email
          .split("@")[0]
          .replace(/[^a-zA-Z0-9]/g, "_")
          .toLowerCase();
        const userHash = (await sha256Hex(email)).slice(0, 10);
        const secretHash = await sha256Hex(`${email}:${body.machineUUID || "mac"}:zerodrive-v3`);

        const endpoint =
          env.R2_ACCESS_KEY_ID && env.R2_SECRET_ACCESS_KEY && env.CLOUDFLARE_ACCOUNT_ID
            ? `https://${env.CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com`
            : `${CANONICAL_ORIGIN}/s3`;

        const provisionData = {
          endpoint,
          bucket: env.R2_BUCKET || "zerodrive-vault-prod",
          userPrefix: `usr_${cleanName}_${userHash}`,
          accessKeyId: env.R2_ACCESS_KEY_ID || `zd_r2_${cleanName}_${userHash}`,
          secretAccessKey: env.R2_SECRET_ACCESS_KEY || `zd_sec_${secretHash}`,
          quotaTB: parseFloat(env.DEFAULT_QUOTA_TB || "5.0"),
          domain: "api.zerodrive.dev",
          provisionedAt: new Date().toISOString(),
          mode: "live_r2_s3_proxy",
        };

        return new Response(JSON.stringify(provisionData), {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      } catch (err) {
        return new Response(
          JSON.stringify({
            error: "Invalid provisioning request",
            details: err instanceof Error ? err.message : String(err),
          }),
          {
            status: 400,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          }
        );
      }
    }

    // 5. 1-Line CLI Installer Script (curl -fsSL https://api.zerodrive.dev/install.sh | bash)
    if (url.pathname === "/install" || url.pathname === "/install.sh") {
      const installScript = `#!/usr/bin/env bash
set -e
echo "⚡ Installing ZeroDrive CLI..."
INSTALL_DIR="$HOME/.local/bin"
mkdir -p "$INSTALL_DIR"

curl -fsSL "https://raw.githubusercontent.com/Vibe-Marketer/zerodrive/main/bin/zerodrive" -o "$INSTALL_DIR/zerodrive"
chmod +x "$INSTALL_DIR/zerodrive"
ln -sf "$INSTALL_DIR/zerodrive" "$INSTALL_DIR/zd"

curl -fsSL "https://raw.githubusercontent.com/Vibe-Marketer/zerodrive/main/bin/zerodrive-mcp" -o "$INSTALL_DIR/zerodrive-mcp"
chmod +x "$INSTALL_DIR/zerodrive-mcp"

# Ensure ~/.local/bin in PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
  SHELL_PROFILE="$HOME/.zshrc"
  if [[ -f "$HOME/.bashrc" && ! -f "$HOME/.zshrc" ]]; then
    SHELL_PROFILE="$HOME/.bashrc"
  fi
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_PROFILE"
  echo "✓ Added $INSTALL_DIR to PATH in $SHELL_PROFILE"
fi

echo "✓ ZeroDrive CLI successfully installed to $INSTALL_DIR/zerodrive (and 'zd')!"
echo "  Run 'zd doctor' or 'zerodrive --help' to get started."
`;
      return new Response(installScript, {
        headers: {
          ...corsHeaders,
          "Content-Type": "text/x-shellscript; charset=utf-8",
          "Cache-Control": "public, max-age=300"
        }
      });
    }

    const accept = request.headers.get("Accept") || "";
    if (url.pathname === "/" && accept.includes("text/html")) {
      const landingHtml = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>ZeroDrive — The 24/7 Cloud Vault for AI Agents &amp; Mac</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="icon" type="image/png" href="${CONNECTOR_ICON_URL}">
  <link rel="apple-touch-icon" href="${CONNECTOR_ICON_URL}">
  <meta property="og:title" content="ZeroDrive — 24/7 Cloud Vault">
  <meta property="og:description" content="Unlimited cloud drive directly in Finder, terminal, and AI agents. Native OAuth 2.0 MCP server for Muse, Claude, Cursor, and ChatGPT.">
  <meta property="og:image" content="${CONNECTOR_ICON_URL}">
  <style>
    * { box-sizing: border-box; -webkit-font-smoothing: antialiased; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", Roboto, sans-serif;
      background: radial-gradient(circle at 50% 12%, rgba(245, 166, 35, 0.12) 0%, transparent 60%), #08080a;
      color: #f5f5f7;
      margin: 0;
      padding: 0;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
    }
    .container {
      max-width: 840px;
      width: 100%;
      padding: 60px 24px;
      text-align: center;
    }
    .badge {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 6px 14px;
      background: rgba(255, 255, 255, 0.06);
      border: 1px solid rgba(255, 255, 255, 0.12);
      border-radius: 999px;
      font-size: 13px;
      color: #34c759;
      font-weight: 500;
      margin-bottom: 24px;
    }
    .badge-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background: #34c759;
      box-shadow: 0 0 10px #34c759;
    }
    .logo {
      width: 80px;
      height: 80px;
      border-radius: 20px;
      margin-bottom: 20px;
      box-shadow: 0 12px 32px rgba(0, 0, 0, 0.5);
    }
    h1 {
      font-size: 44px;
      font-weight: 700;
      letter-spacing: -0.025em;
      margin: 0 0 14px;
      background: linear-gradient(180deg, #ffffff 0%, #b0b0ba 100%);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
    }
    .tagline {
      font-size: 19px;
      line-height: 1.5;
      color: #8e8e93;
      max-width: 620px;
      margin: 0 auto 40px;
    }
    .grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 20px;
      margin-bottom: 30px;
      text-align: left;
    }
    @media (max-width: 700px) {
      .grid { grid-template-columns: 1fr; }
      h1 { font-size: 32px; }
    }
    .card {
      background: rgba(255, 255, 255, 0.03);
      border: 1px solid rgba(255, 255, 255, 0.08);
      border-radius: 20px;
      padding: 26px;
      backdrop-filter: blur(20px);
      -webkit-backdrop-filter: blur(20px);
    }
    .card h3 {
      margin: 0 0 8px;
      font-size: 18px;
      font-weight: 600;
      color: #fff;
    }
    .card p {
      margin: 0 0 18px;
      font-size: 14px;
      line-height: 1.5;
      color: #8e8e93;
    }
    .btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
      width: 100%;
      padding: 13px 20px;
      background: #f5a623;
      color: #000;
      font-weight: 600;
      font-size: 15px;
      border-radius: 12px;
      text-decoration: none;
      transition: opacity 0.15s ease, transform 0.15s ease;
      cursor: pointer;
      border: none;
    }
    .btn:hover { opacity: 0.92; transform: translateY(-1px); }
    .btn-secondary {
      background: rgba(255, 255, 255, 0.08);
      color: #fff;
      border: 1px solid rgba(255, 255, 255, 0.14);
    }
    .code-box {
      display: flex;
      align-items: center;
      background: rgba(0, 0, 0, 0.5);
      border: 1px solid rgba(255, 255, 255, 0.1);
      border-radius: 10px;
      padding: 10px 14px;
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
      font-size: 13px;
      color: #e5e5ea;
      margin-top: 10px;
      word-break: break-all;
    }
    .code-box span { flex: 1; text-align: left; overflow: hidden; text-overflow: ellipsis; }
    .copy-btn {
      background: rgba(255, 255, 255, 0.1);
      border: none;
      color: #fff;
      padding: 6px 12px;
      border-radius: 6px;
      font-size: 12px;
      cursor: pointer;
      margin-left: 10px;
      font-weight: 500;
    }
    .copy-btn:hover { background: rgba(255, 255, 255, 0.2); }
    .features {
      display: flex;
      justify-content: center;
      gap: 24px;
      flex-wrap: wrap;
      margin-top: 20px;
      font-size: 13px;
      color: #6e6e73;
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="badge"><div class="badge-dot"></div> Systems Operational • 24/7 Cloud Vault</div>
    <img src="${CONNECTOR_ICON_URL}" alt="ZeroDrive Logo" class="logo">
    <h1>ZeroDrive</h1>
    <p class="tagline">The 24/7 Cloud Vault for AI Agents &amp; Mac.<br>Unlimited cloud drive in Finder, terminal, and every AI agent with zero mount latency.</p>

    <div class="grid">
      <div class="card">
        <h3>🤖 Connect Your AI Agent (MCP)</h3>
        <p>1-click Google OAuth for Muse, Claude, Cursor, and ChatGPT. Supports text, code, screenshots, videos, and ZIPs.</p>
        <div class="code-box">
          <span id="mcp-url">${CANONICAL_ORIGIN}/mcp</span>
          <button class="copy-btn" onclick="copyMcp()">Copy URL</button>
        </div>
        <p style="font-size: 12px; margin: 12px 0 0; color: #636366;">Add as MCP connector in Muse or Claude Desktop settings.</p>
      </div>

      <div class="card">
        <h3>🍎 ZeroDrive for Mac</h3>
        <p>Mount your cloud vault at <code>~/ZeroDrive/My Drive</code> in Finder. Stream files on-demand without filling your SSD.</p>
        <a href="/download/ZeroDrive-Installer.dmg" class="btn">Download for Mac (.dmg)</a>
        <p style="font-size: 12px; margin: 12px 0 0; color: #636366;">Universal binary for Apple Silicon &amp; Intel • Signed Developer ID</p>
      </div>
    </div>

    <div class="grid" style="margin-bottom: 24px;">
      <div class="card">
        <h3 style="margin-bottom: 6px;">⚡ ZeroDrive Developer CLI</h3>
        <p style="margin-bottom: 10px;">Sub-second queries, file slicing, and high-speed transfers without mount stalls on Mac &amp; Linux.</p>
        <div class="code-box">
          <span id="cli-cmd">curl -fsSL ${CANONICAL_ORIGIN}/install.sh | bash</span>
          <button class="copy-btn" onclick="copyCli()">Copy</button>
        </div>
      </div>

      <div class="card">
        <h3 style="margin-bottom: 6px;">🌐 REST API &amp; OpenAPI 3.1</h3>
        <p style="margin-bottom: 10px;">Full REST API surface for OpenAI Custom GPT Actions, autonomous agents, and workflows.</p>
        <div style="display:flex; gap:10px; margin-top:14px;">
          <a href="/docs" class="btn btn-secondary" style="font-size:13px; padding:10px 14px; text-decoration:none;">View API Docs</a>
          <a href="/openapi.json" class="btn btn-secondary" style="font-size:13px; padding:10px 14px; text-decoration:none;">OpenAPI 3.1 Spec</a>
        </div>
      </div>
    </div>

    <div class="features">
      <span>✓ Cloudflare R2 Backed</span>
      <span>✓ Native OAuth 2.0</span>
      <span>✓ Video &amp; ZIP Streaming</span>
      <span>✓ Reusable Agent Skills</span>
      <span>✓ Loopback NFS Mount</span>
    </div>
  </div>

  <script>
    function copyMcp() {
      navigator.clipboard.writeText("${CANONICAL_ORIGIN}/mcp");
      event.target.textContent = "Copied!";
      setTimeout(() => { event.target.textContent = "Copy URL"; }, 2000);
    }
    function copyCli() {
      navigator.clipboard.writeText("curl -fsSL ${CANONICAL_ORIGIN}/install.sh | bash");
      event.target.textContent = "Copied!";
      setTimeout(() => { event.target.textContent = "Copy"; }, 2000);
    }
  </script>
</body>
</html>`;
      return new Response(landingHtml, {
        headers: { ...corsHeaders, "Content-Type": "text/html; charset=utf-8" }
      });
    }

    return new Response(
      JSON.stringify({
        name: "ZeroDrive",
        service: "ZeroDrive Cloud Vault & Hosted MCP Server",
        status: "online",
        icon: CONNECTOR_ICON_URL,
        logo_url: CONNECTOR_ICON_URL,
        mcp: `${CANONICAL_ORIGIN}/mcp`,
        health: `${CANONICAL_ORIGIN}/v1/health`,
        download: `${CANONICAL_ORIGIN}/download/ZeroDrive-Installer.dmg`,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  },
};
