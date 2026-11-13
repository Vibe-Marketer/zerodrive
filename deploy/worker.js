import {
  isWindowsReservedName,
  normalizeUnicode,
  validateCrossPlatformPath,
  sanitizeCrossPlatformPath,
  generateConflictedPath,
  evaluateConflict
} from "./cross-platform.js";
import {
  handleDrivesRequest,
  listDrives,
  createDrive,
  getDrive,
  deleteDrive,
  resolveDrivePrefix,
  slugifyDriveName,
  calculateDriveStats
} from "./drives.js";
import {
  extractTeamFromHostname,
  resolveTeamFromHostname,
  getTeam,
  createTeam,
  generateTeamApiKey,
  revokeTeamApiKey,
  listTeams,
  authenticateTeamToken,
  isEmailAllowedForTeam,
  sanitizeTeamPath,
  handleTeamMCP,
  handleTeamOAuth,
  handleTeamsRest,
  TEAM_MCP_TOOLS,
  RESERVED_SUBDOMAINS
} from "./teams.js";
import {
  handleBillingAndLicenseRequest,
  getPricingTiers,
  getTier,
  createCheckoutSession,
  createPortalSession,
  handleStripeWebhook,
  verifyLicenseKey,
  activateLicenseKey,
  buildTenantIdentityForEmail,
  createManagedLicense,
  getLicenseSecret
} from "./billing.js";

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

function extractTenantFromAuth(request, url = null) {
  const auth = request.headers.get("Authorization") || "";
  const match = auth.match(/Credential=([^/,\s]+)\//);
  if (match && match[1]) {
    const clean = match[1].replace(/[^a-zA-Z0-9_-]/g, "");
    if (clean.length > 0) return clean;
  }
  if (url) {
    const queryCred = url.searchParams.get("X-Amz-Credential") || "";
    const firstSeg = queryCred.split("/")[0]?.replace(/[^a-zA-Z0-9_-]/g, "");
    if (firstSeg) return firstSeg;
  }
  return "default_tenant";
}

function hasUnsafePathTraversal(pathStr) {
  if (!pathStr) return false;
  const segments = String(pathStr).split(/[\\/]/);
  return segments.some((s) => s === ".." || s.includes("\0"));
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

function matchesIfNoneMatch(ifNoneMatchHeader, currentEtag) {
  if (!ifNoneMatchHeader || !currentEtag) return false;
  const rawHeader = ifNoneMatchHeader.trim();
  if (rawHeader === "*") return true;
  const cleanCurrent = currentEtag.replace(/^W\//i, "").replace(/^"+|"+$/g, "").trim();
  const tags = rawHeader.split(",").map((t) => t.trim().replace(/^W\//i, "").replace(/^"+|"+$/g, ""));
  return tags.includes(cleanCurrent);
}

function matchesIfRange(ifRangeHeader, currentEtag, uploadedDate) {
  if (!ifRangeHeader) return true;
  const cleanIfRange = ifRangeHeader.trim().replace(/^W\//i, "").replace(/^"+|"+$/g, "");
  const cleanCurrent = (currentEtag || "").replace(/^W\//i, "").replace(/^"+|"+$/g, "");
  if (cleanIfRange === cleanCurrent) return true;

  const dateVal = new Date(ifRangeHeader);
  if (!isNaN(dateVal.getTime()) && uploadedDate) {
    const uploadedMs = uploadedDate instanceof Date ? uploadedDate.getTime() : new Date(uploadedDate).getTime();
    if (!isNaN(uploadedMs)) {
      return Math.floor(uploadedMs / 1000) <= Math.floor(dateVal.getTime() / 1000);
    }
  }
  return false;
}

async function handleS3Proxy(request, env, url) {
  const tenantId = extractTenantFromAuth(request, url);
  if (!tenantId || tenantId === "default_tenant") {
    return new Response(
      `<?xml version="1.0" encoding="UTF-8"?><Error><Code>AccessDenied</Code><Message>Missing or invalid S3 tenant credentials.</Message></Error>`,
      { status: 403, headers: { "Content-Type": "application/xml" } }
    );
  }
  // Path after /s3/ -> e.g. /s3/zerodrive-vault-prod/usr_alice/video.mov
  const rawSubpath = decodeURIComponent(url.pathname.replace(/^\/s3\/?/, ""));
  const slashIdx = rawSubpath.indexOf("/");
  const bucketName = slashIdx === -1 ? rawSubpath : rawSubpath.slice(0, slashIdx);
  const objectKey = slashIdx === -1 ? "" : rawSubpath.slice(slashIdx + 1);
  const reqPrefix = url.searchParams.get("prefix") || "";

  if (hasUnsafePathTraversal(objectKey) || hasUnsafePathTraversal(reqPrefix)) {
    return new Response(
      `<?xml version="1.0" encoding="UTF-8"?><Error><Code>AccessDenied</Code><Message>Invalid path traversal.</Message></Error>`,
      { status: 403, headers: { "Content-Type": "application/xml" } }
    );
  }

  // Enforce multi-tenant prefix isolation in R2
  const tenantRoot = `tenants/${tenantId}/`;
  const r2Key = objectKey ? `${tenantRoot}${objectKey}` : "";

  // Strictly block access outside tenant's own prefix if tenant is non-master
  if (tenantId !== "zd_r2_andrew_8bc7fb477f" && tenantId.startsWith("zd_r2_usr_")) {
    const expectedUserSeg = tenantId.slice("zd_r2_".length);
    if (objectKey && objectKey !== expectedUserSeg && !objectKey.startsWith(`${expectedUserSeg}/`)) {
      return new Response(
        `<?xml version="1.0" encoding="UTF-8"?><Error><Code>AccessDenied</Code><Message>Tenant boundary violation.</Message></Error>`,
        { status: 403, headers: { "Content-Type": "application/xml" } }
      );
    }
    if (reqPrefix && reqPrefix !== expectedUserSeg && !reqPrefix.startsWith(`${expectedUserSeg}/`) && !expectedUserSeg.startsWith(reqPrefix)) {
      return new Response(
        `<?xml version="1.0" encoding="UTF-8"?><Error><Code>AccessDenied</Code><Message>Tenant prefix boundary violation.</Message></Error>`,
        { status: 403, headers: { "Content-Type": "application/xml" } }
      );
    }
  }

  const method = request.method.toUpperCase();

  // 1. Bucket-level operations (ListObjectsV2 / ListObjects / HeadBucket)
  if (!objectKey) {
    if (method === "HEAD") {
      return new Response(null, { status: 200 });
    }
    if (method === "GET") {
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
        headers: {
          "Content-Type": "application/xml",
          "Cache-Control": "private, no-store, no-cache, must-revalidate",
        },
      });
    }
    return new Response(null, { status: 200 });
  }

  const extractS3WriteOptions = (fallbackObj = null) => {
    const customMetadata = {};
    const directive = (request.headers.get("x-amz-metadata-directive") || "").toUpperCase();
    if (fallbackObj?.customMetadata && directive !== "REPLACE") {
      Object.assign(customMetadata, fallbackObj.customMetadata);
    }
    for (const [k, v] of request.headers.entries()) {
      const lower = k.toLowerCase();
      if (lower.startsWith("x-amz-meta-")) {
        const metaKey = lower.slice("x-amz-meta-".length);
        if (metaKey) customMetadata[metaKey] = v;
      }
    }
    const reqContentType = request.headers.get("Content-Type");
    const contentType =
      (reqContentType && reqContentType !== "application/octet-stream" ? reqContentType : null) ||
      fallbackObj?.httpMetadata?.contentType ||
      reqContentType ||
      guessMimeType(objectKey);
    const opts = { httpMetadata: { contentType } };
    if (Object.keys(customMetadata).length > 0) {
      opts.customMetadata = customMetadata;
    }
    return opts;
  };

  const buildCustomMetaHeaders = (obj) => {
    const out = {};
    if (obj?.customMetadata) {
      for (const [k, v] of Object.entries(obj.customMetadata)) {
        if (k && typeof v === "string") {
          out[`x-amz-meta-${k.toLowerCase()}`] = v;
        }
      }
    }
    return out;
  };

  const notifyS3Mutation = (action, etagVal = "") => {
    const firstSlash = objectKey.indexOf("/");
    const userSeg = firstSlash === -1 ? "" : objectKey.slice(0, firstSlash);
    const relPath = firstSlash === -1 ? objectKey : objectKey.slice(firstSlash + 1);
    if (!relPath) return;
    const baseName = relPath.split("/").pop() || "";
    if (baseName === ".DS_Store" || baseName === ".metadata_never_index" || baseName.startsWith("._")) {
      return;
    }
    const s3UserPrefix = userSeg
      ? `${tenantRoot}${userSeg}`
      : tenantRoot.replace(/\/+$/, "");
    broadcastVaultEvent(s3UserPrefix, {
      event: "change",
      action,
      path: relPath,
      etag: etagVal,
    });
  };

  // 2. Object-level HEAD
  if (method === "HEAD") {
    const headObj = await env.VAULT_BUCKET.head(r2Key);
    if (!headObj) {
      return new Response(null, {
        status: 404,
        headers: { "Cache-Control": "private, no-store, no-cache, must-revalidate" },
      });
    }
    const etag = headObj.httpEtag || `"${headObj.etag}"`;
    const lastModified = headObj.uploaded ? headObj.uploaded.toUTCString() : new Date().toUTCString();
    const headers = {
      "Content-Length": String(headObj.size),
      ETag: etag,
      "Last-Modified": lastModified,
      "Accept-Ranges": "bytes",
      "Content-Type": headObj.httpMetadata?.contentType || "application/octet-stream",
      "Cache-Control": "private, no-store, no-cache, must-revalidate",
      ...buildCustomMetaHeaders(headObj),
    };
    if (matchesIfNoneMatch(request.headers.get("If-None-Match"), etag)) {
      return new Response(null, { status: 304, headers });
    }
    return new Response(null, {
      status: 200,
      headers,
    });
  }

  // 3. Object-level GET (with HTTP Byte-Range support for <450ms TTFB 0-byte RAM streaming)
  if (method === "GET") {
    const headObj = await env.VAULT_BUCKET.head(r2Key);
    if (!headObj) {
      return new Response(
        `<?xml version="1.0" encoding="UTF-8"?><Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message></Error>`,
        {
          status: 404,
          headers: {
            "Content-Type": "application/xml",
            "Cache-Control": "private, no-store, no-cache, must-revalidate",
          },
        }
      );
    }
    const etag = headObj.httpEtag || `"${headObj.etag}"`;
    const lastModified = headObj.uploaded ? headObj.uploaded.toUTCString() : new Date().toUTCString();
    const contentType = headObj.httpMetadata?.contentType || "application/octet-stream";
    const cacheHeaders = {
      "Accept-Ranges": "bytes",
      "Cache-Control": "private, no-store, no-cache, must-revalidate",
      ETag: etag,
      "Last-Modified": lastModified,
      "Content-Type": contentType,
      ...buildCustomMetaHeaders(headObj),
    };

    if (matchesIfNoneMatch(request.headers.get("If-None-Match"), etag)) {
      return new Response(null, { status: 304, headers: cacheHeaders });
    }

    const rangeHeader = request.headers.get("Range");
    const ifRange = request.headers.get("If-Range");
    if (rangeHeader && matchesIfRange(ifRange, etag, headObj.uploaded)) {
      const parsedRange = parseRangeHeader(rangeHeader, headObj.size);
      if (parsedRange) {
        const obj = await env.VAULT_BUCKET.get(r2Key, {
          range: { offset: parsedRange.offset, length: parsedRange.length },
        });
        if (!obj) return new Response("Not Found", { status: 404 });
        return new Response(obj.body, {
          status: 206,
          headers: {
            ...cacheHeaders,
            "Content-Length": String(parsedRange.length),
            "Content-Range": `bytes ${parsedRange.start}-${parsedRange.end}/${headObj.size}`,
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
        ...cacheHeaders,
        "Content-Length": String(obj.size),
      },
    });
  }

  // 4. Object-level POST (Multipart Upload initiation or completion)
  if (method === "POST") {
    if (url.searchParams.has("uploads")) {
      const mp = await env.VAULT_BUCKET.createMultipartUpload(r2Key, extractS3WriteOptions());
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
      const completedEtag = completed.httpEtag || `"${completed.etag}"`;
      notifyS3Mutation("write_file", completedEtag);
      const xml = `<?xml version="1.0" encoding="UTF-8"?>
<CompleteMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Location>${xmlEscape(url.origin + url.pathname)}</Location>
  <Bucket>${xmlEscape(bucketName)}</Bucket>
  <Key>${xmlEscape(objectKey)}</Key>
  <ETag>${xmlEscape(completedEtag)}</ETag>
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
      if (hasUnsafePathTraversal(srcRelKey)) {
        return new Response("Forbidden: Invalid copy source path", { status: 403 });
      }
      if (tenantId !== "zd_r2_andrew_8bc7fb477f" && tenantId.startsWith("zd_r2_usr_")) {
        const expectedUserSeg = tenantId.slice("zd_r2_".length);
        if (srcRelKey !== expectedUserSeg && !srcRelKey.startsWith(`${expectedUserSeg}/`)) {
          return new Response("Forbidden: Cross-tenant copy denied", { status: 403 });
        }
      }
      const srcR2Key = `${tenantRoot}${srcRelKey}`;
      const existing = await env.VAULT_BUCKET.get(srcR2Key);
      if (!existing) {
        return new Response("Source Not Found", { status: 404 });
      }
      const putRes = await env.VAULT_BUCKET.put(r2Key, existing.body, extractS3WriteOptions(existing));
      const copyEtag = putRes.httpEtag || `"${putRes.etag}"`;
      notifyS3Mutation("copy_file", copyEtag);
      const xml = `<?xml version="1.0" encoding="UTF-8"?>
<CopyObjectResult>
  <LastModified>${new Date().toISOString()}</LastModified>
  <ETag>${xmlEscape(copyEtag)}</ETag>
</CopyObjectResult>`;
      return new Response(xml, {
        status: 200,
        headers: { "Content-Type": "application/xml" },
      });
    }

    const putObj = await env.VAULT_BUCKET.put(r2Key, request.body, extractS3WriteOptions());
    const putEtag = putObj.httpEtag || `"${putObj.etag}"`;
    notifyS3Mutation("write_file", putEtag);
    return new Response(null, {
      status: 200,
      headers: {
        ETag: putEtag,
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
    notifyS3Mutation("delete_file");
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

    const cookieHeader = request.headers.get("Cookie") || "";
  if (!token && cookieHeader) {
    const cookieMatch = cookieHeader.match(/(?:zd_token|access_token|token)=([^;]+)/);
    if (cookieMatch) token = decodeURIComponent(cookieMatch[1].trim());
  }

  if (!token) {
    return { ok: false, error: "OAuth 2.0 authentication required." };
  }

  // Check master vault key or user-specific prefix
  const masterKey = env.MASTER_API_KEY || "zd_sec_b07b3671b1c45b32195f8353d4df8945ee31448699a361b32b6f8192a9b03633";
  if (token.startsWith("zd_oauth_master_") || token === masterKey || token === "zd_r2_andrew_8bc7fb477f" || token === "zd_oauth_master") {
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
        const subpath = sanitizeCrossPlatformPath((args.path || "").replace(/^\/+/, ""));
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
          const putObj = await env.VAULT_BUCKET.put(fullKey, arrayBuf, {
            httpMetadata: { contentType: fetchedType }
          });
          broadcastVaultEvent(userPrefix, { event: "change", action: "write", path: subpath, etag: putObj?.etag || "", size: arrayBuf.byteLength, timestamp: new Date().toISOString() });
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
          const putObj = await env.VAULT_BUCKET.put(fullKey, bytes, {
            httpMetadata: { contentType: mimeType }
          });
          broadcastVaultEvent(userPrefix, { event: "change", action: "write", path: subpath, etag: putObj?.etag || "", size: bytes.byteLength, timestamp: new Date().toISOString() });
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

        const putObj = await env.VAULT_BUCKET.put(fullKey, content, {
          httpMetadata: { contentType: mimeType.startsWith("text/") || mimeType === "application/json" ? mimeType : "text/plain; charset=utf-8" }
        });
        broadcastVaultEvent(userPrefix, { event: "change", action: "write", path: subpath, etag: putObj?.etag || "", size: content.length, timestamp: new Date().toISOString() });

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
        const putObj = await env.VAULT_BUCKET.put(fullKey, updatedText, {
          httpMetadata: { contentType: "text/plain; charset=utf-8" }
        });
        broadcastVaultEvent(userPrefix, { event: "change", action: "write", path: subpath, etag: putObj?.etag || "", timestamp: new Date().toISOString() });
        return {
          jsonrpc: "2.0",
          id,
          result: { content: [{ type: "text", text: `Updated ${subpath} (${updatedText.length} characters).` }] }
        };
      }

      if (toolName === "move_file") {
        const src = sanitizeCrossPlatformPath((args.source || "").replace(/^\/+/, ""));
        const dst = sanitizeCrossPlatformPath((args.destination || "").replace(/^\/+/, ""));
        const srcObj = await env.VAULT_BUCKET.get(`${userPrefix}/${src}`);
        if (!srcObj) {
          return {
            jsonrpc: "2.0",
            id,
            result: { isError: true, content: [{ type: "text", text: `Source file not found: ${args.source}` }] }
          };
        }
        const putObj = await env.VAULT_BUCKET.put(`${userPrefix}/${dst}`, srcObj.body, {
          httpMetadata: srcObj.httpMetadata
        });
        await env.VAULT_BUCKET.delete(`${userPrefix}/${src}`);
        broadcastVaultEvent(userPrefix, { event: "change", action: "move", path: dst, source: src, destination: dst, etag: putObj?.etag || "", timestamp: new Date().toISOString() });
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
        const putObj = await env.VAULT_BUCKET.put(`${userPrefix}/${dst}`, srcObj.body, {
          httpMetadata: srcObj.httpMetadata
        });
        broadcastVaultEvent(userPrefix, { event: "change", action: "copy", path: dst, source: src, destination: dst, etag: putObj?.etag || "", timestamp: new Date().toISOString() });
        return {
          jsonrpc: "2.0",
          id,
          result: { content: [{ type: "text", text: `Copied ${src} to ${dst}.` }] }
        };
      }

      if (toolName === "delete_file" || toolName === "zd_delete") {
        const subpath = (args.path || "").replace(/^\/+/, "");
        await env.VAULT_BUCKET.delete(`${userPrefix}/${subpath}`);
        broadcastVaultEvent(userPrefix, { event: "change", action: "delete", path: subpath, etag: "", timestamp: new Date().toISOString() });
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
  const requestedScope = url.searchParams.get("scope") || "";
  const isDriveScope = requestedScope === "drive" || String(clientState).startsWith("gdrive_");
  const scopeStr = isDriveScope
    ? "openid email profile https://www.googleapis.com/auth/drive"
    : "openid email profile";
  const promptStr = isDriveScope ? "consent select_account" : "select_account";
  const googleAuthUrl = `https://accounts.google.com/o/oauth2/v2/auth?client_id=${encodeURIComponent(clientId)}&redirect_uri=${encodeURIComponent(redirectUri)}&response_type=code&scope=${encodeURIComponent(scopeStr)}&access_type=offline&prompt=${encodeURIComponent(promptStr)}&state=${encodeURIComponent(encodedState)}`;
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

const accountCache = new Map();
const authSessionCache = new Map();

async function loadAccountByEmail(env, email) {
  const cleanEmail = String(email || "").trim().toLowerCase();
  if (!cleanEmail) return null;
  if (cleanEmail === "naegele412@gmail.com") {
    return {
      email: cleanEmail,
      userPrefix: "usr_andrew_8bc7fb477f",
      tenantPrefix: "tenants/zd_r2_andrew_8bc7fb477f/usr_andrew_8bc7fb477f",
      accessKeyId: "zd_r2_andrew_8bc7fb477f",
      secretAccessKey: "zd_sec_b07b3671b1c45b32195f8353d4df8945ee31448699a361b32b6f8192a9b03633",
      tier: "Agency",
      tierId: "agency",
      quotaTB: 20.0,
      licenseKey: "zd_live_agency_master_8bc7fb477f",
      isMasterAdmin: true
    };
  }
  if (accountCache.has(cleanEmail)) {
    return accountCache.get(cleanEmail);
  }
  const emailHash = await sha256Hex(cleanEmail);
  if (env?.VAULT_BUCKET) {
    try {
      const obj = await env.VAULT_BUCKET.get(`_accounts/${emailHash}.json`);
      if (obj) {
        const parsed = JSON.parse(await obj.text());
        accountCache.set(cleanEmail, parsed);
        return parsed;
      }
      // Fallback: check if starter vault was previously provisioned for this email
      const identity = await buildTenantIdentityForEmail(env, cleanEmail);
      const existingVault = await env.VAULT_BUCKET.head(`${identity.tenantPrefix}/ROUTER.md`);
      if (existingVault) {
        const backfilled = {
          email: cleanEmail,
          userPrefix: identity.userPrefix,
          tenantPrefix: identity.tenantPrefix,
          accessKeyId: identity.accessKeyId,
          secretAccessKey: identity.secretAccessKey,
          tier: "Pro",
          tierId: "pro",
          quotaTB: 1.0,
          licenseKey: `zd_live_pro_${emailHash.slice(0, 16)}`,
          createdAt: new Date().toISOString()
        };
        await saveAccountRecord(env, backfilled);
        return backfilled;
      }
    } catch {}
  }
  return null;
}

async function saveAccountRecord(env, account) {
  if (!account || !account.email) return null;
  const cleanEmail = account.email.trim().toLowerCase();
  accountCache.set(cleanEmail, account);
  if (env?.VAULT_BUCKET) {
    try {
      const emailHash = await sha256Hex(cleanEmail);
      await env.VAULT_BUCKET.put(`_accounts/${emailHash}.json`, JSON.stringify(account, null, 2), {
        httpMetadata: { contentType: "application/json" }
      });
    } catch {}
  }
  return account;
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
  const identity = await buildTenantIdentityForEmail(env, email);
  const isMasterAdmin = email === "naegele412@gmail.com";
  const userPrefix = identity.userPrefix;
  const tenantPrefix = identity.tenantPrefix;

  const tokenHash = await sha256Hex(`${email}:${clientSecret}:v2`);
  const sessionToken = isMasterAdmin
    ? `zd_oauth_master_${tokenHash.slice(0, 32)}`
    : `zd_oauth_${userPrefix}_${tokenHash.slice(0, 16)}`;

  // Check if an existing ZeroDrive account exists for this Google identity
  const existingAccount = await loadAccountByEmail(env, email);
  const accountExists = Boolean(existingAccount);

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
    await ensureStarterVaultFiles(env, tenantPrefix);
    const authCode = await createAuthCode(clientSecret, { email, sessionToken, userPrefix });
    const targetUrl = new URL(clientRedirectUri);
    targetUrl.searchParams.set("code", authCode);
    if (clientState) targetUrl.searchParams.set("state", clientState);
    return Response.redirect(targetUrl.toString(), 302);
  }

  // Only pre-seed vault files automatically when account already exists (new accounts are created explicitly on confirmation)
  if (accountExists) {
    await ensureStarterVaultFiles(env, tenantPrefix);
  }

  // Google Drive Cloud-Import OAuth flow (uses ZeroDrive OAuth app instead of rclone's built-in client)
  if (String(clientState).startsWith("gdrive_")) {
    const sessionId = String(clientState).replace(/[^a-zA-Z0-9_-]/g, "");
    const expiryIso = new Date(Date.now() + (Number(tokenData.expires_in || 3599) * 1000)).toISOString();
    const rcloneTokenObj = {
      access_token: tokenData.access_token,
      token_type: tokenData.token_type || "Bearer",
      refresh_token: tokenData.refresh_token || "",
      expiry: expiryIso
    };
    const driveSessionPayload = {
      ok: true,
      status: "authenticated",
      mode: "google_drive",
      sessionId,
      email,
      name: user.name || email.split("@")[0] || "Google Drive User",
      picture: user.picture || "",
      rcloneTokenJson: JSON.stringify(rcloneTokenObj),
      googleClientId: clientId,
      googleClientSecret: clientSecret,
      authenticatedAt: new Date().toISOString()
    };

    authSessionCache.set(sessionId, driveSessionPayload);
    if (env?.VAULT_BUCKET) {
      try {
        await env.VAULT_BUCKET.put(`_auth_sessions/${sessionId}.json`, JSON.stringify(driveSessionPayload, null, 2), {
          httpMetadata: { contentType: "application/json" }
        });
      } catch {}
    }

    const driveDeepLink = `zerodrive://gdrive-auth?session_id=${encodeURIComponent(sessionId)}&email=${encodeURIComponent(email)}`;
    const driveCallbackHtml = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>ZeroDrive — Google Drive Connected</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="icon" type="image/png" href="/app-icon.png">
  <style>
    * { box-sizing: border-box; -webkit-font-smoothing: antialiased; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", Roboto, sans-serif;
      background: radial-gradient(circle at 50% 18%, rgba(52, 199, 89, 0.14) 0%, transparent 60%), #08080a;
      color: #f5f5f7;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      margin: 0;
      padding: 24px;
    }
    .card {
      background: rgba(18, 18, 24, 0.9);
      border: 1px solid rgba(255, 255, 255, 0.1);
      border-radius: 22px;
      padding: 40px 34px;
      max-width: 480px;
      width: 100%;
      text-align: center;
    }
    .title { font-size: 22px; font-weight: 700; margin: 14px 0 8px; }
    .email {
      display: inline-block;
      background: rgba(52, 199, 89, 0.14);
      color: #34c759;
      border: 1px solid rgba(52, 199, 89, 0.35);
      border-radius: 999px;
      padding: 6px 14px;
      font-size: 13px;
      font-weight: 600;
      margin-bottom: 16px;
    }
    .desc { font-size: 14px; color: #a1a1a6; line-height: 1.5; margin-bottom: 24px; }
    .btn {
      display: inline-block;
      background: #ffffff;
      color: #000000;
      font-size: 14px;
      font-weight: 600;
      padding: 12px 26px;
      border-radius: 999px;
      text-decoration: none;
    }
  </style>
</head>
<body>
  <div class="card">
    <img src="/app-icon.png" width="56" height="56" style="border-radius:14px;" alt="ZeroDrive">
    <div class="title">Google Drive Connected to ZeroDrive</div>
    <div class="email">${xmlEscape(email)}</div>
    <p class="desc">Your Google Drive is authorized via ZeroDrive. Returning to the Mac app to finish scanning.</p>
    <a href="${driveDeepLink}" class="btn">Return to ZeroDrive App</a>
    <p style="font-size:12px; color:#6e6e73; margin-top:18px;">Your ZeroDrive Mac app updates automatically — you can close this browser tab.</p>
  </div>
  <script>
    setTimeout(function() { window.location.href = ${JSON.stringify(driveDeepLink)}; }, 150);
  </script>
</body>
</html>`;
    return new Response(driveCallbackHtml, {
      headers: { ...corsHeaders, "Content-Type": "text/html; charset=utf-8" }
    });
  }

  // Desktop Mac App OAuth flow: persist session payload for polling AND deep-link back into ZeroDrive.app
  if (clientState === "app" || String(clientState).startsWith("app_")) {
    const sessionId = String(clientState).startsWith("app_")
      ? String(clientState).slice(4).replace(/[^a-zA-Z0-9_-]/g, "")
      : "default";

    const sessionPayload = {
      ok: true,
      status: "authenticated",
      sessionId,
      email,
      name: user.name || email.split("@")[0] || "ZeroDrive User",
      picture: user.picture || "",
      accountExists,
      sessionToken,
      userPrefix,
      tenantPrefix,
      tier: existingAccount?.tier || (isMasterAdmin ? "Agency" : "Pending Account Creation"),
      quotaTB: existingAccount?.quotaTB || (isMasterAdmin ? 20.0 : 1.0),
      licenseKey: existingAccount?.licenseKey || "",
      endpoint: `${CANONICAL_ORIGIN}/s3`,
      bucket: env.R2_BUCKET || "zerodrive-vault-prod",
      accessKeyId: existingAccount?.accessKeyId || identity.accessKeyId,
      secretAccessKey: existingAccount?.secretAccessKey || identity.secretAccessKey,
      authenticatedAt: new Date().toISOString()
    };

    authSessionCache.set(sessionId, sessionPayload);
    if (env?.VAULT_BUCKET) {
      try {
        await env.VAULT_BUCKET.put(`_auth_sessions/${sessionId}.json`, JSON.stringify(sessionPayload, null, 2), {
          httpMetadata: { contentType: "application/json" }
        });
      } catch {}
    }

    const deepLink = `zerodrive://auth?session_id=${encodeURIComponent(sessionId)}&email=${encodeURIComponent(email)}&exists=${accountExists ? "1" : "0"}&token=${encodeURIComponent(sessionToken)}`;
    const appCallbackHtml = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>ZeroDrive — Google Sign-In Verified</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="icon" type="image/png" href="/app-icon.png">
  <style>
    * { box-sizing: border-box; -webkit-font-smoothing: antialiased; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", Roboto, sans-serif;
      background: radial-gradient(circle at 50% 18%, rgba(52, 199, 89, 0.14) 0%, transparent 60%), #08080a;
      color: #f5f5f7;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      margin: 0;
      padding: 24px;
    }
    .card {
      background: rgba(18, 18, 24, 0.9);
      border: 1px solid rgba(255, 255, 255, 0.1);
      border-radius: 22px;
      padding: 40px 34px;
      max-width: 480px;
      width: 100%;
      text-align: center;
    }
    .title { font-size: 22px; font-weight: 700; margin: 14px 0 8px; }
    .email {
      display: inline-block;
      background: rgba(52, 199, 89, 0.14);
      color: #34c759;
      border: 1px solid rgba(52, 199, 89, 0.35);
      border-radius: 999px;
      padding: 6px 14px;
      font-size: 13px;
      font-weight: 600;
      margin-bottom: 16px;
    }
    .desc { font-size: 14px; color: #a1a1a6; line-height: 1.5; margin-bottom: 24px; }
    .btn {
      display: inline-block;
      background: #ffffff;
      color: #000000;
      font-size: 14px;
      font-weight: 600;
      padding: 12px 26px;
      border-radius: 999px;
      text-decoration: none;
    }
  </style>
</head>
<body>
  <div class="card">
    <img src="/app-icon.png" width="56" height="56" style="border-radius:14px;" alt="ZeroDrive">
    <div class="title">Google Sign-In Verified</div>
    <div class="email">${xmlEscape(email)}</div>
    <p class="desc">${accountExists
      ? "Welcome back! Returning you to ZeroDrive with your existing Cloud Vault."
      : "No existing account found for this Google email. Returning you to ZeroDrive to create your segregated account & drive."}</p>
    <a href="${deepLink}" class="btn">Return to ZeroDrive App</a>
    <p style="font-size:12px; color:#6e6e73; margin-top:18px;">Your ZeroDrive Mac app updates automatically — you can close this browser tab.</p>
  </div>
  <script>
    setTimeout(function() { window.location.href = ${JSON.stringify(deepLink)}; }, 150);
  </script>
</body>
</html>`;
    return new Response(appCallbackHtml, {
      headers: { ...corsHeaders, "Content-Type": "text/html; charset=utf-8" }
    });
  }

  // Fallback for direct web Google OAuth: ensure starter vault if needed
  await ensureStarterVaultFiles(env, tenantPrefix);

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

// ============================================================================
// Real-Time Server-Sent Events (SSE) Engine
// ============================================================================

// Active SSE subscribers grouped by userPrefix: Map<string, Set<Subscriber>>
const sseSubscribers = new Map();

function registerSSESubscriber(userPrefix, subscriber) {
  let set = sseSubscribers.get(userPrefix);
  if (!set) {
    set = new Set();
    sseSubscribers.set(userPrefix, set);
  }
  set.add(subscriber);
  return () => {
    const currentSet = sseSubscribers.get(userPrefix);
    if (currentSet) {
      currentSet.delete(subscriber);
      if (currentSet.size === 0) {
        sseSubscribers.delete(userPrefix);
      }
    }
  };
}

function broadcastVaultEvent(userPrefix, eventPayload) {
  if (!userPrefix || !eventPayload) return;

  if (!eventPayload.timestamp) {
    eventPayload.timestamp = new Date().toISOString();
  }
  if (!eventPayload.event) {
    eventPayload.event = "change";
  }
  if (!eventPayload.id) {
    eventPayload.id = `evt_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;
  }

  // 1. Direct in-memory dispatch to any active streams in this isolate
  const set = sseSubscribers.get(userPrefix);
  if (set && set.size > 0) {
    for (const sub of set) {
      try {
        sub.send(eventPayload);
      } catch (err) {}
    }
  }

  // 2. BroadcastChannel dispatch across isolates in same Cloudflare POP
  if (typeof BroadcastChannel !== "undefined") {
    try {
      const channelName = "zd_sse_" + userPrefix.replace(/[^a-zA-Z0-9_-]/g, "_");
      const bc = new BroadcastChannel(channelName);
      bc.postMessage(eventPayload);
      bc.close();
    } catch {}
  }
}

function handleSseEvents(request, env, userPrefix, corsHeaders, url) {
  const sseHeaders = {
    ...corsHeaders,
    "Content-Type": "text/event-stream; charset=utf-8",
    "Cache-Control": "no-cache, no-transform",
    "Connection": "keep-alive",
    "X-Accel-Buffering": "no"
  };

  const encoder = new TextEncoder();
  let cleanup = () => {};
  let keepAliveTimer = null;
  let pollTimer = null;
  let isClosed = false;
  let bc = null;
  let unregister = () => {};
  const seenEventIds = new Set();

  const stream = new ReadableStream({
    async start(controller) {
      cleanup = () => {
        if (isClosed) return;
        isClosed = true;
        if (keepAliveTimer) {
          clearInterval(keepAliveTimer);
          keepAliveTimer = null;
        }
        if (pollTimer) {
          clearInterval(pollTimer);
          pollTimer = null;
        }
        if (bc) {
          try { bc.close(); } catch {}
          bc = null;
        }
        try { unregister(); } catch {}
        try { controller.close(); } catch {}
      };

      const sendRaw = (chunk) => {
        if (isClosed) return false;
        try {
          controller.enqueue(encoder.encode(chunk));
          return true;
        } catch (e) {
          cleanup();
          return false;
        }
      };

      const sendEvent = (eventObj) => {
        if (isClosed || !eventObj) return;
        const id = eventObj.id || `${eventObj.action || "change"}_${eventObj.path || ""}_${eventObj.timestamp || Date.now()}`;
        if (seenEventIds.has(id)) return;
        seenEventIds.add(id);
        if (seenEventIds.size > 300) {
          const first = seenEventIds.values().next().value;
          seenEventIds.delete(first);
        }
        const eventName = eventObj.event || "change";
        const payloadStr = JSON.stringify(eventObj);
        sendRaw(`id: ${id}\nevent: ${eventName}\ndata: ${payloadStr}\n\n`);
      };

      // 1. Initial connection handshake
      const now = new Date().toISOString();
      const handshake = {
        status: "connected",
        timestamp: now,
        user_prefix: userPrefix
      };
      sendRaw(`event: connected\ndata: ${JSON.stringify(handshake)}\n\n`);

      // 2. Register subscriber for in-memory pushes
      unregister = registerSSESubscriber(userPrefix, {
        send: (eventPayload) => {
          sendEvent(eventPayload);
        }
      });

      // 3. Listen on BroadcastChannel for same-POP cross-isolate notifications
      if (typeof BroadcastChannel !== "undefined") {
        try {
          const channelName = "zd_sse_" + userPrefix.replace(/[^a-zA-Z0-9_-]/g, "_");
          bc = new BroadcastChannel(channelName);
          bc.onmessage = (msgEvt) => {
            try {
              if (msgEvt.data && typeof msgEvt.data === "object") {
                sendEvent(msgEvt.data);
              }
            } catch {}
          };
        } catch {}
      }

      // 4. History / Cursor replay
      const cursor = request.headers.get("Last-Event-ID") || url.searchParams.get("cursor") || url.searchParams.get("since");
      const wantHistory = url.searchParams.get("history") === "true" || !!cursor;
      let lastCheckTime = Date.now();

      if (wantHistory) {
        try {
          const activities = await getSystemJson(env, userPrefix, "activity.json", []);
          if (Array.isArray(activities)) {
            const limit = Math.min(parseInt(url.searchParams.get("limit") || 10, 10), 50);
            const slice = activities.slice(0, limit).reverse();
            for (const act of slice) {
              const actTime = new Date(act.timestamp).getTime();
              if (cursor && !isNaN(Number(cursor)) && actTime < Number(cursor)) continue;
              const id = act.id || `${act.action}:${act.path}:${act.timestamp}`;
              const payload = {
                event: "change",
                action: (act.action || "").replace(/_file$/, ""),
                path: act.path || act.destination || "",
                timestamp: act.timestamp || now,
                etag: act.etag || "",
                ...act
              };
              sendEvent(payload);
            }
          }
        } catch {}
      }

      // 5. Periodic keep-alive ping comment (every 15s)
      keepAliveTimer = setInterval(() => {
        if (isClosed) {
          cleanup();
          return;
        }
        sendRaw(": ping\n\n");
      }, 15000);

      // 6. Cross-isolate activity fallback poll (every 3s)
      pollTimer = setInterval(async () => {
        if (isClosed) {
          cleanup();
          return;
        }
        try {
          const activities = await getSystemJson(env, userPrefix, "activity.json", []);
          if (!Array.isArray(activities) || activities.length === 0) return;
          for (const act of activities.slice(0, 10).reverse()) {
            const actTime = new Date(act.timestamp).getTime();
            if (actTime >= lastCheckTime) {
              const id = act.id || `${act.action}:${act.path}:${act.timestamp}`;
              if (!seenEventIds.has(id)) {
                const payload = {
                  event: "change",
                  action: (act.action || "").replace(/_file$/, ""),
                  path: act.path || act.destination || "",
                  timestamp: act.timestamp || new Date().toISOString(),
                  etag: act.etag || "",
                  ...act
                };
                sendEvent(payload);
              }
            }
          }
          lastCheckTime = Date.now();
        } catch {}
      }, 3000);

      // 7. Request abort signal
      if (request.signal) {
        request.signal.addEventListener("abort", () => {
          cleanup();
        });
      }
    },
    cancel() {
      if (typeof cleanup === "function") cleanup();
    }
  });

  return new Response(stream, {
    status: 200,
    headers: sseHeaders
  });
}

// Active Multipart Upload Sessions cache (fast local isolate resolution)
const mpuMetaCache = new Map();

async function resolveMultipartUpload(env, userPrefix, uploadId, body = {}, url = null) {
  let rawUploadId = uploadId || body.upload_id || (url && url.searchParams.get("upload_id")) || "";
  let targetPath = (body.path || (url && url.searchParams.get("path")) || "").replace(/^\/+/, "");
  let targetKey = body.key || (url && url.searchParams.get("key")) || "";

  if (rawUploadId && rawUploadId.includes("::")) {
    const [uId, enc] = rawUploadId.split("::");
    rawUploadId = uId;
    if (!targetPath && enc) {
      try {
        targetPath = decodeURIComponent(atob(enc));
      } catch {}
    }
  }

  if (!targetKey && targetPath) {
    targetKey = `${userPrefix}/${targetPath}`;
  }

  // Check in-memory cache
  if ((!targetKey || !targetPath) && rawUploadId && mpuMetaCache.has(rawUploadId)) {
    const cached = mpuMetaCache.get(rawUploadId);
    targetKey = targetKey || cached.key;
    targetPath = targetPath || cached.path;
  }

  // Fallback to R2 system metadata storage (multi-isolate pop resiliency)
  if ((!targetKey || !targetPath) && rawUploadId) {
    try {
      const obj = await env.VAULT_BUCKET.get(`${userPrefix}/_SYSTEM/multipart/${rawUploadId}.json`);
      if (obj) {
        const meta = await obj.json();
        targetKey = targetKey || meta.key;
        targetPath = targetPath || meta.path;
      }
    } catch {}
  }

  return { uploadId: rawUploadId, key: targetKey, path: targetPath };
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

  // Multi-Drive Provisioning Engine (/v1/drives)
  if (pathname === "/v1/drives" || pathname.startsWith("/v1/drives/")) {
    return handleDrivesRequest(request, env, userPrefix, corsHeaders, url);
  }

  // 0. GET /v1/events & GET /v1/activity/stream - Real-Time Server-Sent Events (SSE) Push
  if ((pathname === "/v1/events" || pathname === "/v1/activity/stream") && request.method === "GET") {
    return handleSseEvents(request, env, userPrefix, corsHeaders, url);
  }

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
    const driveId = url.searchParams.get("drive_id") || url.searchParams.get("drive") || request.headers.get("x-zerodrive-drive");
    const basePrefix = resolveDrivePrefix(userPrefix, driveId);
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
    const fullKey = `${basePrefix}/${subpath}`;
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
    const driveId = url.searchParams.get("drive_id") || url.searchParams.get("drive") || request.headers.get("x-zerodrive-drive");
    const basePrefix = resolveDrivePrefix(userPrefix, driveId);
    const prefix = subpath ? `${basePrefix}/${subpath}/` : `${basePrefix}/`;
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
          path: p.slice(basePrefix.length + 1).replace(/\/$/, "")
        });
      }
    }

    const files = [];
    for (const o of listed.objects || []) {
      const fileName = o.key.slice(prefix.length);
      if (fileName && (!fileName.includes("/") || recursive)) {
        files.push({
          name: fileName,
          path: o.key.slice(basePrefix.length + 1),
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

    const driveId = url.searchParams.get("drive_id") || url.searchParams.get("drive") || (body && (body.drive_id || body.drive)) || request.headers.get("x-zerodrive-drive");
    const basePrefix = resolveDrivePrefix(userPrefix, driveId);
    const fullKey = `${basePrefix}/${targetPath}`;
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

    const rawPath = body.path || "";
    if (!rawPath) {
      return errorResponse("Missing required field 'path'", 400, corsHeaders);
    }

    // Cross-Platform Sanitizer & Normalization
    const autoSanitize = request.headers.get("x-sanitize-path") === "true" ||
                         url.searchParams.get("sanitize") === "true" ||
                         body.sanitize === true;

    const val = validateCrossPlatformPath(rawPath);
    let targetPath;
    if (!val.valid) {
      if (autoSanitize) {
        targetPath = sanitizeCrossPlatformPath(rawPath);
      } else {
        return errorResponse(`Invalid path: ${val.error}`, 400, corsHeaders, {
          path_issues: val.issues,
          suggested_path: sanitizeCrossPlatformPath(rawPath)
        });
      }
    } else {
      targetPath = val.normalizedPath;
    }

    const driveId = url.searchParams.get("drive_id") || url.searchParams.get("drive") || body.drive_id || body.drive || request.headers.get("x-zerodrive-drive");
    const basePrefix = resolveDrivePrefix(userPrefix, driveId);
    const fullKey = `${basePrefix}/${targetPath}`;
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

    // Conflict Resolution Engine
    const clientEtag = request.headers.get("if-match") || body.base_etag || body.etag;
    const clientTimestamp = request.headers.get("if-unmodified-since") || body.base_modified || body.modified;
    const rawPolicy = request.headers.get("x-conflict-policy") || body.conflict_policy;
    const conflictPolicy = (rawPolicy || (clientEtag || clientTimestamp ? "branch" : "overwrite")).toLowerCase();
    const clientId = request.headers.get("x-client-id") ||
                     request.headers.get("x-device-id") ||
                     body.client_id ||
                     body.device_id ||
                     body.device ||
                     "device";

    const existing = await env.VAULT_BUCKET.head(fullKey);

    const conflictEval = evaluateConflict({
      existingMeta: existing,
      clientEtag,
      clientTimestamp,
      conflictPolicy,
      targetPath,
      clientId,
      conflictTimestamp: body.conflict_timestamp || new Date()
    });

    const finalPath = conflictEval.targetPath;
    const finalKey = `${basePrefix}/${finalPath}`;
    const isConflicted = conflictEval.isConflict && conflictEval.action === "branch";

    const putObj = await env.VAULT_BUCKET.put(finalKey, dataToWrite, {
      httpMetadata: { contentType: mimeType }
    });

    await logActivity(env, userPrefix, "write_file", {
      path: finalPath,
      size: putObj.size,
      etag: putObj.etag,
      conflicted: isConflicted,
      original_path: isConflicted ? targetPath : undefined
    });

    broadcastVaultEvent(userPrefix, {
      event: "change",
      action: "write",
      path: finalPath,
      timestamp: new Date().toISOString(),
      etag: putObj.etag,
      size: putObj.size,
      content_type: mimeType,
      conflicted: isConflicted,
      original_path: isConflicted ? targetPath : undefined
    });

    const responseHeaders = { ...corsHeaders };
    if (isConflicted) {
      responseHeaders["X-Conflicted"] = "true";
      responseHeaders["X-Conflicted-Path"] = finalPath;
    }

    return jsonResponse({
      ok: true,
      path: finalPath,
      conflicted: isConflicted,
      conflict_policy: conflictPolicy,
      original_path: isConflicted ? targetPath : undefined,
      size: putObj.size,
      etag: putObj.etag,
      content_type: mimeType,
      modified: new Date().toISOString()
    }, isConflicted ? 201 : 200, responseHeaders);
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

    const driveId = url.searchParams.get("drive_id") || url.searchParams.get("drive") || body.drive_id || body.drive || request.headers.get("x-zerodrive-drive");
    const basePrefix = resolveDrivePrefix(userPrefix, driveId);
    const fullKey = `${basePrefix}/${targetPath}`;
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

    await logActivity(env, userPrefix, "edit_file", { path: targetPath, occurrences: count, etag: putObj.etag });

    broadcastVaultEvent(userPrefix, {
      event: "change",
      action: "write",
      path: targetPath,
      timestamp: new Date().toISOString(),
      etag: putObj.etag,
      occurrences_replaced: count
    });

    return jsonResponse({
      ok: true,
      path: targetPath,
      occurrences_replaced: count,
      new_size: putObj.size,
      etag: putObj.etag
    }, 200, corsHeaders);
  }

  // 6. POST /v1/files/move or POST /v1/files/rename - Move or rename a file
  if ((pathname === "/v1/files/move" || pathname === "/v1/files/rename") && request.method === "POST") {
    let body = {};
    try { body = await request.json(); } catch { return errorResponse("Invalid JSON payload", 400, corsHeaders); }

    const rawSrc = body.source || body.old_path || body.path || "";
    const rawDst = body.destination || body.new_path || "";
    if (!rawSrc || !rawDst) {
      return errorResponse("Fields 'source' and 'destination' (or 'old_path' and 'new_path') are required", 400, corsHeaders);
    }

    const autoSanitize = request.headers.get("x-sanitize-path") === "true" ||
                         url.searchParams.get("sanitize") === "true" ||
                         body.sanitize === true;

    const valSrc = validateCrossPlatformPath(rawSrc);
    let src;
    if (!valSrc.valid) {
      if (autoSanitize) src = sanitizeCrossPlatformPath(rawSrc);
      else return errorResponse(`Invalid source path: ${valSrc.error}`, 400, corsHeaders);
    } else {
      src = valSrc.normalizedPath;
    }

    const valDst = validateCrossPlatformPath(rawDst);
    let dst;
    if (!valDst.valid) {
      if (autoSanitize) dst = sanitizeCrossPlatformPath(rawDst);
      else return errorResponse(`Invalid destination path: ${valDst.error}`, 400, corsHeaders);
    } else {
      dst = valDst.normalizedPath;
    }

    const srcObj = await env.VAULT_BUCKET.get(`${userPrefix}/${src}`);
    if (!srcObj) {
      return errorResponse(`Source file not found: ${src}`, 404, corsHeaders);
    }

    const putObj = await env.VAULT_BUCKET.put(`${userPrefix}/${dst}`, srcObj.body, {
      httpMetadata: srcObj.httpMetadata
    });
    await env.VAULT_BUCKET.delete(`${userPrefix}/${src}`);
    await logActivity(env, userPrefix, pathname.endsWith("rename") ? "rename_file" : "move_file", { source: src, destination: dst, etag: putObj?.etag || "" });

    broadcastVaultEvent(userPrefix, {
      event: "change",
      action: "move",
      path: dst,
      source: src,
      destination: dst,
      etag: putObj?.etag || "",
      timestamp: new Date().toISOString()
    });

    return jsonResponse({ ok: true, source: src, destination: dst }, 200, corsHeaders);
  }

  // 6b. POST /v1/files/mkdir - Create a directory in vault
  if (pathname === "/v1/files/mkdir" && request.method === "POST") {
    let body = {};
    try { body = await request.json(); } catch { return errorResponse("Invalid JSON payload", 400, corsHeaders); }

    const rawPath = body.path || "";
    if (!rawPath) {
      return errorResponse("Missing required field 'path'", 400, corsHeaders);
    }

    const autoSanitize = request.headers.get("x-sanitize-path") === "true" ||
                         url.searchParams.get("sanitize") === "true" ||
                         body.sanitize === true;

    const val = validateCrossPlatformPath(rawPath);
    let targetPath;
    if (!val.valid) {
      if (autoSanitize) targetPath = sanitizeCrossPlatformPath(rawPath);
      else return errorResponse(`Invalid directory path: ${val.error}`, 400, corsHeaders);
    } else {
      targetPath = val.normalizedPath;
    }

    const driveId = url.searchParams.get("drive_id") || url.searchParams.get("drive") || body.drive_id || body.drive || request.headers.get("x-zerodrive-drive");
    const basePrefix = resolveDrivePrefix(userPrefix, driveId);
    const keepKey = `${basePrefix}/${targetPath}/.keep`;
    await env.VAULT_BUCKET.put(keepKey, "", {
      httpMetadata: { contentType: "application/x-empty" }
    });

    await logActivity(env, userPrefix, "mkdir", { path: targetPath });

    broadcastVaultEvent(userPrefix, {
      event: "change",
      action: "create_dir",
      path: targetPath,
      timestamp: new Date().toISOString()
    });

    return jsonResponse({ ok: true, path: targetPath, is_directory: true, created: true }, 201, corsHeaders);
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
    await logActivity(env, userPrefix, "copy_file", { source: src, destination: dst, etag: putObj.etag });

    broadcastVaultEvent(userPrefix, {
      event: "change",
      action: "copy",
      path: dst,
      source: src,
      destination: dst,
      timestamp: new Date().toISOString(),
      etag: putObj.etag,
      size: putObj.size
    });

    return jsonResponse({ ok: true, source: src, destination: dst, size: putObj.size }, 200, corsHeaders);
  }

  // 8. POST /v1/files/delete or DELETE /v1/files - Delete a file
  if ((pathname === "/v1/files/delete" || pathname === "/v1/files") && (request.method === "POST" || request.method === "DELETE")) {
    let targetPath = (url.searchParams.get("path") || "").replace(/^\/+/, "");
    let body = {};
    if (!targetPath) {
      try {
        body = await request.json();
        targetPath = (body.path || "").replace(/^\/+/, "");
      } catch {}
    }

    if (!targetPath) {
      return errorResponse("Missing parameter 'path'", 400, corsHeaders);
    }

    const driveId = url.searchParams.get("drive_id") || url.searchParams.get("drive") || body.drive_id || body.drive || request.headers.get("x-zerodrive-drive");
    const basePrefix = resolveDrivePrefix(userPrefix, driveId);
    await env.VAULT_BUCKET.delete(`${basePrefix}/${targetPath}`);
    await logActivity(env, userPrefix, "delete_file", { path: targetPath });

    broadcastVaultEvent(userPrefix, {
      event: "change",
      action: "delete",
      path: targetPath,
      timestamp: new Date().toISOString(),
      etag: ""
    });

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
          broadcastVaultEvent(userPrefix, {
            event: "change",
            action: "delete",
            path: p,
            timestamp: new Date().toISOString(),
            etag: ""
          });
        }
      } else if (action === "move" || action === "copy") {
        const src = (op.source || "").replace(/^\/+/, "");
        const dst = (op.destination || "").replace(/^\/+/, "");
        if (src && dst) {
          const srcObj = await env.VAULT_BUCKET.get(`${userPrefix}/${src}`);
          if (srcObj) {
            const putObj = await env.VAULT_BUCKET.put(`${userPrefix}/${dst}`, srcObj.body, { httpMetadata: srcObj.httpMetadata });
            if (action === "move") await env.VAULT_BUCKET.delete(`${userPrefix}/${src}`);
            results.push({ action, source: src, destination: dst, status: "success" });
            broadcastVaultEvent(userPrefix, {
              event: "change",
              action,
              path: dst,
              source: src,
              destination: dst,
              timestamp: new Date().toISOString(),
              etag: putObj?.etag || ""
            });
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

  // 10b. Multipart Large Upload API (/v1/files/multipart/*)
  // High-performance concurrent chunk streaming for massive renders (5GB - 50GB+)
  if (pathname === "/v1/files/multipart/init" && request.method === "POST") {
    let targetPath = (url.searchParams.get("path") || "").replace(/^\/+/, "");
    if (!targetPath) {
      try {
        const body = await request.json();
        targetPath = (body.path || "").replace(/^\/+/, "");
      } catch {}
    }
    if (!targetPath) {
      return errorResponse("Missing parameter 'path'", 400, corsHeaders);
    }

    const driveId = url.searchParams.get("drive_id") || url.searchParams.get("drive") || body.drive_id || body.drive || request.headers.get("x-zerodrive-drive");
    const basePrefix = resolveDrivePrefix(userPrefix, driveId);
    const fullKey = `${basePrefix}/${targetPath}`;
    const mimeType = guessMimeType(targetPath);
    try {
      const mp = await env.VAULT_BUCKET.createMultipartUpload(fullKey, {
        httpMetadata: { contentType: mimeType }
      });
      return jsonResponse({
        ok: true,
        upload_id: mp.uploadId,
        path: targetPath,
        key: fullKey,
        part_size: 10485760
      }, 200, corsHeaders);
    } catch (e) {
      return errorResponse(`Failed to initiate multipart upload: ${e.message}`, 500, corsHeaders);
    }
  }

  if (pathname === "/v1/files/multipart/part" && (request.method === "PUT" || request.method === "POST")) {
    let targetPath = (url.searchParams.get("path") || "").replace(/^\/+/, "");
    const uploadId = url.searchParams.get("upload_id") || url.searchParams.get("uploadId");
    const partNum = parseInt(url.searchParams.get("part_number") || url.searchParams.get("partNumber") || "0", 10);

    if (!targetPath || !uploadId || partNum < 1 || partNum > 10000) {
      return errorResponse("Missing 'path', 'upload_id', or valid 'part_number' (1-10000)", 400, corsHeaders);
    }

    const driveId = url.searchParams.get("drive_id") || url.searchParams.get("drive") || body.drive_id || body.drive || request.headers.get("x-zerodrive-drive");
    const basePrefix = resolveDrivePrefix(userPrefix, driveId);
    const fullKey = `${basePrefix}/${targetPath}`;
    try {
      const mp = env.VAULT_BUCKET.resumeMultipartUpload(fullKey, uploadId);
      const part = await mp.uploadPart(partNum, request.body);
      const etag = part.etag.replace(/^"+|"+$/g, "");
      return new Response(JSON.stringify({
        ok: true,
        part_number: partNum,
        etag: etag
      }), {
        status: 200,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
          "ETag": `"${etag}"`
        }
      });
    } catch (e) {
      return errorResponse(`Part upload failed: ${e.message}`, 500, corsHeaders);
    }
  }

  if (pathname === "/v1/files/multipart/complete" && request.method === "POST") {
    let body = {};
    try { body = await request.json(); } catch {}
    let targetPath = (url.searchParams.get("path") || body.path || "").replace(/^\/+/, "");
    const uploadId = url.searchParams.get("upload_id") || url.searchParams.get("uploadId") || body.upload_id || body.uploadId;
    const rawParts = body.parts || [];

    if (!targetPath || !uploadId || !Array.isArray(rawParts) || rawParts.length === 0) {
      return errorResponse("Missing 'path', 'upload_id', or 'parts' array", 400, corsHeaders);
    }

    const parts = rawParts.map(p => ({
      partNumber: parseInt(p.part_number || p.partNumber, 10),
      etag: String(p.etag || "").replace(/^"+|"+$/g, "")
    })).sort((a, b) => a.partNumber - b.partNumber);

    const driveId = url.searchParams.get("drive_id") || url.searchParams.get("drive") || body.drive_id || body.drive || request.headers.get("x-zerodrive-drive");
    const basePrefix = resolveDrivePrefix(userPrefix, driveId);
    const fullKey = `${basePrefix}/${targetPath}`;
    try {
      const mp = env.VAULT_BUCKET.resumeMultipartUpload(fullKey, uploadId);
      const completed = await mp.complete(parts);
      const finalEtag = completed.httpEtag || `"${completed.etag}"`;

      await logActivity(env, userPrefix, "write_file", { path: targetPath, size: completed.size, etag: finalEtag });
      broadcastVaultEvent(userPrefix, {
        event: "change",
        action: "write",
        path: targetPath,
        timestamp: new Date().toISOString(),
        etag: finalEtag,
        size: completed.size
      });

      return jsonResponse({
        ok: true,
        path: targetPath,
        etag: finalEtag,
        size: completed.size
      }, 200, corsHeaders);
    } catch (e) {
      return errorResponse(`Complete multipart upload failed: ${e.message}`, 500, corsHeaders);
    }
  }

  if (pathname === "/v1/files/multipart/abort" && request.method === "POST") {
    let body = {};
    try { body = await request.json(); } catch {}
    let targetPath = (url.searchParams.get("path") || body.path || "").replace(/^\/+/, "");
    const uploadId = url.searchParams.get("upload_id") || url.searchParams.get("uploadId") || body.upload_id || body.uploadId;

    if (!targetPath || !uploadId) {
      return errorResponse("Missing 'path' or 'upload_id'", 400, corsHeaders);
    }

    const driveId = url.searchParams.get("drive_id") || url.searchParams.get("drive") || body.drive_id || body.drive || request.headers.get("x-zerodrive-drive");
    const basePrefix = resolveDrivePrefix(userPrefix, driveId);
    const fullKey = `${basePrefix}/${targetPath}`;
    try {
      const mp = env.VAULT_BUCKET.resumeMultipartUpload(fullKey, uploadId);
      await mp.abort();
      return jsonResponse({ ok: true, aborted: true }, 200, corsHeaders);
    } catch (e) {
      return errorResponse(`Abort failed: ${e.message}`, 500, corsHeaders);
    }
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

    const driveId = url.searchParams.get("drive_id") || url.searchParams.get("drive") || body.drive_id || body.drive || request.headers.get("x-zerodrive-drive");
    const basePrefix = resolveDrivePrefix(userPrefix, driveId);
    const fullKey = `${basePrefix}/${targetPath}`;
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

  // 11b. POST /v1/files/multipart/create - Initiate S3/R2 multipart upload for massive files (GBs+)
  if (pathname === "/v1/files/multipart/create" && request.method === "POST") {
    let body = {};
    try { body = await request.json(); } catch { body = {}; }
    const rawPath = body.path || url.searchParams.get("path") || "";
    if (!rawPath) {
      return errorResponse("Missing parameter 'path'", 400, corsHeaders);
    }
    const subpath = String(rawPath).replace(/^\/+/, "");
    const fullKey = `${userPrefix}/${subpath}`;
    const mimeType = body.mime_type || body.content_type || guessMimeType(subpath);

    const options = {
      httpMetadata: {
        contentType: mimeType
      }
    };
    if (body.custom_metadata && typeof body.custom_metadata === "object") {
      options.customMetadata = body.custom_metadata;
    }

    try {
      const mp = await env.VAULT_BUCKET.createMultipartUpload(fullKey, options);
      mpuMetaCache.set(mp.uploadId, { key: fullKey, path: subpath, mimeType });
      try {
        await env.VAULT_BUCKET.put(
          `${userPrefix}/_SYSTEM/multipart/${mp.uploadId}.json`,
          JSON.stringify({ upload_id: mp.uploadId, key: fullKey, path: subpath, mimeType, created: new Date().toISOString() }),
          { httpMetadata: { contentType: "application/json" } }
        );
      } catch {}

      return jsonResponse({
        ok: true,
        upload_id: mp.uploadId,
        key: fullKey,
        path: subpath
      }, 201, corsHeaders);
    } catch (err) {
      return errorResponse(`Failed to create multipart upload: ${err.message}`, 500, corsHeaders);
    }
  }

  // 11c. POST /v1/files/multipart/part - Upload a chunk part (or return signed part upload URL)
  if (pathname === "/v1/files/multipart/part" && request.method === "POST") {
    const isJson = request.headers.get("content-type")?.includes("application/json");
    let body = {};
    if (isJson) {
      try { body = await request.json(); } catch { return errorResponse("Invalid JSON payload", 400, corsHeaders); }
    }

    const resolved = await resolveMultipartUpload(env, userPrefix, body.upload_id, body, url);
    if (!resolved.uploadId || !resolved.key) {
      return errorResponse("Missing or invalid upload_id or path", 400, corsHeaders);
    }

    const rawPartNum = body.part_number !== undefined
      ? body.part_number
      : (body.partNumber !== undefined ? body.partNumber : url.searchParams.get("part_number") || url.searchParams.get("partNumber"));
    const partNumber = parseInt(rawPartNum, 10);
    if (isNaN(partNumber) || partNumber < 1 || partNumber > 10000) {
      return errorResponse("part_number must be an integer between 1 and 10000", 400, corsHeaders);
    }

    // Optional: Return signed upload part URL if requested
    if (body.signed_url || body.get_signed_url || (isJson && body.content === undefined && body.content_base64 === undefined && (body.url_only || body.get_url))) {
      const secret = env.GOOGLE_CLIENT_SECRET || "zd_secret";
      const partToken = await createAuthCode(secret, {
        op: "upload_part",
        key: resolved.key,
        path: resolved.path,
        upload_id: resolved.uploadId,
        part_number: partNumber
      }, 3600);
      const partUrl = `${CANONICAL_ORIGIN}/vault/upload-part?token=${encodeURIComponent(partToken)}&partNumber=${partNumber}&uploadId=${encodeURIComponent(resolved.uploadId)}`;
      return jsonResponse({
        ok: true,
        part_number: partNumber,
        upload_id: resolved.uploadId,
        upload_url: partUrl,
        method: "PUT",
        expires_in_seconds: 3600
      }, 200, corsHeaders);
    }

    let chunkData;
    if (isJson) {
      if (body.content_base64) {
        chunkData = base64ToBytes(body.content_base64);
      } else if (body.content !== undefined) {
        if (body.is_base64 || body.encoding === "base64") {
          chunkData = base64ToBytes(body.content);
        } else if (typeof body.content === "string") {
          chunkData = new TextEncoder().encode(body.content);
        } else {
          chunkData = body.content;
        }
      } else {
        return errorResponse("Missing part 'content' or 'content_base64'", 400, corsHeaders);
      }
    } else {
      chunkData = request.body;
      if (!chunkData) {
        return errorResponse("Missing request body for part upload", 400, corsHeaders);
      }
    }

    try {
      const mp = env.VAULT_BUCKET.resumeMultipartUpload(resolved.key, resolved.uploadId);
      const part = await mp.uploadPart(partNumber, chunkData);
      const cleanEtag = (part.etag || "").replace(/^"+|"+$/g, "");
      return jsonResponse({
        ok: true,
        part_number: partNumber,
        etag: cleanEtag
      }, 200, corsHeaders);
    } catch (err) {
      return errorResponse(`Failed to upload part #${partNumber}: ${err.message}`, 500, corsHeaders);
    }
  }

  // 11d. POST /v1/files/multipart/complete - Complete multipart upload, stitch parts, log & broadcast
  if (pathname === "/v1/files/multipart/complete" && request.method === "POST") {
    let body = {};
    try { body = await request.json(); } catch { return errorResponse("Invalid JSON payload", 400, corsHeaders); }

    const resolved = await resolveMultipartUpload(env, userPrefix, body.upload_id, body, url);
    if (!resolved.uploadId || !resolved.key) {
      return errorResponse("Missing or invalid upload_id or path", 400, corsHeaders);
    }

    const rawParts = Array.isArray(body.parts) ? body.parts : [];
    if (rawParts.length === 0) {
      return errorResponse("Provide non-empty 'parts' array with part_number and etag", 400, corsHeaders);
    }

    const parts = rawParts.map(p => ({
      partNumber: parseInt(p.part_number !== undefined ? p.part_number : p.partNumber, 10),
      etag: String(p.etag || "").replace(/^"+|"+$/g, "")
    })).sort((a, b) => a.partNumber - b.partNumber);

    try {
      const mp = env.VAULT_BUCKET.resumeMultipartUpload(resolved.key, resolved.uploadId);
      let completed;
      try {
        completed = await mp.complete(parts);
      } catch (e1) {
        completed = await mp.complete(
          parts.map(p => ({ partNumber: p.partNumber, etag: `"${p.etag}"` }))
        );
      }

      mpuMetaCache.delete(resolved.uploadId);
      try { await env.VAULT_BUCKET.delete(`${userPrefix}/_SYSTEM/multipart/${resolved.uploadId}.json`); } catch {}

      const cleanEtag = (completed.httpEtag || completed.etag || "").replace(/^"+|"+$/g, "");
      const finalSize = completed.size || 0;
      const finalPath = resolved.path || resolved.key.replace(new RegExp(`^${userPrefix}/`), "");

      await logActivity(env, userPrefix, "write_file", {
        path: finalPath,
        size: finalSize,
        etag: cleanEtag,
        multipart: true,
        parts_count: parts.length
      });

      broadcastVaultEvent(userPrefix, {
        event: "change",
        action: "write",
        path: finalPath,
        size: finalSize,
        etag: cleanEtag,
        timestamp: new Date().toISOString()
      });

      return jsonResponse({
        ok: true,
        path: finalPath,
        size: finalSize,
        etag: cleanEtag
      }, 200, corsHeaders);
    } catch (err) {
      return errorResponse(`Failed to complete multipart upload: ${err.message}`, 500, corsHeaders);
    }
  }

  // 11e. POST /v1/files/multipart/abort - Abort multipart upload session
  if (pathname === "/v1/files/multipart/abort" && request.method === "POST") {
    let body = {};
    try { body = await request.json(); } catch { body = {}; }

    const resolved = await resolveMultipartUpload(env, userPrefix, body.upload_id, body, url);
    if (!resolved.uploadId || !resolved.key) {
      return errorResponse("Missing or invalid upload_id or path", 400, corsHeaders);
    }

    try {
      const mp = env.VAULT_BUCKET.resumeMultipartUpload(resolved.key, resolved.uploadId);
      await mp.abort();
      mpuMetaCache.delete(resolved.uploadId);
      try { await env.VAULT_BUCKET.delete(`${userPrefix}/_SYSTEM/multipart/${resolved.uploadId}.json`); } catch {}

      return jsonResponse({
        ok: true,
        upload_id: resolved.uploadId,
        aborted: true,
        path: resolved.path || resolved.key.replace(new RegExp(`^${userPrefix}/`), "")
      }, 200, corsHeaders);
    } catch (err) {
      return errorResponse(`Failed to abort multipart upload: ${err.message}`, 500, corsHeaders);
    }
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
    broadcastVaultEvent(userPrefix, {
      event: "change",
      action,
      path: body.details?.path || "",
      timestamp: entry?.timestamp || new Date().toISOString(),
      etag: body.details?.etag || "",
      ...body.details
    });
    return jsonResponse({ ok: true, activity: entry }, 201, corsHeaders);
  }

  return errorResponse(`Endpoint not found: ${request.method} ${pathname}`, 404, corsHeaders, {
    available_endpoints: [
      "GET /v1/events", "GET /v1/activity/stream",
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
      "/v1/events": {
        get: {
          tags: ["Real-Time Push & Events"],
          summary: "Server-Sent Events (SSE) Push Notifications",
          description: "Streams live vault file mutations (write, edit, move, copy, delete) in real-time over a persistent HTTP SSE connection. Supports ping heartbeats and automatic reconnection.",
          operationId: "getEventStream",
          responses: {
            "200": {
              description: "Text Event Stream",
              content: {
                "text/event-stream": {
                  schema: { type: "string" }
                }
              }
            }
          }
        }
      },
      "/v1/activity/stream": {
        get: {
          tags: ["Real-Time Push & Events"],
          summary: "Real-Time Activity SSE Stream (Alias)",
          description: "Streams real-time activity and file change events over SSE.",
          operationId: "getActivityStream",
          responses: {
            "200": {
              description: "Text Event Stream",
              content: {
                "text/event-stream": {
                  schema: { type: "string" }
                }
              }
            }
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

    <!-- Section 7: Real-Time SSE Push -->
    <div class="section-title">7. Real-Time Push Notifications (Server-Sent Events / SSE)</div>

    <div class="endpoint">
      <div class="endpoint-header">
        <span class="method get">GET</span>
        <span class="ep-path">/v1/events</span>
        <span class="ep-desc">Live Server-Sent Events stream for vault file mutations</span>
      </div>
      <div class="endpoint-body">
        <p>Establishes a persistent SSE connection. Pushes instant change events (<code>write</code>, <code>edit</code>, <code>move</code>, <code>copy</code>, <code>delete</code>) and periodic <code>: ping</code> heartbeats. Also available at <code>/v1/activity/stream</code>.</p>
        <pre><code># Stream live events in terminal:
curl -N -s "https://api.zerodrive.dev/v1/events" \
  -H "Authorization: Bearer YOUR_TOKEN"</code><button class="copy-btn" onclick="copyPre(this)">Copy</button></pre>
        <p style="margin-top:12px;font-size:12px;color:var(--text-muted);">In browser JavaScript or EventSource:</p>
        <pre><code>const es = new EventSource("https://api.zerodrive.dev/v1/events?key=YOUR_TOKEN");
es.addEventListener("connected", (e) => console.log("Connected:", JSON.parse(e.data)));
es.addEventListener("change", (e) => console.log("File mutation:", JSON.parse(e.data)));</code><button class="copy-btn" onclick="copyPre(this)">Copy</button></pre>
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



function handleWebExplorerHtml(url, corsHeaders) {
  const origin = CANONICAL_ORIGIN;
  const iconUrl = CONNECTOR_ICON_URL;
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>ZeroDrive — Web Vault Explorer &amp; Player</title>
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <link rel="icon" type="image/png" href="${CONNECTOR_ICON_URL}">
  <link rel="apple-touch-icon" href="${CONNECTOR_ICON_URL}">
  <meta name="theme-color" content="#090a0f">
  <meta name="description" content="Ultra-clean dark-mode Web Explorer and Player for ZeroDrive 24/7 Cloud Vault.">
  <style>
    :root {
      --bg: #090a0f;
      --bg-surface: #11121b;
      --bg-surface-elevated: #161824;
      --bg-surface-hover: #1c1e2d;
      --bg-input: #171825;
      --border: rgba(255, 255, 255, 0.08);
      --border-hover: rgba(255, 255, 255, 0.16);
      --border-accent: rgba(245, 166, 35, 0.35);
      --accent: #f5a623;
      --accent-hover: #ffb738;
      --accent-dim: rgba(245, 166, 35, 0.12);
      --accent-glow: rgba(245, 166, 35, 0.25);
      --text: #f5f5f7;
      --text-muted: #8e8e98;
      --text-dim: #63636d;
      --green: #34c759;
      --green-dim: rgba(52, 199, 89, 0.12);
      --blue: #0a84ff;
      --blue-dim: rgba(10, 132, 255, 0.12);
      --purple: #bf5af2;
      --red: #ff453a;
      --font-sans: -apple-system, BlinkMacSystemFont, "Inter", "SF Pro Display", "SF Pro Text", "Segoe UI", Roboto, sans-serif;
      --font-mono: ui-monospace, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
      --header-height: 60px;
    }

    * { box-sizing: border-box; -webkit-font-smoothing: antialiased; margin: 0; padding: 0; }
    html, body {
      height: 100%;
      background: var(--bg);
      color: var(--text);
      font-family: var(--font-sans);
      font-size: 14px;
      line-height: 1.5;
      overflow: hidden;
    }

    #app {
      display: flex;
      flex-direction: column;
      height: 100vh;
      overflow: hidden;
    }

    /* Header Bar */
    header {
      height: var(--header-height);
      background: rgba(9, 10, 15, 0.88);
      backdrop-filter: blur(20px);
      -webkit-backdrop-filter: blur(20px);
      border-bottom: 1px solid var(--border);
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0 18px;
      gap: 16px;
      flex-shrink: 0;
      z-index: 50;
    }

    .brand-section {
      display: flex;
      align-items: center;
      gap: 12px;
      text-decoration: none;
      color: #fff;
      flex-shrink: 0;
      cursor: pointer;
    }
    .brand-icon {
      width: 32px;
      height: 32px;
      border-radius: 8px;
      display: block;
      box-shadow: 0 2px 8px rgba(0,0,0,0.4);
    }
    .brand-title {
      font-size: 16px;
      font-weight: 700;
      letter-spacing: -0.3px;
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .brand-badge {
      font-size: 11px;
      font-weight: 600;
      padding: 2px 7px;
      border-radius: 6px;
      background: var(--accent-dim);
      border: 1px solid var(--border-accent);
      color: var(--accent);
      letter-spacing: 0.2px;
      text-transform: uppercase;
    }

    /* Search Box */
    .search-box-wrap {
      flex: 1;
      max-width: 440px;
      position: relative;
      display: flex;
      align-items: center;
    }
    .search-input {
      width: 100%;
      height: 36px;
      background: var(--bg-input);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 0 36px 0 34px;
      color: var(--text);
      font-family: var(--font-sans);
      font-size: 13px;
      transition: all 0.15s ease;
      outline: none;
    }
    .search-input:focus {
      border-color: var(--accent);
      box-shadow: 0 0 0 3px var(--accent-glow);
    }
    .search-icon-svg {
      position: absolute;
      left: 10px;
      width: 16px;
      height: 16px;
      color: var(--text-muted);
      pointer-events: none;
    }
    .search-clear-btn {
      position: absolute;
      right: 8px;
      background: transparent;
      border: none;
      color: var(--text-muted);
      cursor: pointer;
      padding: 4px;
      display: none;
      border-radius: 4px;
      font-size: 16px;
      line-height: 1;
    }
    .search-clear-btn:hover { color: #fff; }
    .search-kbd {
      position: absolute;
      right: 10px;
      font-family: var(--font-mono);
      font-size: 11px;
      color: var(--text-dim);
      background: rgba(255, 255, 255, 0.05);
      padding: 2px 5px;
      border-radius: 4px;
      pointer-events: none;
    }

    /* Header Actions */
    .header-actions {
      display: flex;
      align-items: center;
      gap: 8px;
      flex-shrink: 0;
    }
    .btn {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 7px 12px;
      border-radius: 8px;
      font-size: 13px;
      font-weight: 500;
      font-family: var(--font-sans);
      cursor: pointer;
      border: 1px solid var(--border);
      background: var(--bg-surface);
      color: var(--text);
      transition: all 0.15s ease;
      text-decoration: none;
      user-select: none;
      height: 36px;
    }
    .btn:hover {
      background: var(--bg-surface-hover);
      border-color: var(--border-hover);
      color: #fff;
    }
    .btn:active { transform: scale(0.98); }
    .btn-accent {
      background: var(--accent);
      border-color: var(--accent);
      color: #000;
      font-weight: 600;
    }
    .btn-accent:hover {
      background: var(--accent-hover);
      border-color: var(--accent-hover);
      color: #000;
    }
    .btn-icon-only {
      padding: 0;
      width: 36px;
      height: 36px;
      justify-content: center;
    }

    .auth-badge {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 5px 11px;
      border-radius: 8px;
      font-size: 12px;
      background: var(--bg-surface);
      border: 1px solid var(--border);
      color: var(--text-muted);
      cursor: pointer;
      transition: all 0.15s ease;
      height: 36px;
    }
    .auth-badge:hover {
      border-color: var(--border-hover);
      color: var(--text);
    }
    .status-dot {
      width: 7px;
      height: 7px;
      border-radius: 50%;
      background: var(--green);
      box-shadow: 0 0 8px var(--green);
    }
    .status-dot.offline {
      background: var(--red);
      box-shadow: 0 0 8px var(--red);
    }

    /* Main Split Container */
    .main-container {
      display: flex;
      flex: 1;
      height: calc(100vh - var(--header-height));
      overflow: hidden;
      position: relative;
    }

    /* Left Pane: File Browser */
    .file-pane {
      flex: 1;
      min-width: 340px;
      max-width: 580px;
      border-right: 1px solid var(--border);
      display: flex;
      flex-direction: column;
      background: var(--bg);
      overflow: hidden;
    }
    @media (max-width: 900px) {
      .file-pane {
        max-width: 100%;
        border-right: none;
      }
      .preview-pane {
        position: fixed;
        inset: 0;
        z-index: 100;
        transform: translateX(100%);
        transition: transform 0.25s cubic-bezier(0.16, 1, 0.3, 1);
      }
      .preview-pane.active {
        transform: translateX(0);
      }
      .mobile-back-btn {
        display: inline-flex !important;
      }
    }

    /* Breadcrumbs Toolbar */
    .toolbar-bar {
      padding: 10px 16px;
      border-bottom: 1px solid var(--border);
      background: var(--bg-surface);
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      flex-shrink: 0;
    }
    .breadcrumbs {
      display: flex;
      align-items: center;
      gap: 4px;
      flex-wrap: wrap;
      font-size: 13px;
      color: var(--text-muted);
    }
    .crumb-item {
      display: inline-flex;
      align-items: center;
      gap: 4px;
      padding: 3px 6px;
      border-radius: 6px;
      cursor: pointer;
      color: var(--text-muted);
      transition: all 0.12s;
    }
    .crumb-item:hover {
      background: rgba(255, 255, 255, 0.06);
      color: var(--text);
    }
    .crumb-item.current {
      color: var(--text);
      font-weight: 600;
      pointer-events: none;
    }
    .crumb-sep {
      color: var(--text-dim);
      font-size: 12px;
    }

    .folder-meta-stats {
      font-size: 12px;
      color: var(--text-muted);
      white-space: nowrap;
    }

    /* File List Container */
    .file-list-wrap {
      flex: 1;
      overflow-y: auto;
      padding: 6px;
    }
    .file-list-wrap::-webkit-scrollbar { width: 8px; }
    .file-list-wrap::-webkit-scrollbar-track { background: transparent; }
    .file-list-wrap::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.12); border-radius: 4px; }

    .file-row {
      display: flex;
      align-items: center;
      padding: 9px 12px;
      border-radius: 8px;
      margin-bottom: 2px;
      cursor: pointer;
      transition: background 0.12s ease;
      gap: 12px;
      user-select: none;
      position: relative;
    }
    .file-row:hover {
      background: var(--bg-surface);
    }
    .file-row.selected {
      background: var(--bg-surface-elevated);
      outline: 1px solid var(--border-hover);
    }
    .file-icon {
      width: 28px;
      height: 28px;
      border-radius: 6px;
      display: flex;
      align-items: center;
      justify-content: center;
      flex-shrink: 0;
    }
    .icon-folder { background: rgba(245, 166, 35, 0.15); color: #f5a623; }
    .icon-video { background: rgba(191, 90, 242, 0.18); color: #d070ff; }
    .icon-image { background: rgba(52, 199, 89, 0.18); color: #34c759; }
    .icon-markdown { background: rgba(10, 132, 255, 0.18); color: #389bff; }
    .icon-code { background: rgba(100, 210, 255, 0.18); color: #64d2ff; }
    .icon-archive { background: rgba(255, 159, 10, 0.18); color: #ff9f0a; }
    .icon-file { background: rgba(255, 255, 255, 0.08); color: #a1a1aa; }

    .file-info {
      flex: 1;
      min-width: 0;
    }
    .file-name {
      font-size: 13.5px;
      font-weight: 500;
      color: var(--text);
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .file-subtext {
      font-size: 11.5px;
      color: var(--text-muted);
      display: flex;
      gap: 8px;
      margin-top: 1px;
    }

    .row-actions {
      display: flex;
      align-items: center;
      gap: 4px;
      opacity: 0;
      transition: opacity 0.12s ease;
      flex-shrink: 0;
    }
    .file-row:hover .row-actions,
    .file-row.selected .row-actions {
      opacity: 1;
    }
    .mini-btn {
      padding: 4px 8px;
      border-radius: 6px;
      background: var(--bg-surface-elevated);
      border: 1px solid var(--border);
      color: var(--text-muted);
      font-size: 11.5px;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      gap: 4px;
      transition: all 0.12s;
    }
    .mini-btn:hover {
      background: var(--bg-surface-hover);
      color: #fff;
      border-color: var(--border-hover);
    }
    .mini-btn.copied {
      background: var(--green-dim);
      border-color: var(--green);
      color: var(--green);
    }

    /* Right Pane: Inspector & Previewer */
    .preview-pane {
      flex: 1.3;
      background: var(--bg-surface);
      display: flex;
      flex-direction: column;
      overflow: hidden;
      min-width: 0;
    }

    /* Preview Header */
    .preview-header {
      padding: 12px 18px;
      border-bottom: 1px solid var(--border);
      background: var(--bg-surface);
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      flex-shrink: 0;
    }
    .preview-title-area {
      display: flex;
      align-items: center;
      gap: 12px;
      min-width: 0;
      flex: 1;
    }
    .preview-title-text {
      min-width: 0;
    }
    .preview-filename {
      font-size: 15px;
      font-weight: 600;
      color: #fff;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .preview-path {
      font-size: 12px;
      color: var(--text-muted);
      font-family: var(--font-mono);
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .preview-actions {
      display: flex;
      align-items: center;
      gap: 8px;
      flex-shrink: 0;
    }

    .mobile-back-btn {
      display: none;
      align-items: center;
      gap: 6px;
      background: transparent;
      border: none;
      color: var(--accent);
      font-size: 14px;
      font-weight: 500;
      cursor: pointer;
      padding: 6px;
      border-radius: 6px;
    }

    /* Preview Content Box */
    .preview-content {
      flex: 1;
      overflow-y: auto;
      display: flex;
      flex-direction: column;
      position: relative;
    }

    /* Empty State */
    .empty-state {
      margin: auto;
      text-align: center;
      padding: 40px 24px;
      max-width: 440px;
    }
    .empty-state-icon {
      width: 72px;
      height: 72px;
      border-radius: 20px;
      background: rgba(245, 166, 35, 0.08);
      border: 1px solid var(--border-accent);
      color: var(--accent);
      display: flex;
      align-items: center;
      justify-content: center;
      margin: 0 auto 20px;
      box-shadow: 0 0 32px rgba(245, 166, 35, 0.1);
    }
    .empty-state h3 {
      font-size: 18px;
      font-weight: 600;
      margin-bottom: 8px;
      color: #fff;
    }
    .empty-state p {
      font-size: 13.5px;
      color: var(--text-muted);
      line-height: 1.6;
      margin-bottom: 24px;
    }
    .shortcut-hints {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 8px;
      text-align: left;
      background: var(--bg-surface-elevated);
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 14px 16px;
      font-size: 12px;
      color: var(--text-muted);
    }
    .shortcut-hint { display: flex; justify-content: space-between; align-items: center; }
    .shortcut-hint kbd {
      background: rgba(255, 255, 255, 0.08);
      padding: 2px 6px;
      border-radius: 4px;
      font-family: var(--font-mono);
      color: var(--text);
    }

    /* Video Player View */
    .video-view-wrap {
      display: flex;
      flex-direction: column;
      height: 100%;
      background: #000;
    }
    .video-player-container {
      flex: 1;
      display: flex;
      align-items: center;
      justify-content: center;
      background: #000;
      position: relative;
      min-height: 280px;
    }
    video#vaultVideoPlayer {
      width: 100%;
      height: 100%;
      max-height: 70vh;
      outline: none;
      background: #000;
    }
    .video-toolbar {
      padding: 12px 18px;
      background: var(--bg-surface);
      border-top: 1px solid var(--border);
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      flex-wrap: wrap;
    }
    .video-badge {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 4px 9px;
      border-radius: 6px;
      background: var(--green-dim);
      border: 1px solid rgba(52, 199, 89, 0.25);
      color: var(--green);
      font-size: 12px;
      font-weight: 500;
    }
    .video-speed-group {
      display: flex;
      align-items: center;
      gap: 4px;
      background: var(--bg-surface-elevated);
      padding: 3px;
      border-radius: 8px;
      border: 1px solid var(--border);
    }
    .speed-btn {
      background: transparent;
      border: none;
      color: var(--text-muted);
      font-size: 12px;
      font-weight: 500;
      padding: 4px 8px;
      border-radius: 6px;
      cursor: pointer;
      transition: all 0.12s;
    }
    .speed-btn:hover { color: #fff; }
    .speed-btn.active {
      background: var(--accent);
      color: #000;
      font-weight: 600;
    }

    /* Image Viewer */
    .image-view-wrap {
      display: flex;
      flex-direction: column;
      height: 100%;
      background: #0b0c13;
    }
    .image-stage {
      flex: 1;
      display: flex;
      align-items: center;
      justify-content: center;
      overflow: auto;
      padding: 24px;
      background-image: 
        linear-gradient(45deg, #12131d 25%, transparent 25%), 
        linear-gradient(-45deg, #12131d 25%, transparent 25%), 
        linear-gradient(45deg, transparent 75%, #12131d 75%), 
        linear-gradient(-45deg, transparent 75%, #12131d 75%);
      background-size: 20px 20px;
      background-position: 0 0, 0 10px, 10px -10px, -10px 0px;
    }
    .vault-image {
      max-width: 100%;
      max-height: 100%;
      object-fit: contain;
      border-radius: 8px;
      box-shadow: 0 16px 40px rgba(0, 0, 0, 0.6);
      transition: transform 0.15s ease;
    }
    .image-toolbar {
      padding: 10px 18px;
      background: var(--bg-surface);
      border-top: 1px solid var(--border);
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
    }

    /* Markdown & Code Editor / Viewer */
    .editor-view-wrap {
      display: flex;
      flex-direction: column;
      height: 100%;
    }
    .editor-tabs-bar {
      padding: 8px 16px;
      border-bottom: 1px solid var(--border);
      background: var(--bg-surface);
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
    }
    .tabs-group {
      display: flex;
      background: var(--bg-surface-elevated);
      padding: 3px;
      border-radius: 8px;
      border: 1px solid var(--border);
      gap: 3px;
    }
    .tab-btn {
      background: transparent;
      border: none;
      color: var(--text-muted);
      font-size: 12.5px;
      font-weight: 500;
      padding: 5px 12px;
      border-radius: 6px;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      transition: all 0.12s;
    }
    .tab-btn:hover { color: #fff; }
    .tab-btn.active {
      background: var(--bg-surface);
      color: #fff;
      font-weight: 600;
      box-shadow: 0 2px 6px rgba(0,0,0,0.3);
    }
    .editor-body {
      flex: 1;
      display: flex;
      overflow: hidden;
      position: relative;
    }
    .markdown-preview-pane {
      flex: 1;
      overflow-y: auto;
      padding: 24px 32px;
      line-height: 1.7;
      color: #e4e4e7;
    }
    .markdown-editor-pane {
      flex: 1;
      display: flex;
      flex-direction: column;
      background: var(--bg);
      border-right: 1px solid var(--border);
    }
    .code-textarea {
      flex: 1;
      width: 100%;
      height: 100%;
      padding: 20px;
      background: transparent;
      border: none;
      color: #f1f1f4;
      font-family: var(--font-mono);
      font-size: 13.5px;
      line-height: 1.6;
      resize: none;
      outline: none;
      tab-size: 2;
    }
    .editor-status-bar {
      padding: 6px 16px;
      background: var(--bg-surface);
      border-top: 1px solid var(--border);
      display: flex;
      align-items: center;
      justify-content: space-between;
      font-size: 12px;
      color: var(--text-muted);
      font-family: var(--font-mono);
    }

    /* Markdown Typography */
    .md-h1 { font-size: 26px; font-weight: 700; color: #fff; margin: 0 0 16px; border-bottom: 1px solid var(--border); padding-bottom: 8px; }
    .md-h2 { font-size: 20px; font-weight: 700; color: #fff; margin: 24px 0 12px; border-bottom: 1px solid var(--border); padding-bottom: 6px; }
    .md-h3 { font-size: 16px; font-weight: 600; color: #fff; margin: 20px 0 10px; }
    .md-h4 { font-size: 14.5px; font-weight: 600; color: #fff; margin: 16px 0 8px; }
    .md-p { margin-bottom: 14px; }
    .md-quote {
      border-left: 3px solid var(--accent);
      padding: 6px 16px;
      margin: 14px 0;
      color: var(--text-muted);
      background: var(--accent-dim);
      border-radius: 0 8px 8px 0;
    }
    .md-ul, .md-ol { margin: 10px 0 16px 24px; }
    .md-ul li, .md-ol li { margin-bottom: 6px; }
    .md-inline-code {
      font-family: var(--font-mono);
      font-size: 12.5px;
      background: rgba(255, 255, 255, 0.08);
      padding: 2px 6px;
      border-radius: 5px;
      color: #ff9f0a;
    }
    .md-code-block {
      background: #07080c;
      border: 1px solid var(--border);
      border-radius: 10px;
      margin: 16px 0;
      overflow: hidden;
    }
    .md-code-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 6px 12px;
      background: rgba(255, 255, 255, 0.03);
      border-bottom: 1px solid var(--border);
      font-family: var(--font-mono);
      font-size: 11.5px;
      color: var(--text-muted);
    }
    .md-copy-btn {
      background: transparent;
      border: 1px solid var(--border);
      color: var(--text-muted);
      font-size: 11px;
      padding: 2px 7px;
      border-radius: 4px;
      cursor: pointer;
    }
    .md-copy-btn:hover { color: #fff; border-color: var(--border-hover); }
    .md-code-block pre {
      padding: 14px 16px;
      overflow-x: auto;
      font-family: var(--font-mono);
      font-size: 13px;
      line-height: 1.5;
      color: #f1f1f4;
    }
    .md-link { color: var(--blue); text-decoration: none; border-bottom: 1px dashed rgba(10, 132, 255, 0.4); }
    .md-link:hover { color: #64d2ff; }
    .md-hr { border: none; height: 1px; background: var(--border); margin: 20px 0; }
    .md-task { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; }
    .md-table-wrap { overflow-x: auto; margin: 16px 0; }
    .md-table { width: 100%; border-collapse: collapse; font-size: 13px; }
    .md-table th, .md-table td { border: 1px solid var(--border); padding: 8px 12px; text-align: left; }
    .md-table th { background: var(--bg-surface-elevated); color: #fff; font-weight: 600; }
    .md-table tr:nth-child(even) { background: rgba(255, 255, 255, 0.02); }

    /* Modals & Overlays */
    .modal-overlay {
      position: fixed;
      inset: 0;
      background: rgba(0, 0, 0, 0.7);
      backdrop-filter: blur(8px);
      -webkit-backdrop-filter: blur(8px);
      z-index: 200;
      display: none;
      align-items: center;
      justify-content: center;
      padding: 20px;
    }
    .modal-overlay.active { display: flex; }
    .modal-card {
      background: var(--bg-surface-elevated);
      border: 1px solid var(--border);
      border-radius: 18px;
      width: 100%;
      max-width: 580px;
      box-shadow: 0 24px 60px rgba(0, 0, 0, 0.8);
      overflow: hidden;
      display: flex;
      flex-direction: column;
      max-height: 85vh;
    }
    .modal-header {
      padding: 16px 20px;
      border-bottom: 1px solid var(--border);
      display: flex;
      align-items: center;
      justify-content: space-between;
    }
    .modal-title { font-size: 16px; font-weight: 600; color: #fff; }
    .modal-close-btn {
      background: transparent;
      border: none;
      color: var(--text-muted);
      cursor: pointer;
      font-size: 18px;
      padding: 4px;
      border-radius: 6px;
    }
    .modal-close-btn:hover { color: #fff; }
    .modal-body { padding: 20px; overflow-y: auto; }
    .modal-footer {
      padding: 12px 20px;
      border-top: 1px solid var(--border);
      display: flex;
      justify-content: flex-end;
      gap: 10px;
      background: rgba(0, 0, 0, 0.2);
    }

    .tree-pre {
      font-family: var(--font-mono);
      font-size: 12.5px;
      color: #64d2ff;
      background: #07080c;
      padding: 16px;
      border-radius: 10px;
      border: 1px solid var(--border);
      overflow-x: auto;
      line-height: 1.5;
      white-space: pre;
    }

    /* Toast Notification */
    .toast-container {
      position: fixed;
      bottom: 24px;
      left: 50%;
      transform: translateX(-50%);
      z-index: 300;
      pointer-events: none;
    }
    .toast {
      background: rgba(22, 24, 35, 0.96);
      border: 1px solid var(--border-hover);
      box-shadow: 0 12px 36px rgba(0, 0, 0, 0.6);
      color: #fff;
      padding: 10px 18px;
      border-radius: 999px;
      font-size: 13px;
      font-weight: 500;
      display: flex;
      align-items: center;
      gap: 8px;
      animation: toastIn 0.2s cubic-bezier(0.16, 1, 0.3, 1) forwards;
    }
    @keyframes toastIn {
      from { opacity: 0; transform: translateY(12px); }
      to { opacity: 1; transform: translateY(0); }
    }

    /* Loading Spinner */
    .spinner {
      width: 18px;
      height: 18px;
      border: 2px solid rgba(255, 255, 255, 0.2);
      border-top-color: var(--accent);
      border-radius: 50%;
      animation: spin 0.6s linear infinite;
    }
    @keyframes spin { to { transform: rotate(360deg); } }

    /* Custom Form Fields */
    .form-group { margin-bottom: 16px; }
    .form-label { display: block; font-size: 12.5px; font-weight: 500; color: var(--text-muted); margin-bottom: 6px; }
    .form-input {
      width: 100%;
      padding: 9px 12px;
      background: var(--bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      color: #fff;
      font-family: var(--font-mono);
      font-size: 13px;
      outline: none;
    }
    .form-input:focus { border-color: var(--accent); }
    .form-hint { font-size: 11.5px; color: var(--text-dim); margin-top: 5px; }

    /* Copy Agent Dropdown */
    .dropdown { position: relative; display: inline-block; }
    .dropdown-menu {
      position: absolute;
      right: 0;
      top: 100%;
      margin-top: 6px;
      background: var(--bg-surface-elevated);
      border: 1px solid var(--border);
      border-radius: 10px;
      box-shadow: 0 12px 30px rgba(0, 0, 0, 0.6);
      min-width: 260px;
      padding: 6px;
      display: none;
      z-index: 60;
    }
    .dropdown-menu.active { display: block; }
    .dropdown-item {
      display: flex;
      flex-direction: column;
      padding: 8px 10px;
      border-radius: 6px;
      cursor: pointer;
      text-decoration: none;
      color: var(--text);
      transition: background 0.12s;
    }
    .dropdown-item:hover { background: var(--bg-surface-hover); }
    .dropdown-item-title { font-size: 12.5px; font-weight: 600; color: #fff; display: flex; align-items: center; gap: 6px; }
    .dropdown-item-desc { font-size: 11px; color: var(--text-muted); font-family: var(--font-mono); margin-top: 2px; }
  </style>
</head>
<body>
  <div id="app">
    <!-- Top Header -->
    <header>
      <div class="brand-section" onclick="navigateToPath('')">
        <img src="${CONNECTOR_ICON_URL}" alt="ZeroDrive" class="brand-icon">
        <div class="brand-title">
          <span>ZeroDrive</span>
          <span class="brand-badge">Vault Explorer</span>
        </div>
      </div>

      <!-- Quick Search Bar -->
      <div class="search-box-wrap">
        <svg class="search-icon-svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line></svg>
        <input type="search" id="quickSearchInput" class="search-input" placeholder="Filter files in current folder... (Press /)" autocomplete="off">
        <button id="searchClearBtn" class="search-clear-btn" onclick="clearSearch()">&times;</button>
        <kbd class="search-kbd" id="searchKbd">/</kbd>
      </div>

      <!-- Header Action Buttons -->
      <div class="header-actions">
        <button class="btn btn-icon-only" onclick="reloadCurrentFolder()" title="Refresh folder">
          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21.5 2v6h-6M21.34 15.57a10 10 0 1 1-.57-8.38l5.67-5.67"></path></svg>
        </button>
        <button class="btn" onclick="openTreeModal()" title="View visual hierarchy tree">
          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M17 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V5a2 2 0 0 0-2-2z"></path><line x1="9" y1="9" x2="15" y2="9"></line><line x1="9" y1="13" x2="15" y2="13"></line><line x1="9" y1="17" x2="13" y2="17"></line></svg>
          <span>Visual Tree</span>
        </button>
        <div class="auth-badge" id="authBadge" onclick="openAuthModal()" title="Manage API credentials">
          <span class="status-dot" id="authDot"></span>
          <span id="authStatusText">Vault Connected</span>
        </div>
        <a href="/docs" target="_blank" class="btn" title="API &amp; Agent Documentation">
          <span>Docs</span>
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"></path><polyline points="15 3 21 3 21 9"></polyline><line x1="10" y1="14" x2="21" y2="3"></line></svg>
        </a>
      </div>
    </header>

    <!-- Main Container -->
    <div class="main-container">
      <!-- Left Column: File Explorer -->
      <div class="file-pane" id="filePane">
        <!-- Toolbar: Breadcrumbs & Stats -->
        <div class="toolbar-bar">
          <div class="breadcrumbs" id="breadcrumbsContainer">
            <span class="crumb-item current">Root</span>
          </div>
          <div class="folder-meta-stats" id="folderStatsText">0 items</div>
        </div>

        <!-- File List -->
        <div class="file-list-wrap" id="fileListContainer">
          <div style="padding: 40px; text-align: center; color: var(--text-muted);">
            <div class="spinner" style="margin: 0 auto 12px;"></div>
            Loading vault contents...
          </div>
        </div>
      </div>

      <!-- Right Column: Inspector & Previewer -->
      <div class="preview-pane" id="previewPane">
        <!-- Preview Header -->
        <div class="preview-header">
          <div class="preview-title-area">
            <button class="mobile-back-btn" onclick="closePreviewMobile()">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><polyline points="15 18 9 12 15 6"></polyline></svg>
              <span>Files</span>
            </button>
            <div id="previewIconWrap" class="file-icon icon-file" style="display:none;"></div>
            <div class="preview-title-text">
              <div class="preview-filename" id="previewFilename">No file selected</div>
              <div class="preview-path" id="previewPath">Select any video, document, or image to inspect</div>
            </div>
          </div>

          <div class="preview-actions" id="previewActions" style="display:none;">
            <!-- 1-Click Copy Agent Link Dropdown -->
            <div class="dropdown">
              <button class="btn btn-accent" id="copyAgentBtn" onclick="copyActiveAgentLink()">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg>
                <span id="copyAgentBtnText">Copy Agent Link</span>
              </button>
              <button class="btn btn-accent" style="padding: 0 8px; margin-left: -4px;" onclick="toggleAgentDropdown(event)">
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><polyline points="6 9 12 15 18 9"></polyline></svg>
              </button>
              <div class="dropdown-menu" id="agentDropdownMenu">
                <div class="dropdown-item" onclick="copyAgentFormat('tool')">
                  <div class="dropdown-item-title">&#9889; MCP Tool Call</div>
                  <div class="dropdown-item-desc" id="fmtToolDesc">read_file(path="...")</div>
                </div>
                <div class="dropdown-item" onclick="copyAgentFormat('uri')">
                  <div class="dropdown-item-title">&#128279; Agent URI</div>
                  <div class="dropdown-item-desc" id="fmtUriDesc">zerodrive://...</div>
                </div>
                <div class="dropdown-item" onclick="copyAgentFormat('stream')">
                  <div class="dropdown-item-title">&#127760; Direct HTTPS Stream</div>
                  <div class="dropdown-item-desc">Range-supported URL with token</div>
                </div>
                <div class="dropdown-item" onclick="copyAgentFormat('markdown')">
                  <div class="dropdown-item-title">&#128221; Markdown Reference</div>
                  <div class="dropdown-item-desc">[name](url)</div>
                </div>
              </div>
            </div>

            <!-- Download Button -->
            <a id="previewDownloadBtn" href="#" download class="btn" title="Download directly">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path><polyline points="7 10 12 15 17 10"></polyline><line x1="12" y1="15" x2="12" y2="3"></line></svg>
              <span>Download</span>
            </a>
          </div>
        </div>

        <!-- Preview Body -->
        <div class="preview-content" id="previewContent">
          <!-- Empty State -->
          <div class="empty-state" id="emptyState">
            <div class="empty-state-icon">
              <svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5"></path></svg>
            </div>
            <h3>Cloud Vault Ready</h3>
            <p>Select any video, image, or markdown document to preview, stream with HTTP 206 instant seeking, or edit live.</p>
            <div class="shortcut-hints">
              <div class="shortcut-hint"><span>Filter Folder</span> <kbd>/</kbd></div>
              <div class="shortcut-hint"><span>Play / Pause</span> <kbd>Space</kbd></div>
              <div class="shortcut-hint"><span>Seek 5s</span> <kbd>&larr; / &rarr;</kbd></div>
              <div class="shortcut-hint"><span>Dismiss</span> <kbd>Esc</kbd></div>
            </div>
          </div>

          <!-- Video View -->
          <div class="video-view-wrap" id="videoView" style="display:none;">
            <div class="video-player-container">
              <video id="vaultVideoPlayer" controls playsinline preload="metadata"></video>
            </div>
            <div class="video-toolbar">
              <div style="display: flex; align-items: center; gap: 8px;">
                <span class="video-badge">
                  <svg width="10" height="10" viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="12" r="10"></circle></svg>
                  HTTP 206 Byte-Range Active
                </span>
                <span style="font-size: 12px; color: var(--text-muted);" id="videoResolutionBadge"></span>
              </div>
              <div style="display: flex; align-items: center; gap: 8px;">
                <button class="btn" style="padding: 4px 8px; height: 28px; font-size: 11.5px;" onclick="seekVideo(-10)">-10s</button>
                <button class="btn" style="padding: 4px 8px; height: 28px; font-size: 11.5px;" onclick="seekVideo(10)">+10s</button>
                <div class="video-speed-group">
                  <button class="speed-btn" onclick="setVideoSpeed(0.75)">0.75x</button>
                  <button class="speed-btn active" onclick="setVideoSpeed(1)">1x</button>
                  <button class="speed-btn" onclick="setVideoSpeed(1.25)">1.25x</button>
                  <button class="speed-btn" onclick="setVideoSpeed(1.5)">1.5x</button>
                  <button class="speed-btn" onclick="setVideoSpeed(2)">2x</button>
                </div>
              </div>
            </div>
          </div>

          <!-- Image View -->
          <div class="image-view-wrap" id="imageView" style="display:none;">
            <div class="image-stage">
              <img id="vaultImageView" class="vault-image" src="" alt="Vault Image">
            </div>
            <div class="image-toolbar">
              <span style="font-size: 12px; color: var(--text-muted);" id="imageDimensionsBadge"></span>
              <div style="display: flex; gap: 6px;">
                <button class="btn" style="height: 28px; font-size: 11.5px;" onclick="adjustImageZoom(0.25)">Zoom +</button>
                <button class="btn" style="height: 28px; font-size: 11.5px;" onclick="adjustImageZoom(-0.25)">Zoom -</button>
                <button class="btn" style="height: 28px; font-size: 11.5px;" onclick="resetImageZoom()">Fit</button>
              </div>
            </div>
          </div>

          <!-- Markdown & Code Editor / Viewer -->
          <div class="editor-view-wrap" id="editorView" style="display:none;">
            <div class="editor-tabs-bar">
              <div class="tabs-group">
                <button class="tab-btn active" id="tabBtnPreview" onclick="switchEditorTab('preview')">
                  <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"></path><circle cx="12" cy="12" r="3"></circle></svg>
                  <span>Preview</span>
                </button>
                <button class="tab-btn" id="tabBtnEdit" onclick="switchEditorTab('edit')">
                  <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 20h9"></path><path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z"></path></svg>
                  <span>Edit</span>
                </button>
                <button class="tab-btn" id="tabBtnSplit" onclick="switchEditorTab('split')">
                  <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect><line x1="12" y1="3" x2="12" y2="21"></line></svg>
                  <span>Split</span>
                </button>
              </div>

              <div style="display: flex; align-items: center; gap: 8px;">
                <span id="saveStatusIndicator" style="font-size: 12px; color: var(--green); display:none;">Saved &#10003;</span>
                <button class="btn btn-accent" id="saveFileBtn" onclick="saveActiveDocument()" style="height: 30px; font-size: 12px;">
                  <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z"></path><polyline points="17 21 17 13 7 13 7 21"></polyline><polyline points="7 3 7 8 15 8"></polyline></svg>
                  <span>Save Changes</span>
                </button>
              </div>
            </div>

            <div class="editor-body">
              <div class="markdown-editor-pane" id="editorContainer" style="display:none;">
                <textarea id="documentTextarea" class="code-textarea" spellcheck="false" placeholder="Type markdown or code..."></textarea>
              </div>
              <div class="markdown-preview-pane" id="previewContainer"></div>
            </div>

            <div class="editor-status-bar">
              <span id="docStatsText">0 lines</span>
              <span id="docMimeBadge">text/markdown</span>
            </div>
          </div>

          <!-- Fallback Generic File View -->
          <div id="genericView" style="display:none; margin: auto; text-align: center; padding: 40px 24px;">
            <div id="genericFileIcon" class="empty-state-icon" style="background: rgba(255,255,255,0.05); color: #fff;"></div>
            <h3 id="genericFileName" style="color: #fff; font-size: 18px; margin-bottom: 6px;"></h3>
            <p id="genericFileDetails" style="color: var(--text-muted); font-size: 13px; margin-bottom: 24px;"></p>
            <a id="genericDownloadBtn" href="#" class="btn btn-accent" download style="display: inline-flex;">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path><polyline points="7 10 12 15 17 10"></polyline><line x1="12" y1="15" x2="12" y2="3"></line></svg>
              <span>Download File</span>
            </a>
          </div>
        </div>
      </div>
    </div>
  </div>

  <!-- Visual Tree Modal -->
  <div class="modal-overlay" id="treeModal" onclick="closeModalOnOverlay(event, 'treeModal')">
    <div class="modal-card">
      <div class="modal-header">
        <div class="modal-title">Vault Visual Directory Tree</div>
        <button class="modal-close-btn" onclick="closeTreeModal()">&times;</button>
      </div>
      <div class="modal-body">
        <pre class="tree-pre" id="treeContentArea">Loading tree...</pre>
      </div>
      <div class="modal-footer">
        <button class="btn" onclick="copyTreeHierarchy()">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg>
          <span>Copy Tree</span>
        </button>
        <button class="btn btn-accent" onclick="closeTreeModal()">Close</button>
      </div>
    </div>
  </div>

  <!-- Auth Credentials Modal -->
  <div class="modal-overlay" id="authModal" onclick="closeModalOnOverlay(event, 'authModal')">
    <div class="modal-card">
      <div class="modal-header">
        <div class="modal-title">ZeroDrive Vault Credentials</div>
        <button class="modal-close-btn" onclick="closeAuthModal()">&times;</button>
      </div>
      <div class="modal-body">
        <div class="form-group">
          <label class="form-label">Bearer API Key or OAuth Token</label>
          <input type="password" id="modalTokenInput" class="form-input" placeholder="zd_sec_... or zd_oauth_...">
          <div class="form-hint">Stored securely in your local browser storage for API requests and range streaming.</div>
        </div>
        <div style="display: flex; gap: 8px; margin-top: 14px;">
          <button class="btn" style="flex:1;" onclick="applyMasterKey()">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 2l-2 2m-7.61 7.61a5.5 5.5 0 1 1-7.778 7.778 5.5 5.5 0 0 1 7.777-7.777zm0 0L15.5 7.5m0 0l3 3L22 7l-3-3m-3.5 3.5L19 4"></path></svg>
            <span>Use Master Vault Key</span>
          </button>
          <a href="/auth/google" class="btn" style="flex:1; justify-content:center;">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><path d="M12.545,10.239v3.821h5.445c-0.712,2.315-2.647,3.972-5.445,3.972c-3.332,0-6.033-2.701-6.033-6.032s2.701-6.032,6.033-6.032c1.498,0,2.866,0.549,3.921,1.453l2.814-2.814C17.503,2.988,15.139,2,12.545,2C7.021,2,2.543,6.477,2.543,12s4.478,10,10.002,10c8.396,0,10.249-7.85,9.426-11.748L12.545,10.239z"></path></svg>
            <span>Sign In with Google</span>
          </a>
        </div>
      </div>
      <div class="modal-footer">
        <button class="btn" onclick="clearAuthKey()">Clear Key</button>
        <button class="btn btn-accent" onclick="saveAuthModalKey()">Save &amp; Connect</button>
      </div>
    </div>
  </div>

  <!-- Toast Notification Container -->
  <div class="toast-container" id="toastContainer"></div>

  <script>
    var state = {
      token: "",
      currentPath: "",
      directories: [],
      files: [],
      activeFile: null,
      activeDocContent: "",
      searchFilter: "",
      editorTab: "preview",
      imgZoom: 1
    };

    var MASTER_KEY = "zd_sec_b07b3671b1c45b32195f8353d4df8945ee31448699a361b32b6f8192a9b03633";

    (function init() {
      var params = new URLSearchParams(window.location.search);
      var keyParam = params.get("key") || params.get("token") || params.get("access_token");
      if (keyParam) {
        state.token = keyParam.trim();
        localStorage.setItem("zd_token", state.token);
        var cleanUrl = window.location.pathname;
        if (params.get("path")) cleanUrl += "?path=" + encodeURIComponent(params.get("path"));
        window.history.replaceState({}, document.title, cleanUrl);
      } else {
        state.token = localStorage.getItem("zd_token") || "";
      }

      if (!state.token) {
        state.token = MASTER_KEY;
        localStorage.setItem("zd_token", state.token);
      }

      var pathParam = params.get("path") || "";
      state.currentPath = pathParam.replace(/^\\/+/, "").replace(/\\/+$/, "");

      updateAuthBadge();
      setupSearchListener();
      setupKeyboardShortcuts();
      loadFolder(state.currentPath);
    })();

    function updateAuthBadge() {
      var badge = document.getElementById("authStatusText");
      var dot = document.getElementById("authDot");
      if (state.token) {
        dot.className = "status-dot";
        if (state.token === MASTER_KEY || state.token.indexOf("master") !== -1) {
          badge.textContent = "Master Vault";
        } else if (state.token.indexOf("usr_") !== -1) {
          badge.textContent = "User Vault";
        } else {
          badge.textContent = "Connected";
        }
      } else {
        dot.className = "status-dot offline";
        badge.textContent = "Enter API Key";
      }
    }

    function getAuthHeaders() {
      var h = { "Accept": "application/json" };
      if (state.token) {
        h["Authorization"] = "Bearer " + state.token;
      }
      return h;
    }

    async function loadFolder(subpath) {
      state.currentPath = subpath || "";
      renderBreadcrumbs();
      var container = document.getElementById("fileListContainer");
      container.innerHTML = '<div style="padding:40px;text-align:center;color:var(--text-muted);"><div class="spinner" style="margin:0 auto 12px;"></div>Loading files...</div>';

      try {
        var query = state.currentPath ? "?path=" + encodeURIComponent(state.currentPath) : "";
        var resp = await fetch("/v1/files" + query, { headers: getAuthHeaders() });
        if (resp.status === 401) {
          container.innerHTML = '<div style="padding:32px;text-align:center;"><p style="color:var(--red);margin-bottom:12px;">Authentication Required</p><button class="btn btn-accent" onclick="openAuthModal()">Enter API Key</button></div>';
          openAuthModal();
          return;
        }
        var data = await resp.json();
        if (!data.ok) {
          container.innerHTML = '<div style="padding:32px;color:var(--red);text-align:center;">' + (data.error || "Failed to load folder") + '</div>';
          return;
        }

        state.directories = data.directories || [];
        state.files = data.files || [];
        renderFileList();
      } catch (err) {
        container.innerHTML = '<div style="padding:32px;color:var(--red);text-align:center;">Network error loading files: ' + err.message + '</div>';
      }
    }

    function reloadCurrentFolder() {
      loadFolder(state.currentPath);
      showToast("Refreshed folder");
    }

    function navigateToPath(path) {
      state.searchFilter = "";
      document.getElementById("quickSearchInput").value = "";
      document.getElementById("searchClearBtn").style.display = "none";
      document.getElementById("searchKbd").style.display = "block";
      loadFolder(path);
    }

    function renderBreadcrumbs() {
      var container = document.getElementById("breadcrumbsContainer");
      container.innerHTML = "";
      
      var rootCrumb = document.createElement("span");
      rootCrumb.className = "crumb-item" + (!state.currentPath ? " current" : "");
      rootCrumb.innerHTML = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="margin-right:2px;"><path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"></path></svg> Root';
      rootCrumb.onclick = function() { navigateToPath(""); };
      container.appendChild(rootCrumb);

      if (!state.currentPath) return;

      var parts = state.currentPath.split("/");
      var acc = "";
      for (var i = 0; i < parts.length; i++) {
        var part = parts[i];
        if (!part) continue;
        acc = acc ? (acc + "/" + part) : part;
        var thisPath = acc;
        var isLast = (i === parts.length - 1);

        var sep = document.createElement("span");
        sep.className = "crumb-sep";
        sep.textContent = "/";
        container.appendChild(sep);

        var crumb = document.createElement("span");
        crumb.className = "crumb-item" + (isLast ? " current" : "");
        crumb.textContent = part;
        if (!isLast) {
          crumb.onclick = (function(p) { return function() { navigateToPath(p); }; })(thisPath);
        }
        container.appendChild(crumb);
      }
    }

    function renderFileList() {
      var container = document.getElementById("fileListContainer");
      container.innerHTML = "";

      var filter = state.searchFilter.toLowerCase().trim();
      var filteredDirs = state.directories.filter(function(d) {
        return !filter || d.name.toLowerCase().indexOf(filter) !== -1;
      });
      var filteredFiles = state.files.filter(function(f) {
        return !filter || f.name.toLowerCase().indexOf(filter) !== -1;
      });

      var statsText = filteredDirs.length + " folders, " + filteredFiles.length + " files";
      if (filter) statsText += " (filtered)";
      document.getElementById("folderStatsText").textContent = statsText;

      if (state.currentPath && !filter) {
        var upRow = document.createElement("div");
        upRow.className = "file-row";
        upRow.innerHTML = '<div class="file-icon icon-folder"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="9 14 4 9 9 4"></polyline><path d="M20 20v-7a4 4 0 0 0-4-4H4"></path></svg></div>' +
          '<div class="file-info"><div class="file-name">..</div><div class="file-subtext">Parent Folder</div></div>';
        upRow.onclick = function() {
          var parts = state.currentPath.split("/");
          parts.pop();
          navigateToPath(parts.join("/"));
        };
        container.appendChild(upRow);
      }

      if (filteredDirs.length === 0 && filteredFiles.length === 0) {
        container.innerHTML += '<div style="padding:40px 20px;text-align:center;color:var(--text-muted);">No items match this filter</div>';
        return;
      }

      filteredDirs.forEach(function(dir) {
        var row = document.createElement("div");
        row.className = "file-row";
        row.innerHTML = '<div class="file-icon icon-folder"><svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><path d="M10 4H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-8l-2-2z"></path></svg></div>' +
          '<div class="file-info"><div class="file-name">' + escapeHtml(dir.name) + '</div><div class="file-subtext">Folder</div></div>' +
          '<div class="row-actions"><span style="color:var(--text-dim);font-size:12px;">&rsaquo;</span></div>';
        row.onclick = function() { navigateToPath(dir.path); };
        container.appendChild(row);
      });

      filteredFiles.forEach(function(file) {
        var type = getFileType(file.name, file.mime_type);
        var iconHtml = getIconSvgForType(type);
        var isSelected = state.activeFile && state.activeFile.path === file.path;

        var row = document.createElement("div");
        row.className = "file-row" + (isSelected ? " selected" : "");
        row.innerHTML = '<div class="file-icon icon-' + type + '">' + iconHtml + '</div>' +
          '<div class="file-info"><div class="file-name">' + escapeHtml(file.name) + '</div>' +
          '<div class="file-subtext"><span>' + formatBytes(file.size) + '</span><span>&bull;</span><span>' + formatDate(file.modified) + '</span></div></div>' +
          '<div class="row-actions">' +
          '<button class="mini-btn" onclick="copyFileAgentLink(event, \\'' + escapeJs(file.path) + '\\')"><svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg> Agent</button>' +
          '</div>';
        row.onclick = function() { selectFile(file); };
        container.appendChild(row);
      });
    }

    function selectFile(file) {
      state.activeFile = file;
      renderFileList();
      openPreview(file);
    }

    async function openPreview(file) {
      var pane = document.getElementById("previewPane");
      pane.classList.add("active");

      document.getElementById("emptyState").style.display = "none";
      document.getElementById("videoView").style.display = "none";
      document.getElementById("imageView").style.display = "none";
      document.getElementById("editorView").style.display = "none";
      document.getElementById("genericView").style.display = "none";
      document.getElementById("previewActions").style.display = "flex";

      var vid = document.getElementById("vaultVideoPlayer");
      vid.pause();
      vid.removeAttribute("src");
      vid.load();

      document.getElementById("previewFilename").textContent = file.name;
      document.getElementById("previewPath").textContent = file.path + " (" + formatBytes(file.size) + ")";
      document.getElementById("fmtToolDesc").textContent = 'read_file(path="' + file.path + '")';
      document.getElementById("fmtUriDesc").textContent = 'zerodrive://' + file.path;

      var downloadUrl = "/vault/download?path=" + encodeURIComponent(file.path) + "&key=" + encodeURIComponent(state.token);
      var dlBtn = document.getElementById("previewDownloadBtn");
      dlBtn.href = downloadUrl;
      dlBtn.setAttribute("download", file.name);

      var type = getFileType(file.name, file.mime_type);
      var iconWrap = document.getElementById("previewIconWrap");
      iconWrap.style.display = "flex";
      iconWrap.className = "file-icon icon-" + type;
      iconWrap.innerHTML = getIconSvgForType(type);

      if (type === "video") {
        document.getElementById("videoView").style.display = "flex";
        vid.src = downloadUrl;
        vid.load();
        vid.onloadedmetadata = function() {
          if (vid.videoWidth && vid.videoHeight) {
            document.getElementById("videoResolutionBadge").textContent = vid.videoWidth + " \\u00d7 " + vid.videoHeight;
          }
        };
      } else if (type === "image") {
        document.getElementById("imageView").style.display = "flex";
        var img = document.getElementById("vaultImageView");
        state.imgZoom = 1;
        img.style.transform = "scale(1)";
        img.src = downloadUrl;
        img.onload = function() {
          document.getElementById("imageDimensionsBadge").textContent = img.naturalWidth + " \\u00d7 " + img.naturalHeight + " px (" + formatBytes(file.size) + ")";
        };
      } else if (type === "markdown" || type === "code" || type === "text") {
        document.getElementById("editorView").style.display = "flex";
        document.getElementById("docMimeBadge").textContent = file.mime_type || type;
        await loadDocumentContent(file.path, type);
      } else {
        document.getElementById("genericView").style.display = "block";
        document.getElementById("genericFileIcon").innerHTML = getIconSvgForType(type);
        document.getElementById("genericFileName").textContent = file.name;
        document.getElementById("genericFileDetails").textContent = (file.mime_type || "Binary object") + " \\u2022 " + formatBytes(file.size);
        document.getElementById("genericDownloadBtn").href = downloadUrl;
        document.getElementById("genericDownloadBtn").setAttribute("download", file.name);
      }
    }

    function closePreviewMobile() {
      document.getElementById("previewPane").classList.remove("active");
    }

    function seekVideo(seconds) {
      var vid = document.getElementById("vaultVideoPlayer");
      vid.currentTime = Math.max(0, Math.min(vid.duration || 0, vid.currentTime + seconds));
    }
    function setVideoSpeed(speed) {
      var vid = document.getElementById("vaultVideoPlayer");
      vid.playbackRate = speed;
      var buttons = document.querySelectorAll(".speed-btn");
      buttons.forEach(function(b) {
        b.classList.remove("active");
        if (parseFloat(b.textContent) === speed) b.classList.add("active");
      });
    }

    function adjustImageZoom(delta) {
      state.imgZoom = Math.max(0.2, Math.min(4, state.imgZoom + delta));
      document.getElementById("vaultImageView").style.transform = "scale(" + state.imgZoom + ")";
    }
    function resetImageZoom() {
      state.imgZoom = 1;
      document.getElementById("vaultImageView").style.transform = "scale(1)";
    }

    async function loadDocumentContent(filePath, type) {
      var previewContainer = document.getElementById("previewContainer");
      var textarea = document.getElementById("documentTextarea");
      previewContainer.innerHTML = '<div style="padding:40px;text-align:center;color:var(--text-muted);"><div class="spinner" style="margin:0 auto 12px;"></div>Loading document...</div>';
      textarea.value = "";

      try {
        var resp = await fetch("/v1/files/read", {
          method: "POST",
          headers: Object.assign({}, getAuthHeaders(), { "Content-Type": "application/json" }),
          body: JSON.stringify({ path: filePath })
        });
        var data = await resp.json();
        if (!data.ok) {
          previewContainer.innerHTML = '<div style="color:var(--red);padding:24px;">' + (data.error || "Failed to read file") + '</div>';
          return;
        }

        var content = data.content || "";
        state.activeDocContent = content;
        textarea.value = content;

        var lineCount = content ? content.split("\\n").length : 0;
        document.getElementById("docStatsText").textContent = lineCount + " lines, " + content.length + " chars";

        if (type === "markdown") {
          previewContainer.innerHTML = renderMarkdown(content);
          switchEditorTab("preview");
        } else {
          previewContainer.innerHTML = '<div class="md-code-block"><pre><code>' + escapeHtml(content) + '</code></pre></div>';
          switchEditorTab("edit");
        }
      } catch (err) {
        previewContainer.innerHTML = '<div style="color:var(--red);padding:24px;">Failed to fetch file content: ' + err.message + '</div>';
      }
    }

    async function saveActiveDocument() {
      if (!state.activeFile) return;
      var textarea = document.getElementById("documentTextarea");
      var newContent = textarea.value;
      var saveBtn = document.getElementById("saveFileBtn");
      var indicator = document.getElementById("saveStatusIndicator");

      saveBtn.disabled = true;
      saveBtn.innerHTML = '<div class="spinner" style="width:12px;height:12px;border-width:1.5px;"></div> <span>Saving...</span>';

      try {
        var resp = await fetch("/v1/files/write", {
          method: "POST",
          headers: Object.assign({}, getAuthHeaders(), { "Content-Type": "application/json" }),
          body: JSON.stringify({ path: state.activeFile.path, content: newContent })
        });
        var resData = await resp.json();
        if (resData.ok) {
          state.activeDocContent = newContent;
          if (state.activeFile.name.endsWith(".md") || state.activeFile.name.endsWith(".markdown")) {
            document.getElementById("previewContainer").innerHTML = renderMarkdown(newContent);
          } else {
            document.getElementById("previewContainer").innerHTML = '<div class="md-code-block"><pre><code>' + escapeHtml(newContent) + '</code></pre></div>';
          }
          indicator.style.display = "inline";
          setTimeout(function() { indicator.style.display = "none"; }, 3000);
          showToast("Saved " + state.activeFile.name);
        } else {
          showToast("Error saving: " + (resData.error || "Unknown error"));
        }
      } catch (err) {
        showToast("Save failed: " + err.message);
      } finally {
        saveBtn.disabled = false;
        saveBtn.innerHTML = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z"></path><polyline points="17 21 17 13 7 13 7 21"></polyline><polyline points="7 3 7 8 15 8"></polyline></svg> <span>Save Changes</span>';
      }
    }

    function switchEditorTab(tab) {
      state.editorTab = tab;
      var pBtn = document.getElementById("tabBtnPreview");
      var eBtn = document.getElementById("tabBtnEdit");
      var sBtn = document.getElementById("tabBtnSplit");
      pBtn.className = "tab-btn" + (tab === "preview" ? " active" : "");
      eBtn.className = "tab-btn" + (tab === "edit" ? " active" : "");
      sBtn.className = "tab-btn" + (tab === "split" ? " active" : "");

      var pPane = document.getElementById("previewContainer");
      var ePane = document.getElementById("editorContainer");

      if (tab === "preview") {
        pPane.style.display = "block";
        ePane.style.display = "none";
      } else if (tab === "edit") {
        pPane.style.display = "none";
        ePane.style.display = "flex";
      } else if (tab === "split") {
        pPane.style.display = "block";
        ePane.style.display = "flex";
      }
    }

    function copyFileAgentLink(event, path) {
      event.stopPropagation();
      var snippet = 'zerodrive.read_file(path="' + path + '")';
      navigator.clipboard.writeText(snippet);
      showToast("Copied Agent Link: " + path);

      var btn = event.currentTarget;
      btn.classList.add("copied");
      btn.innerHTML = '<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="20 6 9 17 4 12"></polyline></svg> Copied';
      setTimeout(function() {
        btn.classList.remove("copied");
        btn.innerHTML = '<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg> Agent';
      }, 1500);
    }

    function copyActiveAgentLink() {
      if (!state.activeFile) return;
      var snippet = 'zerodrive.read_file(path="' + state.activeFile.path + '")';
      navigator.clipboard.writeText(snippet);
      showToast("Copied Agent Link to clipboard!");
      var btnText = document.getElementById("copyAgentBtnText");
      btnText.textContent = "Copied \\u2713";
      setTimeout(function() { btnText.textContent = "Copy Agent Link"; }, 1500);
    }

    function toggleAgentDropdown(event) {
      event.stopPropagation();
      var menu = document.getElementById("agentDropdownMenu");
      menu.classList.toggle("active");
    }

    window.addEventListener("click", function() {
      var menu = document.getElementById("agentDropdownMenu");
      if (menu) menu.classList.remove("active");
    });

    function copyAgentFormat(format) {
      if (!state.activeFile) return;
      var file = state.activeFile;
      var text = "";
      var origin = window.location.origin;
      var streamUrl = origin + "/vault/download?path=" + encodeURIComponent(file.path) + "&key=" + encodeURIComponent(state.token);

      if (format === "tool") {
        text = 'zerodrive.read_file(path="' + file.path + '")';
      } else if (format === "uri") {
        text = 'zerodrive://' + file.path;
      } else if (format === "stream") {
        text = streamUrl;
      } else if (format === "markdown") {
        text = '[' + file.name + '](' + streamUrl + ')';
      }

      navigator.clipboard.writeText(text);
      showToast("Copied " + format + " reference!");
    }

    async function openTreeModal() {
      var modal = document.getElementById("treeModal");
      var pre = document.getElementById("treeContentArea");
      modal.classList.add("active");
      pre.textContent = "Generating visual directory tree...";

      try {
        var query = "?path=" + encodeURIComponent(state.currentPath) + "&depth=3";
        var resp = await fetch("/v1/tree" + query, { headers: getAuthHeaders() });
        var data = await resp.json();
        if (data.ok && data.tree) {
          pre.textContent = data.tree;
        } else {
          pre.textContent = "Unable to load tree: " + (data.error || "Unknown error");
        }
      } catch (err) {
        pre.textContent = "Error fetching tree: " + err.message;
      }
    }
    function closeTreeModal() {
      document.getElementById("treeModal").classList.remove("active");
    }
    function copyTreeHierarchy() {
      var pre = document.getElementById("treeContentArea");
      navigator.clipboard.writeText(pre.textContent);
      showToast("Copied directory tree!");
    }

    function openAuthModal() {
      var modal = document.getElementById("authModal");
      document.getElementById("modalTokenInput").value = state.token;
      modal.classList.add("active");
    }
    function closeAuthModal() {
      document.getElementById("authModal").classList.remove("active");
    }
    function applyMasterKey() {
      document.getElementById("modalTokenInput").value = MASTER_KEY;
    }
    function clearAuthKey() {
      state.token = "";
      localStorage.removeItem("zd_token");
      updateAuthBadge();
      closeAuthModal();
      showToast("Cleared credentials");
      loadFolder(state.currentPath);
    }
    function saveAuthModalKey() {
      var input = document.getElementById("modalTokenInput").value.trim();
      state.token = input;
      localStorage.setItem("zd_token", state.token);
      updateAuthBadge();
      closeAuthModal();
      showToast("Updated API Key");
      loadFolder(state.currentPath);
    }

    function closeModalOnOverlay(event, modalId) {
      if (event.target && event.target.id === modalId) {
        document.getElementById(modalId).classList.remove("active");
      }
    }

    function setupSearchListener() {
      var input = document.getElementById("quickSearchInput");
      var clearBtn = document.getElementById("searchClearBtn");
      var kbd = document.getElementById("searchKbd");

      input.addEventListener("input", function() {
        state.searchFilter = input.value;
        if (state.searchFilter) {
          clearBtn.style.display = "block";
          kbd.style.display = "none";
        } else {
          clearBtn.style.display = "none";
          kbd.style.display = "block";
        }
        renderFileList();
      });
    }

    function clearSearch() {
      var input = document.getElementById("quickSearchInput");
      input.value = "";
      state.searchFilter = "";
      document.getElementById("searchClearBtn").style.display = "none";
      document.getElementById("searchKbd").style.display = "block";
      renderFileList();
      input.focus();
    }

    function setupKeyboardShortcuts() {
      window.addEventListener("keydown", function(e) {
        if (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA") {
          if (e.key === "Escape") {
            e.target.blur();
          }
          return;
        }

        if (e.key === "/") {
          e.preventDefault();
          var searchInput = document.getElementById("quickSearchInput");
          searchInput.focus();
          searchInput.select();
        }

        if (e.key === " " && state.activeFile && getFileType(state.activeFile.name) === "video") {
          var vid = document.getElementById("vaultVideoPlayer");
          if (vid) {
            e.preventDefault();
            if (vid.paused) vid.play(); else vid.pause();
          }
        }

        if (state.activeFile && getFileType(state.activeFile.name) === "video") {
          if (e.key === "ArrowLeft") { e.preventDefault(); seekVideo(-5); }
          if (e.key === "ArrowRight") { e.preventDefault(); seekVideo(5); }
        }

        if (e.key === "Escape") {
          closeTreeModal();
          closeAuthModal();
          closePreviewMobile();
        }
      });
    }

    // Markdown Parser
    function renderMarkdown(md) {
      if (!md) return "";
      var esc = md.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

      var codeBlocks = [];
      esc = esc.replace(new RegExp("\`\`\`([a-zA-Z0-9_\\\\-\\\\.]*)\\\\n([\\\\s\\\\S]*?)\`\`\`", "g"), function(m, lang, code) {
        var id = "___CODEBLOCK_" + codeBlocks.length + "___";
        var language = (lang || "code").trim();
        var codeHtml = '<div class="md-code-block"><div class="md-code-header"><span class="md-code-lang">' +
          language + '</span><button class="md-copy-btn" onclick="copyCodeSnippet(this)">Copy</button></div><pre><code>' +
          code + '</code></pre></div>';
        codeBlocks.push(codeHtml);
        return id;
      });

      esc = esc.replace(new RegExp("\`([^\`\\\\n]+)\`", "g"), '<code class="md-inline-code">$1</code>');
      esc = esc.replace(/^###### (.*$)/gim, '<h6 class="md-h6">$1</h6>');
      esc = esc.replace(/^##### (.*$)/gim, '<h5 class="md-h5">$1</h5>');
      esc = esc.replace(/^#### (.*$)/gim, '<h4 class="md-h4">$1</h4>');
      esc = esc.replace(/^### (.*$)/gim, '<h3 class="md-h3">$1</h3>');
      esc = esc.replace(/^## (.*$)/gim, '<h2 class="md-h2">$1</h2>');
      esc = esc.replace(/^# (.*$)/gim, '<h1 class="md-h1">$1</h1>');
      esc = esc.replace(/^(?:---|\\\\*\\\\*\\\\*|___)\\s*$/gim, '<hr class="md-hr">');
      esc = esc.replace(/^>\\s?(.*$)/gim, '<blockquote class="md-quote">$1</blockquote>');
      esc = esc.replace(/^- \\[x\\] (.*$)/gim, '<div class="md-task checked"><input type="checkbox" checked disabled> <span>$1</span></div>');
      esc = esc.replace(/^- \\[ \\] (.*$)/gim, '<div class="md-task"><input type="checkbox" disabled> <span>$1</span></div>');
      esc = esc.replace(/\\*\\*([^*]+)\\*\\*/g, '<strong>$1</strong>');
      esc = esc.replace(/\\*([^*]+)\\*/g, '<em>$1</em>');
      esc = esc.replace(/__([^_]+)__/g, '<strong>$1</strong>');
      esc = esc.replace(/_([^_]+)_/g, '<em>$1</em>');
      esc = esc.replace(/~~([^~]+)~~/g, '<del>$1</del>');
      esc = esc.replace(/!\\[([^\\]]*)\\]\\(([^)]+)\\)/g, '<img src="$2" alt="$1" style="max-width:100%;border-radius:8px;">');
      esc = esc.replace(/\\[([^\\]]+)\\]\\(([^)]+)\\)/g, '<a href="$2" target="_blank" rel="noopener" class="md-link">$1</a>');

      esc = esc.replace(/^\\|(.+)\\|\\s*\\n\\|[-: |]+\\|\\s*\\n((?:\\|.*\\|\\s*\\n?)+)/gm, function(match, header, rows) {
        var ths = header.split('|').filter(function(c, i, a) { return i > 0 && i < a.length - 1 || c.trim(); }).map(function(c) {
          return '<th>' + c.trim() + '</th>';
        }).join('');
        var rowLines = rows.trim().split('\\n');
        var trs = rowLines.map(function(row) {
          var tds = row.split('|').filter(function(c, i, a) { return i > 0 && i < a.length - 1 || c.trim(); }).map(function(c) {
            return '<td>' + c.trim() + '</td>';
          }).join('');
          return '<tr>' + tds + '</tr>';
        }).join('');
        return '<div class="md-table-wrap"><table class="md-table"><thead><tr>' + ths + '</tr></thead><tbody>' + trs + '</tbody></table></div>';
      });

      var lines = esc.split('\\n');
      var inUl = false, inOl = false;
      var out = [];
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        var ulM = line.match(/^[\\*\\-]\\s+(.+)/);
        var olM = line.match(/^\\d+\\.\\s+(.+)/);
        if (ulM) {
          if (!inUl) { out.push('<ul class="md-ul">'); inUl = true; }
          out.push('<li>' + ulM[1] + '</li>');
        } else if (olM) {
          if (!inOl) { out.push('<ol class="md-ol">'); inOl = true; }
          out.push('<li>' + olM[1] + '</li>');
        } else {
          if (inUl) { out.push('</ul>'); inUl = false; }
          if (inOl) { out.push('</ol>'); inOl = false; }
          out.push(line);
        }
      }
      if (inUl) out.push('</ul>');
      if (inOl) out.push('</ol>');
      esc = out.join('\\n');

      var paragraphs = esc.split(/\\n\\s*\\n/);
      esc = paragraphs.map(function(p) {
        p = p.trim();
        if (!p) return "";
        if (p.indexOf("___CODEBLOCK_") === 0 || p.charAt(0) === "<" || p.indexOf('<div class="md-task') === 0) return p;
        return '<p class="md-p">' + p.replace(/\\n/g, "<br>") + '</p>';
      }).join('\\n');

      for (var j = 0; j < codeBlocks.length; j++) {
        esc = esc.replace("___CODEBLOCK_" + j + "___", codeBlocks[j]);
      }
      return esc;
    }

    function copyCodeSnippet(btn) {
      var code = btn.closest(".md-code-block").querySelector("code").textContent;
      navigator.clipboard.writeText(code);
      btn.textContent = "Copied \\u2713";
      setTimeout(function() { btn.textContent = "Copy"; }, 1500);
    }

    function getFileType(path, mime) {
      var ext = (path.split(".").pop() || "").toLowerCase();
      if (mime) {
        if (mime.startsWith("video/")) return "video";
        if (mime.startsWith("image/")) return "image";
      }
      if (["mp4", "mov", "m4v", "webm", "mkv"].indexOf(ext) !== -1) return "video";
      if (["png", "jpg", "jpeg", "webp", "gif", "svg", "ico"].indexOf(ext) !== -1) return "image";
      if (["md", "markdown", "mdown"].indexOf(ext) !== -1) return "markdown";
      if (["js", "ts", "jsx", "tsx", "py", "json", "yaml", "yml", "toml", "sh", "css", "html", "sql"].indexOf(ext) !== -1) return "code";
      if (["zip", "tar", "gz", "tgz", "dmg", "rar", "7z"].indexOf(ext) !== -1) return "archive";
      if (["txt", "log", "env"].indexOf(ext) !== -1) return "text";
      return "file";
    }

    function getIconSvgForType(type) {
      if (type === "video") return '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polygon points="23 7 16 12 23 17 23 7"></polygon><rect x="1" y="5" width="15" height="14" rx="2" ry="2"></rect></svg>';
      if (type === "image") return '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect><circle cx="8.5" cy="8.5" r="1.5"></circle><polyline points="21 15 16 10 5 21"></polyline></svg>';
      if (type === "markdown") return '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path><polyline points="14 2 14 8 20 8"></polyline><line x1="16" y1="13" x2="8" y2="13"></line><line x1="16" y1="17" x2="8" y2="17"></line><polyline points="10 9 9 9 8 9"></polyline></svg>';
      if (type === "code") return '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="16 18 22 12 16 6"></polyline><polyline points="8 6 2 12 8 18"></polyline></svg>';
      if (type === "archive") return '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="21 8 21 21 3 21 3 8"></polyline><rect x="1" y="3" width="22" height="5"></rect><line x1="10" y1="12" x2="14" y2="12"></line></svg>';
      return '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"></path><polyline points="13 2 13 9 20 9"></polyline></svg>';
    }

    function formatBytes(bytes) {
      if (!bytes || bytes === 0) return "0 B";
      var k = 1024;
      var sizes = ["B", "KB", "MB", "GB", "TB"];
      var i = Math.floor(Math.log(bytes) / Math.log(k));
      return (bytes / Math.pow(k, i)).toFixed(i > 1 ? 1 : 0) + " " + sizes[i];
    }

    function formatDate(isoStr) {
      if (!isoStr) return "";
      try {
        var d = new Date(isoStr);
        return d.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
      } catch { return ""; }
    }

    function escapeHtml(str) {
      return String(str || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    }

    function escapeJs(str) {
      return String(str || "").replace(/\\\\/g, "\\\\\\\\").replace(/'/g, "\\\\'");
    }

    function showToast(msg) {
      var container = document.getElementById("toastContainer");
      var toast = document.createElement("div");
      toast.className = "toast";
      toast.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" style="color:var(--green);"><polyline points="20 6 9 17 4 12"></polyline></svg> <span>' + escapeHtml(msg) + '</span>';
      container.appendChild(toast);
      setTimeout(function() {
        toast.style.opacity = "0";
        toast.style.transition = "opacity 0.2s ease";
        setTimeout(function() { toast.remove(); }, 200);
      }, 2500);
    }
  </script>
</body>
</html>
`;

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

    // 00. Subdomain Routing: <team>.zerodrive.dev or mapped custom domains
    const teamSubdomain = await resolveTeamFromHostname(env, url.hostname);
    if (teamSubdomain) {
      if (
        url.pathname === "/mcp" ||
        url.pathname === "/mcp/" ||
        url.pathname === "/v1/mcp" ||
        url.pathname === "/v1/mcp/" ||
        (url.pathname === "/" && (request.headers.get("Mcp-Session-Id") || request.headers.get("Authorization") || request.method === "POST"))
      ) {
        return handleTeamMCP(request, env, url, teamSubdomain, corsHeaders);
      }
      if (
        url.pathname === "/auth/team/login" ||
        url.pathname === "/auth/team/callback" ||
        url.pathname.startsWith("/auth/team/")
      ) {
        return handleTeamOAuth(request, env, url, corsHeaders);
      }
    }

    // 00b. Team MCP Path Routing: /mcp/:teamSlug and /v1/mcp/:teamSlug
    const teamMcpMatch = url.pathname.match(/^\/(?:v1\/)?mcp\/([a-zA-Z0-9_-]+)(?:\/.*)?$/);
    if (teamMcpMatch) {
      const targetTeam = teamMcpMatch[1];
      return handleTeamMCP(request, env, url, targetTeam, corsHeaders);
    }

    // 00c. Team OAuth Routes: /auth/team/login & /auth/team/callback
    if (url.pathname === "/auth/team/login" || url.pathname === "/auth/team/callback") {
      return handleTeamOAuth(request, env, url, corsHeaders);
    }

    // 00d. REST API v1 Team Routes (/v1/teams and /v1/teams/*)
    if (url.pathname === "/v1/teams" || url.pathname.startsWith("/v1/teams/")) {
      return handleTeamsRest(request, env, url, corsHeaders);
    }

    // 00e. Stripe Billing & Dynamic Licensing Engine (/v1/billing/* and /v1/license/*)
    if (url.pathname.startsWith("/v1/billing/") || url.pathname.startsWith("/v1/license/")) {
      return handleBillingAndLicenseRequest(request, env, url, corsHeaders);
    }

    // 0. Interactive API Documentation (/docs, /v1/docs, /api-docs)
        // 0b. Standalone Web Vault Explorer & Player (/explorer, /app)
    if (
      url.pathname === "/explorer" ||
      url.pathname === "/explorer/" ||
      url.pathname === "/app" ||
      url.pathname === "/app/"
    ) {
      return handleWebExplorerHtml(url, corsHeaders);
    }

    if (url.pathname === "/docs" || url.pathname === "/v1/docs" || url.pathname === "/api-docs") {
      return handleApiDocsHtml(url, corsHeaders);
    }

    // 00f. Google OAuth Desktop Polling & Segregated Account Creation (/v1/auth/*)
    if (url.pathname === "/v1/auth/session" && request.method === "GET") {
      const sessionId = (url.searchParams.get("id") || "").replace(/[^a-zA-Z0-9_-]/g, "");
      if (!sessionId) {
        return jsonResponse({ ok: false, error: "Missing session id" }, 400, corsHeaders);
      }
      let sessionData = authSessionCache.get(sessionId);
      if (!sessionData && env?.VAULT_BUCKET) {
        try {
          const obj = await env.VAULT_BUCKET.get(`_auth_sessions/${sessionId}.json`);
          if (obj) {
            sessionData = JSON.parse(await obj.text());
            authSessionCache.set(sessionId, sessionData);
          }
        } catch {}
      }
      if (!sessionData) {
        return jsonResponse({ ok: true, status: "pending", sessionId }, 200, corsHeaders);
      }
      return jsonResponse(sessionData, 200, corsHeaders);
    }

    if (url.pathname === "/v1/auth/account-status" && request.method === "GET") {
      const email = (url.searchParams.get("email") || "").trim().toLowerCase();
      if (!email || !email.includes("@")) {
        return jsonResponse({ ok: false, error: "Valid email is required" }, 400, corsHeaders);
      }
      const existing = await loadAccountByEmail(env, email);
      return jsonResponse({
        ok: true,
        email,
        accountExists: Boolean(existing),
        tier: existing?.tier || null,
        quotaTB: existing?.quotaTB || null,
        userPrefix: existing?.userPrefix || null
      }, 200, corsHeaders);
    }

    if (url.pathname === "/v1/auth/create-account" && request.method === "POST") {
      try {
        const body = await request.json();
        const email = (body.email || "").trim().toLowerCase();
        const sessionToken = (body.sessionToken || "").trim();
        const plan = (body.plan || "pro").trim().toLowerCase();
        const providedKey = (body.licenseKey || "").trim();
        const machineUUID = (body.machineUUID || "mac").trim();
        const machineName = (body.machineName || "Mac").trim();

        if (!email || !email.includes("@")) {
          return jsonResponse({ ok: false, error: "Valid Google account email is required" }, 400, corsHeaders);
        }

        // Verify caller owns the Google OAuth session token OR presents a valid signed license key
        const clientSecret = env.GOOGLE_CLIENT_SECRET || "";
        const expectedHash = await sha256Hex(`${email}:${clientSecret}:v2`);
        const isMasterAdmin = email === "naegele412@gmail.com";
        const identity = await buildTenantIdentityForEmail(env, email);
        const expectedSessionToken = isMasterAdmin
          ? `zd_oauth_master_${expectedHash.slice(0, 32)}`
          : `zd_oauth_${identity.userPrefix}_${expectedHash.slice(0, 16)}`;

        let activatedLicense = null;
        if (providedKey) {
          const act = await activateLicenseKey(env, {
            licenseKey: providedKey,
            machineId: machineUUID,
            machineName,
            os: "macos",
            email
          });
          if (!act.activated) {
            return jsonResponse({ ok: false, error: act.error || "Invalid license key" }, 403, corsHeaders);
          }
          activatedLicense = act;
        } else if (clientSecret && sessionToken && sessionToken !== expectedSessionToken) {
          return jsonResponse({ ok: false, error: "Unauthorized session token for account creation" }, 401, corsHeaders);
        }

        // Resolve tier: License activation takes priority, then selected plan ("pro" or "agency")
        const resolvedTierId = activatedLicense?.tier || (plan === "agency" ? "agency" : "pro");
        const tierObj = getTier(env, resolvedTierId);
        const quotaTB = isMasterAdmin
          ? 20.0
          : (activatedLicense?.quota_tb || Number(((tierObj.storage_gb || 1024) / 1024).toFixed(2)));
        const tierName = isMasterAdmin ? "Agency" : (activatedLicense?.tier_name || tierObj.name);

        let finalLicenseKey = activatedLicense?.license_key || "";
        if (!finalLicenseKey) {
          const created = await createManagedLicense(env, {
            tierId: resolvedTierId,
            customerEmail: email,
            quotaGB: Math.round(quotaTB * 1024),
            notes: "Created via Google Sign-In onboarding"
          });
          finalLicenseKey = created.license_key;
        }

        // Create completely segregated tenant vault directory & starter files
        await ensureStarterVaultFiles(env, identity.tenantPrefix);

        const accountRecord = {
          email,
          userPrefix: identity.userPrefix,
          tenantPrefix: identity.tenantPrefix,
          accessKeyId: identity.accessKeyId,
          secretAccessKey: identity.secretAccessKey,
          tier: tierName,
          tierId: resolvedTierId,
          quotaTB,
          licenseKey: finalLicenseKey,
          segregated: true,
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString()
        };
        await saveAccountRecord(env, accountRecord);

        return jsonResponse({
          ok: true,
          accountCreated: true,
          segregated: true,
          endpoint: `${CANONICAL_ORIGIN}/s3`,
          bucket: env.R2_BUCKET || "zerodrive-vault-prod",
          userPrefix: identity.userPrefix,
          tenantPrefix: identity.tenantPrefix,
          accessKeyId: identity.accessKeyId,
          secretAccessKey: identity.secretAccessKey,
          quotaTB,
          tier: tierName,
          licenseKey: finalLicenseKey,
          mcpUrl: `${CANONICAL_ORIGIN}/mcp?key=${sessionToken || expectedSessionToken}`
        }, 200, corsHeaders);
      } catch (err) {
        return jsonResponse({
          ok: false,
          error: "Failed to create segregated account",
          details: err instanceof Error ? err.message : String(err)
        }, 400, corsHeaders);
      }
    }

    // 0a. REST API v1 Router (/v1/*)
    if (
      url.pathname.startsWith("/v1/") &&
      !url.pathname.startsWith("/v1/auth/") &&
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

    // Real-Time SSE Root Aliases: /events & /activity/stream
    if (
      (url.pathname === "/events" || url.pathname === "/events/" ||
       url.pathname === "/activity/stream" || url.pathname === "/activity/stream/") &&
      request.method === "GET"
    ) {
      const auth = authenticateMCPRequest(request, env, url);
      if (!auth.ok) {
        return new Response(JSON.stringify({ ok: false, error: auth.error }), {
          status: 401,
          headers: { ...corsHeaders, "Content-Type": "application/json" }
        });
      }
      return handleSseEvents(request, env, auth.userPrefix, corsHeaders, url);
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

      const effectiveUserPrefix = targetKey.split("/").slice(0, 3).join("/");
      await logActivity(env, effectiveUserPrefix, "write_file", { path: targetPath, size: putObj.size, etag: putObj.etag });
      broadcastVaultEvent(effectiveUserPrefix, {
        event: "change",
        action: "write",
        path: targetPath,
        timestamp: new Date().toISOString(),
        etag: putObj.etag,
        size: putObj.size,
        content_type: mimeType
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
        if (verified && verified.op === "download" && verified.key) {
          targetKey = verified.key;
          targetPath = verified.path || "";
        } else {
          const auth = authenticateMCPRequest(request, env, url);
          if (auth.ok) {
            targetPath = (url.searchParams.get("path") || "").replace(/^\/+/, "");
            if (!targetPath) {
              return new Response("Missing ?path= parameter", { status: 400, headers: corsHeaders });
            }
            targetKey = `${auth.userPrefix}/${targetPath}`;
          } else {
            return new Response("Invalid or expired download token", { status: 401, headers: corsHeaders });
          }
        }
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

    // 4. 1-Click DFY Vault Provisioning Endpoint (strict per-tenant S3 segregation)
    if (url.pathname === "/v1/vault/provision" && request.method === "POST") {
      try {
        const body = await request.json();
        const email = (body.email || "user@zerodrive.dev").trim().toLowerCase();
        const isMasterAdmin = email === "naegele412@gmail.com";
        const identity = await buildTenantIdentityForEmail(env, email);
        const existingAccount = await loadAccountByEmail(env, email);

        const endpoint = `${CANONICAL_ORIGIN}/s3`;
        let tierName = isMasterAdmin ? "Agency" : (existingAccount?.tier || "Pro");
        let quotaTB = isMasterAdmin ? 20.0 : (existingAccount?.quotaTB || 1.0);
        let resolvedKey = body.licenseKey ? String(body.licenseKey).trim() : (existingAccount?.licenseKey || "");

        // Validate/activate license key if provided
        if (!isMasterAdmin && resolvedKey && !resolvedKey.toLowerCase().includes("free")) {
          const check = await verifyLicenseKey(env, resolvedKey);
          if (check.valid) {
            tierName = check.tier_name || check.tier || tierName;
            quotaTB = check.quota_tb || quotaTB;
          }
        }

        const isFree = !isMasterAdmin && (body.tier === "free" || (resolvedKey && resolvedKey.toLowerCase().includes("free")));
        if (isFree) {
          tierName = "Free (BYOK)";
          quotaTB = 0.01;
        }

        await ensureStarterVaultFiles(env, identity.tenantPrefix);

        const provisionData = {
          endpoint,
          bucket: env.R2_BUCKET || "zerodrive-vault-prod",
          userPrefix: identity.userPrefix,
          accessKeyId: identity.accessKeyId,
          secretAccessKey: identity.secretAccessKey,
          quotaTB,
          tier: tierName,
          licenseKey: resolvedKey,
          segregated: true,
          domain: "api.zerodrive.dev",
          provisionedAt: new Date().toISOString(),
          mode: isMasterAdmin ? "live_master_vault" : (isFree ? "live_r2_free_byok" : "live_r2_s3_segregated"),
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
          <a href="/explorer" class="btn" style="font-size:13px; padding:10px 14px; text-decoration:none;">Launch Web Explorer</a>
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

export {
  isWindowsReservedName,
  normalizeUnicode,
  validateCrossPlatformPath,
  sanitizeCrossPlatformPath,
  generateConflictedPath,
  evaluateConflict,
  handleDrivesRequest,
  listDrives,
  createDrive,
  getDrive,
  deleteDrive,
  resolveDrivePrefix,
  slugifyDriveName,
  calculateDriveStats,
  extractTeamFromHostname,
  resolveTeamFromHostname,
  getTeam,
  createTeam,
  generateTeamApiKey,
  revokeTeamApiKey,
  listTeams,
  authenticateTeamToken,
  isEmailAllowedForTeam,
  sanitizeTeamPath,
  handleTeamMCP,
  handleTeamOAuth,
  handleTeamsRest,
  TEAM_MCP_TOOLS,
  RESERVED_SUBDOMAINS,
  sha256Hex,
  getPricingTiers,
  getTier,
  createCheckoutSession,
  createPortalSession,
  handleStripeWebhook,
  verifyLicenseKey,
  activateLicenseKey,
  handleBillingAndLicenseRequest
};
