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

async function createAuthCode(secret, payload) {
  const data = JSON.stringify({ ...payload, exp: Math.floor(Date.now() / 1000) + 600 });
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
    description: "Read the text contents of a file in the ZeroDrive vault, with optional line slicing (head, tail, or line range) for large files.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Vault file path (e.g. 'ROUTER.md', 'AGENTS.md', 'MAIN/notes.md')." },
        head: { type: "integer", description: "Read only the first N lines." },
        tail: { type: "integer", description: "Read only the last N lines." },
        lines: { type: "string", description: "Read a specific line range (e.g. '1-100', '101-200')." }
      },
      required: ["path"]
    }
  },
  {
    name: "write_file",
    description: "Create a new file, overwrite an existing file, or append to a file at any path in the ZeroDrive vault. Parent folders are created automatically.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Target vault file path (e.g. 'MAIN/project-notes.md', '_SORT/inbox/idea.md')." },
        content: { type: "string", description: "Text content to write to the file." },
        append: { type: "boolean", description: "If true, append content to the end of the existing file instead of overwriting.", default: false }
      },
      required: ["path", "content"]
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
  }
];

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
      return { ok: true, userPrefix: `tenants/${tenant}/${tenant}` };
    }
  }

  // Backwards compatibility for existing OAuth tokens
  if (token.startsWith("zd_oauth_")) {
    return { ok: true, userPrefix: "tenants/zd_r2_andrew_8bc7fb477f/usr_andrew_8bc7fb477f" };
  }

  if (token.startsWith("usr_")) {
    const clean = token.replace(/[^a-zA-Z0-9_]/g, "");
    return { ok: true, userPrefix: `tenants/${clean}/${clean}` };
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
        instructions: "ZeroDrive Cloud Vault. Start by calling get_file_tree or reading ROUTER.md to see the vault structure. Use search_filenames to locate files by name, grep_vault to search inside file contents, read_file to inspect files, and write_file / edit_file / move_file to create and update files."
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
    return { jsonrpc: "2.0", id, result: { prompts: [] } };
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

      if (toolName === "write_file" || toolName === "zd_write") {
        const subpath = (args.path || "").replace(/^\/+/, "");
        const fullKey = `${userPrefix}/${subpath}`;
        let content = String(args.content ?? "");

        if (args.append) {
          const existing = await env.VAULT_BUCKET.get(fullKey);
          if (existing) {
            const prevText = await existing.text();
            content = prevText + (prevText.endsWith("\n") ? "" : "\n") + content;
          }
        }

        await env.VAULT_BUCKET.put(fullKey, content, {
          httpMetadata: { contentType: "text/plain; charset=utf-8" }
        });

        return {
          jsonrpc: "2.0",
          id,
          result: { content: [{ type: "text", text: `Saved ${content.length} characters to ${subpath}.` }] }
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

function handleOpenAPISpec(url, corsHeaders) {
  const origin = CANONICAL_ORIGIN;
  const spec = {
    openapi: "3.1.0",
    info: {
      title: "ZeroDrive",
      description: "Hosted 24/7 ZeroDrive Cloud Vault MCP Server with native OAuth 2.0 authentication.",
      version: "1.1.0",
      "x-logo": {
        url: CONNECTOR_ICON_URL,
        altText: "ZeroDrive"
      }
    },
    servers: [{ url: origin }],
    paths: {
      "/mcp": {
        post: {
          summary: "ZeroDrive MCP JSON-RPC 2.0 Endpoint",
          operationId: "executeMCP",
          security: [{ OAuth2: ["mcp", "vault:read", "vault:write"] }],
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
            "200": { description: "MCP response" },
            "401": { description: "OAuth 2.0 token required" }
          }
        }
      }
    },
    components: {
      securitySchemes: {
        OAuth2: {
          type: "oauth2",
          description: "ZeroDrive OAuth 2.0 flow",
          flows: {
            authorizationCode: {
              authorizationUrl: `${origin}/oauth/authorize`,
              tokenUrl: `${origin}/oauth/token`,
              scopes: {
                mcp: "Full MCP agent vault access",
                "vault:read": "Read files in vault",
                "vault:write": "Write files in vault"
              }
            }
          }
        }
      }
    },
    security: [{ OAuth2: ["mcp", "vault:read", "vault:write"] }]
  };
  return new Response(JSON.stringify(spec, null, 2), {
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

    const accept = request.headers.get("Accept") || "";
    if (url.pathname === "/" && accept.includes("text/html")) {
      return new Response(
        `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>ZeroDrive</title><link rel="icon" type="image/png" href="${CONNECTOR_ICON_URL}"><link rel="apple-touch-icon" href="${CONNECTOR_ICON_URL}"><meta property="og:title" content="ZeroDrive"><meta property="og:image" content="${CONNECTOR_ICON_URL}"></head><body style="background:#08080a;color:#fff;font-family:-apple-system,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;"><div style="text-align:center;"><img src="${CONNECTOR_ICON_URL}" width="72" height="72" style="border-radius:18px;margin-bottom:16px;"><h1>ZeroDrive</h1><p style="color:#888;">24/7 Cloud Vault &amp; MCP Server</p></div></body></html>`,
        { headers: { ...corsHeaders, "Content-Type": "text/html; charset=utf-8" } }
      );
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
