/**
 * ZeroDrive Cross-Platform Auto-Update, Release Manifest & Appcast Engine
 *
 * Serves:
 *   - GET /v1/releases/latest (and alias /v1/updates/check)
 *   - GET /v1/releases/changelog
 *   - GET /v1/releases/appcast.xml (Sparkle-compatible XML feed)
 *   - GET / HEAD /download/<filename> (Full HTTP Range resume support from R2 `releases/*`)
 */

const CANONICAL_ORIGIN = "https://api.zerodrive.dev";

export const UPDATE_SIGNING_PUBLIC_KEY_PEM = `-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE/JM4b2aY9Rt903bl8CDZt3kbcV5c
I75mfIZAxtzNsSuNxNVLGvRoZ3kwUZ5UtigFOmBfoFkAtA4CgBRi+q9OMQ==
-----END PUBLIC KEY-----`;

export const DEFAULT_RELEASES = [
  {
    version: "3.1.0",
    build: "2",
    date: "2026-11-13",
    title: "Automatic Updates, Verified Releases & In-App Changelog",
    summary: "Automatic update checks on launch, sign-in, and every 4 hours on macOS and Windows with ECDSA P-256 verification and automatic What's New changelog.",
    highlights: [
      "Automatic update checks on launch, sign-in, and every 4 hours in the background on macOS and Windows",
      "Cryptographically signed updates using ECDSA P-256 + SHA-256 verification and native OS code signing",
      "Resumable downloads with HTTP Range recovery and atomic rollback if an install or verification fails",
      "Automatic post-update \"What's New\" changelog window (including cumulative notes when skipping multiple versions)",
      "View full release history anytime from Dashboard, Settings, Menu Bar, or Windows CLI (--changelog)"
    ],
    notes_markdown: [
      "- Automatic update checks on launch, sign-in, and every 4 hours in the background on macOS and Windows",
      "- Cryptographically signed updates using ECDSA P-256 + SHA-256 verification and native OS code signing",
      "- Resumable downloads with HTTP Range recovery and atomic rollback if an install or verification fails",
      "- Automatic post-update \"What's New\" changelog window (including cumulative notes when skipping multiple versions)",
      "- View full release history anytime from Dashboard, Settings, Menu Bar, or Windows CLI (`--changelog`)"
    ].join("\n"),
    mandatory: false,
    min_supported_version: "1.0.0"
  },
  {
    version: "3.0.5",
    build: "1",
    date: "2026-11-10",
    title: "Apple FileProvider Extension, Windows Cloud Filter & Multi-Drive Isolation",
    summary: "Native macOS Apple FileProvider extension, Windows Cloud Files API sync client, and multi-drive partitioning.",
    highlights: [
      "Native macOS Apple FileProvider extension (ZeroDriveFileProvider.appex) for instant 3 ms APFS placeholders",
      "Native Windows Cloud Files API (cfapi.dll) sync engine (zerodrive-sync.exe) with Explorer sidebar pinning",
      "Multi-Drive partitioning and isolated sub-vaults across macOS, Windows, and AI agent MCP tools",
      "Founders ($29/mo Pro, $297/mo Agency) checkout flow with instant signed license activation"
    ],
    notes_markdown: [
      "- Native macOS Apple FileProvider extension (`ZeroDriveFileProvider.appex`) for instant 3 ms APFS placeholders",
      "- Native Windows Cloud Files API (`cfapi.dll`) sync engine (`zerodrive-sync.exe`) with Explorer sidebar pinning",
      "- Multi-Drive partitioning and isolated sub-vaults across macOS, Windows, and AI agent MCP tools",
      "- Founders ($29/mo Pro, $297/mo Agency) checkout flow with instant signed license activation"
    ].join("\n"),
    mandatory: false,
    min_supported_version: "1.0.0"
  },
  {
    version: "3.0.0",
    build: "1",
    date: "2026-11-05",
    title: "ZeroDrive Studio 3.0 & 24/7 Hosted MCP Server",
    summary: "ZeroDrive Studio UI, 24/7 hosted AI Agent MCP server, and zero-latency NFS mount engine.",
    highlights: [
      "Complete ZeroDrive Studio UI with live telemetry, Storage Reclaim Advisor, and Duplicate Protection Shield",
      "24/7 hosted AI Agent MCP server on api.zerodrive.dev/mcp with Google OAuth 2.0 authentication",
      "Zero-latency NFS mount engine with persistent disk handle caching and high-speed direct cloud streaming"
    ],
    notes_markdown: [
      "- Complete ZeroDrive Studio UI with live telemetry, Storage Reclaim Advisor, and Duplicate Protection Shield",
      "- 24/7 hosted AI Agent MCP server on `api.zerodrive.dev/mcp` with Google OAuth 2.0 authentication",
      "- Zero-latency NFS mount engine with persistent disk handle caching and high-speed direct cloud streaming"
    ].join("\n"),
    mandatory: false,
    min_supported_version: "1.0.0"
  }
];

function jsonResp(data, status = 200, corsHeaders = {}, extraHeaders = {}) {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      ...extraHeaders
    }
  });
}

function escapeXml(str) {
  return String(str || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

/**
 * Parses a version string such as "v3.1.0", "3.1", or "3.1.0+42" into numeric parts.
 */
export function parseSemver(version) {
  const raw = String(version || "0.0.0").trim().replace(/^v/i, "");
  const [mainPart] = raw.split("+");
  const [corePart, prePart = ""] = mainPart.split("-", 2);
  const nums = corePart.split(".").map((n) => {
    const parsed = parseInt(n.replace(/[^0-9]/g, ""), 10);
    return Number.isFinite(parsed) ? parsed : 0;
  });
  return {
    major: nums[0] || 0,
    minor: nums[1] || 0,
    patch: nums[2] || 0,
    prerelease: prePart,
    normalized: `${nums[0] || 0}.${nums[1] || 0}.${nums[2] || 0}`
  };
}

/**
 * Compares two semver strings. Returns 1 if a > b, -1 if a < b, 0 if equal.
 */
export function compareSemver(a, b) {
  const pa = parseSemver(a);
  const pb = parseSemver(b);
  if (pa.major !== pb.major) return pa.major > pb.major ? 1 : -1;
  if (pa.minor !== pb.minor) return pa.minor > pb.minor ? 1 : -1;
  if (pa.patch !== pb.patch) return pa.patch > pb.patch ? 1 : -1;
  if (pa.prerelease && !pb.prerelease) return -1;
  if (!pa.prerelease && pb.prerelease) return 1;
  if (pa.prerelease !== pb.prerelease) return pa.prerelease > pb.prerelease ? 1 : -1;
  return 0;
}

/**
 * Normalizes platform query values into "macos" or "windows".
 */
export function normalizePlatform(platformRaw) {
  const p = String(platformRaw || "macos").trim().toLowerCase();
  if (p === "win" || p === "win32" || p === "win64" || p === "windows" || p === "pc") {
    return "windows";
  }
  return "macos";
}

/**
 * Parses `release-notes.md` into structured release records ordered newest-first.
 * Format:
 *   ## v3.1.0 — 2026-11-13 — Release Title
 *   - Bullet highlight
 */
export function parseReleaseNotesMarkdown(markdown) {
  const text = String(markdown || "").replace(/\r\n/g, "\n");
  const lines = text.split("\n");
  const releases = [];
  let current = null;

  const headingRegex = /^##\s+v?(\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?)(?:\s*[—\-–|:]\s*(\d{4}-\d{2}-\d{2}))?(?:\s*[—\-–|:]\s*(.+))?$/;

  for (const rawLine of lines) {
    const trimmed = rawLine.trim();
    const match = trimmed.match(headingRegex);
    if (match) {
      if (current) {
        current.notes_markdown = current._lines.join("\n").trim();
        current.summary = current.highlights[0] || current.title || `ZeroDrive v${current.version}`;
        delete current._lines;
        releases.push(current);
      }
      const version = match[1];
      const date = match[2] || new Date().toISOString().slice(0, 10);
      const title = (match[3] || `ZeroDrive v${version}`).trim();
      current = {
        version,
        build: "1",
        date,
        title,
        summary: title,
        highlights: [],
        notes_markdown: "",
        mandatory: false,
        min_supported_version: "1.0.0",
        _lines: []
      };
      continue;
    }

    if (current) {
      if (trimmed.length > 0 || current._lines.length > 0) {
        current._lines.push(rawLine);
      }
      const bulletMatch = trimmed.match(/^[-*]\s+(.+)$/);
      if (bulletMatch) {
        current.highlights.push(bulletMatch[1].trim());
      }
    }
  }

  if (current) {
    current.notes_markdown = current._lines.join("\n").trim();
    current.summary = current.highlights[0] || current.title || `ZeroDrive v${current.version}`;
    delete current._lines;
    releases.push(current);
  }

  releases.sort((a, b) => compareSemver(b.version, a.version));
  return releases;
}

/**
 * Computes all releases skipped between currentVersion (exclusive) and targetVersion (inclusive).
 * Useful when a user upgrades across multiple versions (e.g. 3.0.0 -> 3.1.0 sees 3.1.0 + 3.0.5).
 */
export function computeMissedReleases(releases, currentVersion, targetVersion) {
  const list = Array.isArray(releases) ? [...releases] : [];
  list.sort((a, b) => compareSemver(b.version, a.version));

  const missed = list.filter((rel) => {
    const gtCurrent = !currentVersion || compareSemver(rel.version, currentVersion) > 0;
    const lteTarget = !targetVersion || compareSemver(rel.version, targetVersion) <= 0;
    return gtCurrent && lteTarget;
  });

  const combinedNotesMarkdown = missed
    .map((rel) => `### v${rel.version} (${rel.date}) — ${rel.title}\n${rel.notes_markdown || ""}`.trim())
    .join("\n\n");

  return { missed, combinedNotesMarkdown };
}

/**
 * Parses an HTTP Range header (e.g. "bytes=0-1023" or "bytes=1024-").
 */
export function parseByteRange(rangeHeader, totalSize) {
  if (!rangeHeader || !String(rangeHeader).startsWith("bytes=")) return null;
  const spec = String(rangeHeader).slice(6).split(",")[0].trim();
  const [startStr, endStr] = spec.split("-", 2);
  let start = startStr === "" ? NaN : parseInt(startStr, 10);
  let end = endStr === "" ? NaN : parseInt(endStr, 10);

  if (Number.isNaN(start) && Number.isNaN(end)) return null;
  if (Number.isNaN(start)) {
    const suffixLen = end;
    if (!Number.isFinite(suffixLen) || suffixLen <= 0) return null;
    start = Math.max(0, totalSize - suffixLen);
    end = totalSize - 1;
  } else {
    if (Number.isNaN(end) || end >= totalSize) {
      end = totalSize - 1;
    }
  }
  if (start < 0 || start > end || start >= totalSize) {
    return { invalid: true, totalSize };
  }
  return {
    invalid: false,
    start,
    end,
    offset: start,
    length: end - start + 1
  };
}

/**
 * Loads the active release manifest from R2 (`releases/manifest.json`) with clean fallback.
 */
export async function loadReleaseManifest(env) {
  if (env?.VAULT_BUCKET) {
    try {
      const obj = await env.VAULT_BUCKET.get("releases/manifest.json");
      if (obj) {
        const parsed = JSON.parse(await obj.text());
        if (parsed && parsed.latest_version) {
          return parsed;
        }
      }
    } catch {
      // Fall through to embedded defaults
    }
  }

  return {
    schema: 1,
    latest_version: DEFAULT_RELEASES[0].version,
    build: DEFAULT_RELEASES[0].build,
    published_at: "2026-11-13T16:30:00Z",
    public_key: UPDATE_SIGNING_PUBLIC_KEY_PEM,
    platforms: {
      macos: {
        platform: "macos",
        arch: "arm64",
        filename: `ZeroDrive-macOS-${DEFAULT_RELEASES[0].version}.zip`,
        url: `${CANONICAL_ORIGIN}/download/ZeroDrive-macOS-${DEFAULT_RELEASES[0].version}.zip`,
        dmg_url: `${CANONICAL_ORIGIN}/download/ZeroDrive-Installer.dmg`,
        size: 0,
        sha256: "",
        signature: "",
        signature_alg: "ecdsa-p256-sha256",
        team_id: "DTB456HJMJ",
        notarized: false,
        minimum_os: "13.0"
      },
      windows: {
        platform: "windows",
        arch: "x64",
        filename: `ZeroDrive-Windows-${DEFAULT_RELEASES[0].version}.zip`,
        url: `${CANONICAL_ORIGIN}/download/ZeroDrive-Windows-${DEFAULT_RELEASES[0].version}.zip`,
        installer_url: `${CANONICAL_ORIGIN}/download/install-zerodrive.ps1`,
        size: 0,
        sha256: "",
        signature: "",
        signature_alg: "ecdsa-p256-sha256",
        authenticode_signed: false,
        minimum_os: "Windows 10 1809"
      }
    },
    releases: DEFAULT_RELEASES
  };
}

/**
 * Generates a Sparkle-compatible RSS 2.0 appcast XML feed for macOS clients.
 */
export function generateSparkleAppcastXml(manifest, baseUrl = CANONICAL_ORIGIN) {
  const releases = Array.isArray(manifest?.releases) && manifest.releases.length > 0
    ? [...manifest.releases].sort((a, b) => compareSemver(b.version, a.version))
    : DEFAULT_RELEASES;
  const macInfo = manifest?.platforms?.macos || {};
  const latestVersion = manifest?.latest_version || releases[0]?.version || "3.1.0";

  const itemsXml = releases.map((rel, idx) => {
    const isLatest = idx === 0 || rel.version === latestVersion;
    const filename = isLatest && macInfo.filename ? macInfo.filename : `ZeroDrive-macOS-${rel.version}.zip`;
    const downloadUrl = isLatest && macInfo.url ? macInfo.url : `${baseUrl}/download/${filename}`;
    const size = isLatest && macInfo.size ? macInfo.size : 0;
    const sha256 = isLatest && macInfo.sha256 ? macInfo.sha256 : "";
    const sig = isLatest && macInfo.signature ? macInfo.signature : "";
    const buildNum = rel.build || manifest?.build || "1";
    const pubDate = rel.date ? new Date(`${rel.date}T12:00:00Z`).toUTCString() : new Date().toUTCString();

    const bulletsHtml = (rel.highlights || [])
      .map((h) => `<li>${escapeXml(h)}</li>`)
      .join("");
    const descriptionHtml = `<h3>ZeroDrive v${escapeXml(rel.version)} — ${escapeXml(rel.title)}</h3><ul>${bulletsHtml}</ul>`;

    const extraAttrs = [
      sig ? `sparkle:edSignature="${escapeXml(sig)}"` : "",
      sha256 ? `sparkle:sha256="${escapeXml(sha256)}"` : ""
    ].filter(Boolean).join(" ");

    return `    <item>
      <title>ZeroDrive ${escapeXml(rel.version)} — ${escapeXml(rel.title)}</title>
      <pubDate>${escapeXml(pubDate)}</pubDate>
      <sparkle:version>${escapeXml(buildNum)}</sparkle:version>
      <sparkle:shortVersionString>${escapeXml(rel.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${escapeXml(macInfo.minimum_os || "13.0")}</sparkle:minimumSystemVersion>
      <description><![CDATA[${descriptionHtml}]]></description>
      <enclosure url="${escapeXml(downloadUrl)}" length="${Number(size) || 0}" type="application/octet-stream" ${extraAttrs} />
    </item>`;
  }).join("\n");

  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>ZeroDrive Releases</title>
    <link>${escapeXml(baseUrl)}/v1/releases/appcast.xml</link>
    <description>Signed ZeroDrive desktop releases and changelogs.</description>
    <language>en</language>
${itemsXml}
  </channel>
</rss>`;
}

function contentTypeForFilename(filename) {
  const lower = String(filename || "").toLowerCase();
  if (lower.endsWith(".dmg")) return "application/x-apple-diskimage";
  if (lower.endsWith(".zip")) return "application/zip";
  if (lower.endsWith(".exe")) return "application/vnd.microsoft.portable-executable";
  if (lower.endsWith(".msi")) return "application/x-msi";
  if (lower.endsWith(".ps1")) return "text/plain; charset=utf-8";
  if (lower.endsWith(".json")) return "application/json; charset=utf-8";
  if (lower.endsWith(".md")) return "text/markdown; charset=utf-8";
  return "application/octet-stream";
}

/**
 * Handles all /v1/releases/*, /v1/updates/*, and /download/* requests.
 * Returns a Response if matched, or null if unrelated.
 */
export async function handleReleasesRequest(request, env, url, corsHeaders = {}) {
  const pathname = url.pathname;

  // 1. Update Check / Latest Release Endpoint
  if (
    (pathname === "/v1/releases/latest" || pathname === "/v1/updates/check") &&
    request.method === "GET"
  ) {
    const manifest = await loadReleaseManifest(env);
    const platform = normalizePlatform(url.searchParams.get("platform"));
    const currentVersion = (
      url.searchParams.get("current_version") ||
      url.searchParams.get("current") ||
      url.searchParams.get("version") ||
      ""
    ).trim();
    const releases = Array.isArray(manifest.releases) && manifest.releases.length > 0
      ? [...manifest.releases].sort((a, b) => compareSemver(b.version, a.version))
      : DEFAULT_RELEASES;

    const latestRelease = releases[0] || {
      version: manifest.latest_version || "3.1.0",
      build: manifest.build || "1",
      date: new Date().toISOString().slice(0, 10),
      title: "ZeroDrive Update",
      summary: "",
      highlights: [],
      notes_markdown: ""
    };

    const latestVersion = manifest.latest_version || latestRelease.version;
    const updateAvailable = currentVersion ? compareSemver(latestVersion, currentVersion) > 0 : true;
    const { missed, combinedNotesMarkdown } = computeMissedReleases(
      releases,
      currentVersion || null,
      latestVersion
    );

    const platformArtifact = (manifest.platforms && manifest.platforms[platform]) || null;

    return jsonResp({
      ok: true,
      platform,
      current_version: currentVersion || null,
      latest_version: latestVersion,
      update_available: updateAvailable,
      mandatory: Boolean(latestRelease.mandatory || (missed.some((r) => r.mandatory))),
      latest: latestRelease,
      platform_artifact: platformArtifact,
      missed_releases: missed,
      combined_notes_markdown: combinedNotesMarkdown,
      all_releases: releases,
      public_key: manifest.public_key || UPDATE_SIGNING_PUBLIC_KEY_PEM,
      checked_at: new Date().toISOString()
    }, 200, corsHeaders);
  }

  // 2. Full Changelog Endpoint
  if (pathname === "/v1/releases/changelog" && request.method === "GET") {
    const manifest = await loadReleaseManifest(env);
    const releases = Array.isArray(manifest.releases) && manifest.releases.length > 0
      ? [...manifest.releases].sort((a, b) => compareSemver(b.version, a.version))
      : DEFAULT_RELEASES;
    const sinceVersion = (url.searchParams.get("since") || "").trim();
    const { missed, combinedNotesMarkdown } = computeMissedReleases(
      releases,
      sinceVersion || null,
      manifest.latest_version || releases[0]?.version
    );

    return jsonResp({
      ok: true,
      latest_version: manifest.latest_version || releases[0]?.version,
      releases: sinceVersion ? missed : releases,
      all_releases: releases,
      markdown: combinedNotesMarkdown
    }, 200, corsHeaders);
  }

  // 3. Sparkle Appcast XML Feed
  if ((pathname === "/v1/releases/appcast.xml" || pathname === "/appcast.xml") && request.method === "GET") {
    const manifest = await loadReleaseManifest(env);
    const xml = generateSparkleAppcastXml(manifest, url.origin || CANONICAL_ORIGIN);
    return new Response(xml, {
      status: 200,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/rss+xml; charset=utf-8",
        "Cache-Control": "public, max-age=120"
      }
    });
  }

  // 4. Resumable Release Binary Download Endpoint (/download/<filename>)
  if (pathname.startsWith("/download/") && (request.method === "GET" || request.method === "HEAD")) {
    const rawFile = pathname.slice("/download/".length);
    const decodedFile = decodeURIComponent(rawFile || "").trim();

    if (!decodedFile || decodedFile.includes("/") || decodedFile.includes("..") || !/^[A-Za-z0-9._-]+$/.test(decodedFile)) {
      return new Response("Invalid release filename.", { status: 400, headers: corsHeaders });
    }

    if (!env?.VAULT_BUCKET) {
      return new Response("Release storage bucket unavailable.", { status: 503, headers: corsHeaders });
    }

    const r2Key = `releases/${decodedFile}`;
    const rangeHeader = request.headers.get("Range");
    const contentType = contentTypeForFilename(decodedFile);

    // Inspect manifest to attach X-Content-Sha256 when available
    let manifestSha256 = "";
    try {
      const manifest = await loadReleaseManifest(env);
      for (const p of Object.values(manifest?.platforms || {})) {
        if (p && p.filename === decodedFile && p.sha256) {
          manifestSha256 = p.sha256;
          break;
        }
      }
    } catch {}

    if (request.method === "GET" && rangeHeader) {
      const headObj = await env.VAULT_BUCKET.head(r2Key);
      if (!headObj) {
        return new Response(`${decodedFile} not found.`, { status: 404, headers: corsHeaders });
      }
      const parsedRange = parseByteRange(rangeHeader, headObj.size);
      if (parsedRange?.invalid) {
        return new Response("Requested Range Not Satisfiable", {
          status: 416,
          headers: {
            ...corsHeaders,
            "Content-Range": `bytes */${headObj.size}`
          }
        });
      }
      if (parsedRange) {
        const obj = await env.VAULT_BUCKET.get(r2Key, {
          range: { offset: parsedRange.offset, length: parsedRange.length }
        });
        if (!obj) {
          return new Response(`${decodedFile} not found.`, { status: 404, headers: corsHeaders });
        }
        const headers = {
          ...corsHeaders,
          "Content-Type": contentType,
          "Content-Disposition": `attachment; filename="${decodedFile}"`,
          "Content-Length": String(parsedRange.length),
          "Content-Range": `bytes ${parsedRange.start}-${parsedRange.end}/${headObj.size}`,
          "Accept-Ranges": "bytes",
          ETag: headObj.httpEtag || `"${headObj.etag}"`,
          "Cache-Control": "public, max-age=300"
        };
        if (manifestSha256) headers["X-Content-Sha256"] = manifestSha256;
        return new Response(obj.body, { status: 206, headers });
      }
    }

    const obj = request.method === "HEAD"
      ? await env.VAULT_BUCKET.head(r2Key)
      : await env.VAULT_BUCKET.get(r2Key);

    if (!obj) {
      return new Response(`${decodedFile} is currently being uploaded.`, {
        status: 404,
        headers: corsHeaders
      });
    }

    const headers = {
      ...corsHeaders,
      "Content-Type": contentType,
      "Content-Disposition": `attachment; filename="${decodedFile}"`,
      "Content-Length": String(obj.size),
      "Accept-Ranges": "bytes",
      ETag: obj.httpEtag || `"${obj.etag}"`,
      "Cache-Control": "public, max-age=300"
    };
    if (manifestSha256) headers["X-Content-Sha256"] = manifestSha256;

    return new Response(request.method === "HEAD" ? null : obj.body, {
      status: 200,
      headers
    });
  }

  return null;
}
