/**
 * ZeroDrive Cross-Platform Filename Sanitization & Conflict Resolution Engine
 *
 * Enforces strict interoperability across macOS (HFS+/APFS), Windows (NTFS), and Linux (ext4).
 * Handles:
 * 1. Windows forbidden characters: \ / : * ? " < > | and control characters (0x00-0x1F)
 * 2. Trailing spaces and dots (illegal on Windows Win32 file APIs)
 * 3. Windows reserved DOS device names (CON, PRN, AUX, NUL, COM1-COM9, LPT1-LPT9)
 * 4. Unicode normalization (NFD to NFC canonical composition)
 * 5. Branching conflict resolution for concurrent edits across devices
 */

export const WINDOWS_RESERVED_REGEX = /^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$/i;
export const WINDOWS_FORBIDDEN_CHARS_REGEX = /[\\:*?"<>|\x00-\x1f]/;
export const WINDOWS_FORBIDDEN_CHARS_GLOBAL = /[\\:*?"<>|\x00-\x1f]/g;

/**
 * Checks if a filename or stem is a Windows reserved DOS device name.
 * e.g. 'CON', 'con.txt', 'AUX.tar.gz', 'com1.log' are all reserved.
 */
export function isWindowsReservedName(segment) {
  if (!segment || typeof segment !== "string") return false;
  const stem = segment.split(".")[0];
  return WINDOWS_RESERVED_REGEX.test(stem);
}

/**
 * Normalizes Unicode string to canonical NFC (Normalization Form C).
 * Converts macOS decomposed Unicode (NFD) to precomposed NFC.
 */
export function normalizeUnicode(str) {
  if (typeof str !== "string") return "";
  return str.normalize("NFC");
}

/**
 * Validates whether a relative path conforms strictly to cross-platform filesystem requirements.
 * Returns { valid: boolean, normalizedPath?: string, error?: string, issues?: string[] }
 */
export function validateCrossPlatformPath(rawPath) {
  if (!rawPath || typeof rawPath !== "string") {
    return { valid: false, error: "Path must be a non-empty string", issues: ["empty_path"] };
  }

  // 1. Unicode NFC normalization
  const normalized = normalizeUnicode(rawPath.trim());
  if (!normalized) {
    return { valid: false, error: "Path cannot be empty after trimming", issues: ["empty_path"] };
  }

  // Strip leading and trailing slashes for segment evaluation
  const cleanPath = normalized.replace(/^\/+|\/+$/g, "");
  if (!cleanPath) {
    return { valid: false, error: "Path cannot refer to root directory alone", issues: ["root_path"] };
  }

  const rawSegments = cleanPath.split("/");
  const issues = [];

  for (let i = 0; i < rawSegments.length; i++) {
    const segment = rawSegments[i];

    if (!segment) {
      issues.push(`Segment ${i + 1} is empty (consecutive slashes)`);
      continue;
    }

    if (segment === "..") {
      issues.push(`Segment '${segment}' attempts directory traversal (..)`);
      continue;
    }

    if (segment === ".") {
      issues.push(`Segment '${segment}' contains current-directory reference (.)`);
      continue;
    }

    // Windows forbidden characters: \ : * ? " < > | and control chars
    const matchForbidden = segment.match(WINDOWS_FORBIDDEN_CHARS_REGEX);
    if (matchForbidden) {
      issues.push(`Segment '${segment}' contains forbidden character '${matchForbidden[0]}'`);
    }

    // Trailing space or trailing dot (forbidden on Windows NTFS)
    if (/[. ]+$/.test(segment)) {
      issues.push(`Segment '${segment}' has illegal trailing space or dot`);
    }

    // Windows reserved device name check (CON, PRN, AUX, NUL, COM1-9, LPT1-9)
    if (isWindowsReservedName(segment)) {
      const stem = segment.split(".")[0];
      issues.push(`Segment '${segment}' matches Windows reserved device name '${stem.toUpperCase()}'`);
    }

    // Filename length limit (255 UTF-8 bytes max on most filesystems)
    const segmentBytes = new TextEncoder().encode(segment).length;
    if (segmentBytes > 255) {
      issues.push(`Segment '${segment}' exceeds 255 bytes limit (${segmentBytes} bytes)`);
    }
  }

  if (issues.length > 0) {
    return {
      valid: false,
      error: issues.join("; "),
      issues,
      normalizedPath: cleanPath
    };
  }

  return {
    valid: true,
    normalizedPath: cleanPath
  };
}

/**
 * Sanitizes a path to be 100% compliant across macOS, Windows, and Linux.
 * - Normalizes Unicode to NFC
 * - Replaces forbidden characters with replacement char (default: '_')
 * - Strips trailing spaces and dots from segments
 * - Renames Windows reserved device names (e.g. con.txt -> con_.txt)
 * - Removes directory traversal attempts
 *
 * If options.strict is true, throws an Error if the original path was invalid.
 */
export function sanitizeCrossPlatformPath(rawPath, options = {}) {
  const { strict = false, replacement = "_" } = options;

  if (strict) {
    const val = validateCrossPlatformPath(rawPath);
    if (!val.valid) {
      const err = new Error(`Invalid cross-platform path: ${val.error}`);
      err.code = "INVALID_CROSS_PLATFORM_PATH";
      err.issues = val.issues;
      throw err;
    }
    return val.normalizedPath;
  }

  if (!rawPath || typeof rawPath !== "string") {
    return "unnamed_file";
  }

  // 1. Normalize Unicode to NFC
  let normalized = normalizeUnicode(rawPath);

  // 2. Normalize Windows backslashes to forward slashes
  normalized = normalized.replace(/\\+/g, "/");

  // 3. Strip leading and trailing slashes and collapse duplicate slashes
  normalized = normalized.replace(/^\/+|\/+$/g, "");

  const segments = normalized.split("/").filter(Boolean);
  if (segments.length === 0) {
    return "unnamed_file";
  }

  const safeSegments = [];

  for (const rawSeg of segments) {
    // Prevent directory traversal
    if (rawSeg === ".." || rawSeg === ".") {
      continue;
    }

    // Replace Windows forbidden characters
    let seg = rawSeg.replace(WINDOWS_FORBIDDEN_CHARS_GLOBAL, replacement);

    // Strip trailing dots and spaces
    seg = seg.replace(/[. ]+$/, "");

    // If segment became empty, assign fallback
    if (!seg) {
      seg = replacement;
    }

    // Check Windows reserved device name
    if (isWindowsReservedName(seg)) {
      const parts = seg.split(".");
      parts[0] = parts[0] + "_";
      seg = parts.join(".");
    }

    // Limit byte length to 255
    const enc = new TextEncoder();
    while (enc.encode(seg).length > 255 && seg.length > 1) {
      seg = seg.slice(0, -1);
    }

    safeSegments.push(seg);
  }

  return safeSegments.length > 0 ? safeSegments.join("/") : "unnamed_file";
}

/**
 * Splits a vault relative path into directory, baseName, and extension.
 * Recognizes compound archive extensions (.tar.gz, etc.)
 */
export function splitVaultPath(filePath) {
  const normalized = normalizeUnicode(String(filePath || "")).replace(/^\/+|\/+$/g, "");
  const parts = normalized.split("/");
  const filename = parts.pop() || "";
  const dir = parts.join("/");

  let baseName = filename;
  let ext = "";

  const compoundMatch = filename.match(/^(.+?)(\.(?:tar\.(?:gz|bz2|xz|zst)))$/i);
  if (compoundMatch) {
    baseName = compoundMatch[1];
    ext = compoundMatch[2];
  } else {
    const dotIndex = filename.lastIndexOf(".");
    if (dotIndex > 0) {
      baseName = filename.slice(0, dotIndex);
      ext = filename.slice(dotIndex);
    }
  }

  return { dir, filename, baseName, ext };
}

/**
 * Generates a conflict resolution branch path in the format:
 * `path/to/name (Conflicted copy - <client_id_or_device> - <timestamp>).ext`
 *
 * Ensures the generated path contains no forbidden characters (e.g. colons in ISO timestamp
 * are replaced with hyphens for Windows compatibility).
 */
export function generateConflictedPath(targetPath, clientIdOrDevice = "device", timestamp = new Date()) {
  const { dir, baseName, ext } = splitVaultPath(targetPath);

  // Sanitize client/device name
  const safeClient = sanitizeCrossPlatformPath(String(clientIdOrDevice || "device"))
    .replace(/\//g, "-")
    .replace(/[()]/g, "")
    .trim() || "device";

  // Format timestamp without colons: YYYY-MM-DDTHH-mm-ssZ
  let tsStr;
  if (timestamp instanceof Date) {
    tsStr = timestamp.toISOString().replace(/:/g, "-").replace(/\.\d+Z$/, "Z");
  } else if (typeof timestamp === "string") {
    const parsed = new Date(timestamp);
    if (!isNaN(parsed.getTime())) {
      tsStr = parsed.toISOString().replace(/:/g, "-").replace(/\.\d+Z$/, "Z");
    } else {
      tsStr = String(timestamp).replace(/:/g, "-").replace(/[^a-zA-Z0-9_\-]/g, "_");
    }
  } else {
    tsStr = new Date().toISOString().replace(/:/g, "-").replace(/\.\d+Z$/, "Z");
  }

  const conflictedFilename = `${baseName} (Conflicted copy - ${safeClient} - ${tsStr})${ext}`;
  const fullPath = dir ? `${dir}/${conflictedFilename}` : conflictedFilename;

  return sanitizeCrossPlatformPath(fullPath);
}

/**
 * Resolves edit conflict for writes to R2:
 * Evaluates whether a write request conflicts with existing file in storage,
 * and determines whether to branch or overwrite according to X-Conflict-Policy.
 */
export function evaluateConflict({
  existingMeta,
  clientEtag,
  clientTimestamp,
  conflictPolicy = "branch",
  targetPath,
  clientId = "device",
  conflictTimestamp = new Date()
}) {
  if (!existingMeta) {
    return { isConflict: false, targetPath };
  }

  let isConflict = false;
  let reason = null;

  // Clean ETags
  const cleanClientEtag = clientEtag ? String(clientEtag).replace(/^["']+|["']+$/g, "") : null;
  const cleanServerEtag = existingMeta.etag ? String(existingMeta.etag).replace(/^["']+|["']+$/g, "") : null;

  if (cleanClientEtag && cleanServerEtag && cleanClientEtag !== "*") {
    if (cleanClientEtag !== cleanServerEtag) {
      isConflict = true;
      reason = "etag_mismatch";
    }
  } else if (clientTimestamp && existingMeta.uploaded) {
    const clientTime = new Date(clientTimestamp).getTime();
    const serverTime = new Date(existingMeta.uploaded).getTime();
    if (!isNaN(clientTime) && !isNaN(serverTime) && serverTime > clientTime) {
      isConflict = true;
      reason = "timestamp_outdated";
    }
  }

  const policy = String(conflictPolicy || "branch").toLowerCase();

  if (isConflict) {
    if (policy === "overwrite") {
      return {
        isConflict: true,
        action: "overwrite",
        reason,
        targetPath
      };
    } else {
      const conflictedPath = generateConflictedPath(targetPath, clientId, conflictTimestamp);
      return {
        isConflict: true,
        action: "branch",
        reason,
        targetPath: conflictedPath,
        originalPath: targetPath
      };
    }
  }

  return {
    isConflict: false,
    action: "write",
    targetPath
  };
}
