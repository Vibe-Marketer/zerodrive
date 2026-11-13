/**
 * ZeroDrive Multi-Drive Provisioning & Domain Isolation Engine
 *
 * Provides multi-tenant, multi-drive provisioning across Cloudflare R2, macOS FileProvider,
 * and Windows NTFS sync daemon.
 *
 * Drives data model is persisted in the user's system R2 vault:
 *   ${userPrefix}/_SYSTEM/drives.json
 *
 * Folder isolation structure:
 *   Primary / Default: ${userPrefix}/
 *   Secondary Drives:  ${userPrefix}/drives/${driveId}/
 */

/**
 * Slugifies a human-readable drive name into a clean, safe drive ID.
 * e.g. "Work Docs 2026!" -> "work-docs-2026"
 */
export function slugifyDriveName(name) {
  if (!name || typeof name !== "string") return "drive";
  let slug = name
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9_-]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return slug || "drive";
}

/**
 * Resolves the underlying R2 bucket path prefix for a given drive.
 * For primary / default: returns ${userPrefix}
 * For secondary drives: returns ${userPrefix}/drives/${driveId}
 */
export function resolveDrivePrefix(userPrefix, driveId) {
  const cleanPrefix = (userPrefix || "").replace(/\/+$/, "");
  if (!driveId || driveId === "primary" || driveId === "default" || driveId === "root") {
    return cleanPrefix;
  }
  const cleanDriveId = String(driveId).replace(/^\/+|\/+$/g, "");
  return `${cleanPrefix}/drives/${cleanDriveId}`;
}

/**
 * Helper to read JSON from the user's _SYSTEM prefix in R2
 */
export async function getSystemJson(env, userPrefix, fileKey, defaultValue = []) {
  try {
    const obj = await env.VAULT_BUCKET.get(`${userPrefix}/_SYSTEM/${fileKey}`);
    if (!obj) return defaultValue;
    const text = await obj.text();
    return JSON.parse(text);
  } catch {
    return defaultValue;
  }
}

/**
 * Helper to write JSON to the user's _SYSTEM prefix in R2
 */
export async function setSystemJson(env, userPrefix, fileKey, data) {
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

/**
 * Helper to log activity entries into _SYSTEM/activity.json
 */
export async function logActivity(env, userPrefix, action, details = {}) {
  try {
    const activities = await getSystemJson(env, userPrefix, "activity.json", []);
    const entry = {
      id: `act_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`,
      timestamp: new Date().toISOString(),
      action,
      ...details
    };
    activities.unshift(entry);
    if (activities.length > 250) activities.length = 250;
    await setSystemJson(env, userPrefix, "activity.json", activities);
    return entry;
  } catch {
    return null;
  }
}

/**
 * Calculates current file count and storage bytes consumed by a drive.
 */
export async function calculateDriveStats(env, userPrefix, driveId) {
  const prefix = resolveDrivePrefix(userPrefix, driveId);
  const searchPrefix = `${prefix}/`;

  let fileCount = 0;
  let usedBytes = 0;
  let cursor;

  do {
    const res = await env.VAULT_BUCKET.list({ prefix: searchPrefix, limit: 1000, cursor });
    for (const obj of res.objects || []) {
      // Exclude _SYSTEM metadata and custom drives when computing primary stats
      if (driveId === "primary" || driveId === "default" || !driveId) {
        if (obj.key.startsWith(`${prefix}/_SYSTEM/`) || obj.key.startsWith(`${prefix}/drives/`)) {
          continue;
        }
      }
      fileCount++;
      usedBytes += (obj.size || 0);
    }
    cursor = res.truncated ? res.cursor : undefined;
  } while (cursor && fileCount < 10000);

  const usedGb = Number((usedBytes / (1024 * 1024 * 1024)).toFixed(3));
  const sizeFormatted = `${(usedBytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;

  return {
    file_count: fileCount,
    used_bytes: usedBytes,
    used_gb: usedGb,
    size_formatted: sizeFormatted
  };
}

/**
 * Lists all drives for a user.
 * Always includes the primary / default drive with quota and live stats.
 */
export async function listDrives(env, userPrefix, options = {}) {
  const savedDrives = await getSystemJson(env, userPrefix, "drives.json", []);
  const defaultQuotaGb = Number(env?.DEFAULT_QUOTA_TB || 1.0) * 1024;

  const defaultDrive = {
    id: "primary",
    name: "Primary Drive",
    description: "Default primary cloud storage drive",
    is_default: true,
    quota_gb: defaultQuotaGb,
    status: "active",
    created_at: new Date(0).toISOString(),
    updated_at: new Date(0).toISOString(),
    prefix: ""
  };

  const drives = [];
  const foundPrimary = savedDrives.find(d => d.id === "primary" || d.is_default);

  if (foundPrimary) {
    drives.push({ ...defaultDrive, ...foundPrimary, is_default: true });
  } else {
    drives.push(defaultDrive);
  }

  for (const d of savedDrives) {
    if (d.id === "primary" || d.is_default) continue;
    if (!options.includeArchived && d.status === "archived") continue;
    if (d.status === "deleted") continue;
    drives.push(d);
  }

  for (const drive of drives) {
    const stats = await calculateDriveStats(env, userPrefix, drive.id);
    drive.stats = stats;
    drive.file_count = stats.file_count;
    drive.used_bytes = stats.used_bytes;
    drive.used_gb = stats.used_gb;
    drive.size_formatted = stats.size_formatted;
  }

  return drives;
}

/**
 * Creates and provisions a new isolated storage drive.
 * - Generates unique driveId (slugified name)
 * - Initializes folder structure at ${userPrefix}/drives/${driveId}/ in R2
 * - Logs activity
 * - Persists drive metadata in _SYSTEM/drives.json
 */
export async function createDrive(env, userPrefix, { name, description = "", quota_gb = 1000, id } = {}) {
  if (!name || typeof name !== "string" || !name.trim()) {
    throw new Error("Drive field 'name' is required");
  }

  const baseSlug = slugifyDriveName(id || name);
  let driveId = baseSlug;
  if (driveId === "primary" || driveId === "default" || driveId === "root") {
    driveId = `${baseSlug}-${Date.now().toString(36).slice(-4)}`;
  }

  const existingDrives = await getSystemJson(env, userPrefix, "drives.json", []);
  if (existingDrives.some(d => d.id === driveId && d.status !== "deleted")) {
    driveId = `${driveId}-${Date.now().toString(36).slice(-4)}`;
  }

  const quota = quota_gb !== undefined && quota_gb !== null ? Number(quota_gb) : 1000;
  const now = new Date().toISOString();

  const drive = {
    id: driveId,
    name: name.trim(),
    description: description ? String(description).trim() : "",
    quota_gb: quota,
    is_default: false,
    status: "active",
    created_at: now,
    updated_at: now,
    prefix: `drives/${driveId}`,
    file_count: 0,
    used_bytes: 0,
    used_gb: 0,
    size_formatted: "0.00 GB",
    stats: {
      file_count: 0,
      used_bytes: 0,
      used_gb: 0,
      size_formatted: "0.00 GB"
    }
  };

  // Initialize folder structure in R2 at ${userPrefix}/drives/${driveId}/
  const folderPlaceholderKey = `${userPrefix}/drives/${driveId}/.keep`;
  await env.VAULT_BUCKET.put(folderPlaceholderKey, "", {
    httpMetadata: { contentType: "application/x-empty" }
  });

  const updatedDrives = existingDrives.filter(d => d.id !== driveId);
  updatedDrives.push(drive);
  await setSystemJson(env, userPrefix, "drives.json", updatedDrives);

  await logActivity(env, userPrefix, "create_drive", {
    drive_id: driveId,
    name: drive.name,
    quota_gb: drive.quota_gb
  });

  return drive;
}

/**
 * Returns specific drive details by ID (including primary/default).
 */
export async function getDrive(env, userPrefix, driveId) {
  if (!driveId) return null;
  const drives = await listDrives(env, userPrefix);
  const found = drives.find(d => d.id === driveId || ((driveId === "default" || driveId === "primary") && d.is_default));
  return found || null;
}

/**
 * Deletes or archives a specific drive.
 * Protects default / primary drive from deletion.
 */
export async function deleteDrive(env, userPrefix, driveId, options = {}) {
  if (!driveId || driveId === "primary" || driveId === "default") {
    return { ok: false, error: "Cannot delete the default primary drive" };
  }

  const existingDrives = await getSystemJson(env, userPrefix, "drives.json", []);
  const index = existingDrives.findIndex(d => d.id === driveId);
  if (index === -1) {
    return { ok: false, error: `Drive '${driveId}' not found` };
  }

  const targetDrive = existingDrives[index];
  const { purge = false, archive = false } = options;

  if (archive) {
    targetDrive.status = "archived";
    targetDrive.updated_at = new Date().toISOString();
    existingDrives[index] = targetDrive;
  } else if (purge) {
    // Purge R2 objects under this drive's prefix
    const prefix = `${userPrefix}/drives/${driveId}/`;
    let cursor;
    do {
      const res = await env.VAULT_BUCKET.list({ prefix, limit: 1000, cursor });
      for (const obj of res.objects || []) {
        try {
          await env.VAULT_BUCKET.delete(obj.key);
        } catch {}
      }
      cursor = res.truncated ? res.cursor : undefined;
    } while (cursor);
    existingDrives.splice(index, 1);
  } else {
    // Standard delete: remove from drives ledger
    existingDrives.splice(index, 1);
  }

  await setSystemJson(env, userPrefix, "drives.json", existingDrives);

  await logActivity(env, userPrefix, "delete_drive", {
    drive_id: driveId,
    name: targetDrive.name,
    mode: archive ? "archive" : purge ? "purge" : "delete"
  });

  return { ok: true, id: driveId, status: archive ? "archived" : "deleted" };
}

/**
 * REST Request Handler for /v1/drives routes
 */
export async function handleDrivesRequest(request, env, userPrefix, corsHeaders = {}, url) {
  const reqUrl = url || new URL(request.url);
  const pathname = reqUrl.pathname.replace(/\/+$/, "");
  const method = request.method;

  function jsonResponse(data, status = 200) {
    return new Response(JSON.stringify(data, null, 2), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" }
    });
  }

  function errorResponse(error, status = 400) {
    return jsonResponse({ ok: false, error }, status);
  }

  // GET /v1/drives - List all drives
  if (pathname === "/v1/drives" && method === "GET") {
    const drives = await listDrives(env, userPrefix);
    return jsonResponse({
      ok: true,
      count: drives.length,
      drives
    }, 200);
  }

  // POST /v1/drives or POST /v1/drives/create - Create / provision a new drive
  if ((pathname === "/v1/drives" || pathname === "/v1/drives/create") && method === "POST") {
    let body = {};
    try {
      body = await request.json();
    } catch {
      return errorResponse("Invalid JSON payload", 400);
    }

    if (!body.name || typeof body.name !== "string" || !body.name.trim()) {
      return errorResponse("Drive field 'name' is required", 400);
    }

    try {
      const drive = await createDrive(env, userPrefix, {
        name: body.name,
        description: body.description,
        quota_gb: body.quota_gb,
        id: body.id
      });
      return jsonResponse({ ok: true, drive }, 201);
    } catch (err) {
      return errorResponse(err.message || "Failed to create drive", 400);
    }
  }

  // Match /v1/drives/:id
  const match = pathname.match(/^\/v1\/drives\/([a-zA-Z0-9_-]+)$/);
  if (match) {
    const driveId = match[1];

    if (method === "GET") {
      const drive = await getDrive(env, userPrefix, driveId);
      if (!drive) {
        return errorResponse(`Drive '${driveId}' not found`, 404);
      }
      return jsonResponse({ ok: true, drive }, 200);
    }

    if (method === "DELETE") {
      if (driveId === "primary" || driveId === "default") {
        return errorResponse("Cannot delete the default primary drive", 400);
      }
      const purge = reqUrl.searchParams.get("purge") === "true";
      const archive = reqUrl.searchParams.get("archive") === "true";
      const result = await deleteDrive(env, userPrefix, driveId, { purge, archive });
      if (!result.ok) {
        return errorResponse(result.error || `Failed to delete drive '${driveId}'`, 404);
      }
      return jsonResponse({ ok: true, id: driveId, status: result.status, message: `Drive '${driveId}' deleted` }, 200);
    }
  }

  return errorResponse(`Endpoint not found: ${method} ${pathname}`, 404);
}
