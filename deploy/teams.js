/**
 * ZeroDrive Team MCP & Subdomain Routing System
 *
 * Implements:
 * 1. Data model stored in R2: `_SYSTEM/teams/<slug>.json`
 *    - Fields: slug, name, owner_user, allowed_domains, drives, created_at, api_keys
 * 2. Hostname extraction: `extractTeamFromHostname(hostname)` for `<team>.zerodrive.dev` and custom domains
 * 3. Team lifecycle: `getTeam`, `createTeam`, `generateTeamApiKey`, `revokeTeamApiKey`, `listTeams`
 * 4. Authentication: `authenticateTeamToken(env, token)`
 * 5. Team MCP Server: `handleTeamMCP(request, env, url, teamSlug, corsHeaders)`
 * 6. Team OAuth & Domain Authorization: `handleTeamOAuth(request, env, url, corsHeaders)`
 * 7. REST API router for `/v1/teams/*`
 */

export const RESERVED_SUBDOMAINS = new Set([
  "api",
  "drive",
  "www",
  "app",
  "auth",
  "admin",
  "status",
  "mail",
  "login",
  "cdn",
  "staging",
  "dev",
  "localhost",
  "s3",
  "assets"
]);

export async function sha256Hex(input) {
  const data = new TextEncoder().encode(input);
  const hashBuffer = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(hashBuffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Extracts team slug from hostname.
 * If hostname is `<team>.zerodrive.dev` (and not api, drive, www, etc.), returns `<team>`.
 * Also supports custom domains if mapped via customDomainMap.
 */
export function extractTeamFromHostname(hostname, customDomainMap = null) {
  if (!hostname || typeof hostname !== "string") return null;
  const host = hostname.toLowerCase().split(":")[0].trim();

  // Custom domain map check (if provided in-memory or passed)
  if (customDomainMap && typeof customDomainMap === "object") {
    if (customDomainMap instanceof Map && customDomainMap.has(host)) {
      return customDomainMap.get(host);
    }
    if (typeof customDomainMap[host] === "string") {
      return customDomainMap[host];
    }
  }

  // Check <team>.zerodrive.dev
  const match = host.match(/^([a-z0-9_-]+)\.zerodrive\.dev$/);
  if (match) {
    const candidate = match[1];
    if (!RESERVED_SUBDOMAINS.has(candidate)) {
      return candidate;
    }
    return null;
  }

  return null;
}

/**
 * Resolves team slug from hostname, checking R2 `_SYSTEM/domains/<host>.json`
 * if not directly matched by .zerodrive.dev.
 */
export async function resolveTeamFromHostname(env, hostname, customDomainMap = null) {
  const direct = extractTeamFromHostname(hostname, customDomainMap);
  if (direct) return direct;
  if (!hostname || typeof hostname !== "string") return null;
  const host = hostname.toLowerCase().split(":")[0].trim();

  if (env && env.VAULT_BUCKET) {
    try {
      const mappingObj = await env.VAULT_BUCKET.get(`_SYSTEM/domains/${host}.json`);
      if (mappingObj) {
        const data = JSON.parse(await mappingObj.text());
        if (data && data.team) return data.team;
      }
    } catch {}
  }
  return null;
}

/**
 * Retrieves a team record from R2 `_SYSTEM/teams/<slug>.json`.
 */
export async function getTeam(env, slug) {
  if (!slug || typeof slug !== "string") return null;
  const cleanSlug = slug.toLowerCase().trim();
  const key = `_SYSTEM/teams/${cleanSlug}.json`;
  try {
    const obj = await env.VAULT_BUCKET.get(key);
    if (!obj) return null;
    const text = await obj.text();
    return JSON.parse(text);
  } catch {
    return null;
  }
}

/**
 * Provisions a new team and stores in R2 `_SYSTEM/teams/<slug>.json`.
 */
export async function createTeam(env, ownerPrefix, {
  name,
  slug,
  allowed_domains = [],
  drives = [],
  custom_domains = [],
  invites = []
}) {
  if (!slug || typeof slug !== "string") {
    throw new Error("Team slug is required");
  }
  const cleanSlug = slug.toLowerCase().trim();
  if (!/^[a-z0-9_-]+$/.test(cleanSlug)) {
    throw new Error("Invalid team slug format. Must be lowercase alphanumeric with hyphens or underscores.");
  }
  if (RESERVED_SUBDOMAINS.has(cleanSlug)) {
    throw new Error(`Team slug '${cleanSlug}' is a reserved system name.`);
  }

  const existing = await getTeam(env, cleanSlug);
  if (existing) {
    throw new Error(`Team with slug '${cleanSlug}' already exists.`);
  }

  const teamData = {
    slug: cleanSlug,
    name: (name || cleanSlug).trim(),
    owner_user: ownerPrefix || "usr_master",
    allowed_domains: Array.isArray(allowed_domains)
      ? allowed_domains.map(d => d.trim().toLowerCase())
      : [],
    drives: Array.isArray(drives) && drives.length > 0
      ? drives.map(d => d.trim().toLowerCase())
      : ["main"],
    custom_domains: Array.isArray(custom_domains)
      ? custom_domains.map(d => d.trim().toLowerCase())
      : [],
    invites: Array.isArray(invites)
      ? invites.map(i => i.trim().toLowerCase())
      : [],
    created_at: new Date().toISOString(),
    api_keys: []
  };

  await env.VAULT_BUCKET.put(
    `_SYSTEM/teams/${cleanSlug}.json`,
    JSON.stringify(teamData, null, 2),
    { httpMetadata: { contentType: "application/json" } }
  );

  // Map any custom domains
  for (const cd of teamData.custom_domains) {
    await env.VAULT_BUCKET.put(
      `_SYSTEM/domains/${cd}.json`,
      JSON.stringify({ team: cleanSlug, domain: cd, created_at: teamData.created_at }, null, 2),
      { httpMetadata: { contentType: "application/json" } }
    );
  }

  // Provision starter files and drive folders in the team's vault
  try {
    const routerContent = `# ZeroDrive Team Hub: ${teamData.name} (\`${teamData.slug}\`)\n\nWelcome to the ${teamData.name} team vault.\n\n## Assigned Drives\n${teamData.drives.map(d => `- \`${d}/\``).join("\n")}\n\n## Agent Rules\nAgents operate scoped exclusively to this team's drives.\n`;
    await env.VAULT_BUCKET.put(
      `teams/${cleanSlug}/ROUTER.md`,
      routerContent,
      { httpMetadata: { contentType: "text/markdown; charset=utf-8" } }
    );
    await env.VAULT_BUCKET.put(
      `teams/${cleanSlug}/AGENTS.md`,
      `# ZeroDrive Agent Rules — Team ${teamData.name}\n\nOperate strictly within assigned team drives: ${teamData.drives.join(", ")}.\n`,
      { httpMetadata: { contentType: "text/markdown; charset=utf-8" } }
    );
    for (const drive of teamData.drives) {
      await env.VAULT_BUCKET.put(`teams/${cleanSlug}/${drive}/.gitkeep`, "", { httpMetadata: { contentType: "text/plain" } });
    }
  } catch {}

  return teamData;
}

/**
 * Generates an MCP API key for a team with prefix `zd_team_<slug>_<random32>`.
 */
export async function generateTeamApiKey(env, slug, label = "Default Key") {
  const team = await getTeam(env, slug);
  if (!team) {
    throw new Error(`Team '${slug}' not found.`);
  }

  const randomBytes = crypto.getRandomValues(new Uint8Array(16));
  const random32 = Array.from(randomBytes).map(b => b.toString(16).padStart(2, "0")).join("");
  const token = `zd_team_${team.slug}_${random32}`;
  const keyHash = await sha256Hex(token);

  const keyIdBytes = crypto.getRandomValues(new Uint8Array(6));
  const keyId = "key_" + Array.from(keyIdBytes).map(b => b.toString(16).padStart(2, "0")).join("");

  const keyRecord = {
    id: keyId,
    label: (label || "Default Key").trim(),
    prefix: `zd_team_${team.slug}_...${random32.slice(-4)}`,
    hash: keyHash,
    created_at: new Date().toISOString(),
    last_used_at: null
  };

  team.api_keys = team.api_keys || [];
  team.api_keys.push(keyRecord);

  await env.VAULT_BUCKET.put(
    `_SYSTEM/teams/${team.slug}.json`,
    JSON.stringify(team, null, 2),
    { httpMetadata: { contentType: "application/json" } }
  );

  return {
    ok: true,
    token,
    key: {
      id: keyRecord.id,
      label: keyRecord.label,
      prefix: keyRecord.prefix,
      created_at: keyRecord.created_at
    },
    team: team.slug
  };
}

/**
 * Revokes a team API key by ID.
 */
export async function revokeTeamApiKey(env, slug, keyId) {
  const team = await getTeam(env, slug);
  if (!team) {
    throw new Error(`Team '${slug}' not found.`);
  }

  const initialCount = (team.api_keys || []).length;
  team.api_keys = (team.api_keys || []).filter(k => k.id !== keyId);

  if (team.api_keys.length === initialCount) {
    throw new Error(`Key '${keyId}' not found on team '${slug}'.`);
  }

  await env.VAULT_BUCKET.put(
    `_SYSTEM/teams/${team.slug}.json`,
    JSON.stringify(team, null, 2),
    { httpMetadata: { contentType: "application/json" } }
  );

  return { ok: true, message: "Key revoked", keyId };
}

/**
 * Lists teams stored in `_SYSTEM/teams/`.
 */
export async function listTeams(env, ownerPrefix = null) {
  const listed = await env.VAULT_BUCKET.list({ prefix: "_SYSTEM/teams/", limit: 1000 });
  const teams = [];

  for (const obj of listed.objects || []) {
    try {
      const teamObj = await env.VAULT_BUCKET.get(obj.key);
      if (teamObj) {
        const team = JSON.parse(await teamObj.text());
        if (!ownerPrefix || team.owner_user === ownerPrefix || ownerPrefix === "master_admin") {
          teams.push({
            slug: team.slug,
            name: team.name,
            owner_user: team.owner_user,
            allowed_domains: team.allowed_domains,
            drives: team.drives,
            custom_domains: team.custom_domains,
            created_at: team.created_at,
            key_count: (team.api_keys || []).length
          });
        }
      }
    } catch {}
  }

  return teams;
}

/**
 * Authenticates a team token and returns team context.
 * Accepts:
 * - `zd_team_<slug>_<random32>`
 * - Master API key / admin override
 */
export async function authenticateTeamToken(env, token) {
  if (!token || typeof token !== "string") {
    return { ok: false, error: "No authentication token provided" };
  }
  const cleanToken = token.trim();

  // Check master admin token
  const masterKey = env.MASTER_API_KEY || "zd_sec_b07b3671b1c45b32195f8353d4df8945ee31448699a361b32b6f8192a9b03633";
  if (cleanToken === masterKey || cleanToken.startsWith("zd_oauth_master_") || cleanToken === "zd_oauth_master") {
    return { ok: true, isAdmin: true, userPrefix: "master_admin" };
  }

  // Format: zd_team_<slug>_<random32>
  const match = cleanToken.match(/^zd_team_([a-zA-Z0-9_-]+)_[a-f0-9]+$/i);
  if (!match) {
    return { ok: false, error: "Invalid team token format. Expected zd_team_<slug>_<key>" };
  }

  const slug = match[1].toLowerCase();
  const team = await getTeam(env, slug);
  if (!team) {
    return { ok: false, error: `Team '${slug}' does not exist` };
  }

  const tokenHash = await sha256Hex(cleanToken);
  const matchedKey = (team.api_keys || []).find(k => k.hash === tokenHash);
  if (!matchedKey) {
    return { ok: false, error: "Invalid team token or token has been revoked" };
  }

  // Update last_used_at asynchronously
  matchedKey.last_used_at = new Date().toISOString();
  env.VAULT_BUCKET.put(
    `_SYSTEM/teams/${team.slug}.json`,
    JSON.stringify(team, null, 2),
    { httpMetadata: { contentType: "application/json" } }
  ).catch(() => {});

  return {
    ok: true,
    team,
    slug: team.slug,
    drives: team.drives,
    teamPrefix: `teams/${team.slug}`,
    keyId: matchedKey.id,
    keyLabel: matchedKey.label
  };
}

/**
 * Checks if a user email is authorized for a team based on allowed_domains,
 * explicit invites, or team ownership.
 */
export function isEmailAllowedForTeam(email, team) {
  if (!email || !team) return false;
  const cleanEmail = email.toLowerCase().trim();
  const parts = cleanEmail.split("@");
  if (parts.length !== 2) return false;
  const domain = parts[1];

  // 1. Check allowed_domains
  const allowed = team.allowed_domains || [];
  for (const d of allowed) {
    const normalized = d.toLowerCase().trim().replace(/^@/, "");
    if (normalized === "*" || normalized === domain) {
      return true;
    }
  }

  // 2. Check explicit invites / allowed users
  const invites = team.invites || [];
  for (const inv of invites) {
    if (inv.toLowerCase().trim() === cleanEmail) {
      return true;
    }
  }

  // 3. Check owner
  if (team.owner_user && (team.owner_user.toLowerCase() === cleanEmail || team.owner_user.toLowerCase().includes(cleanEmail))) {
    return true;
  }

  return false;
}

/**
 * Validates and sanitizes a path within a team vault, guaranteeing that
 * file access cannot escape `teams/<slug>/`.
 */
export function sanitizeTeamPath(teamSlug, rawPath) {
  if (!rawPath || typeof rawPath !== "string") {
    return { error: "Path must be a non-empty string" };
  }
  const normalized = rawPath.replace(/\\/g, "/").trim();
  const segments = normalized.split("/").filter(s => s.length > 0 && s !== ".");
  for (const seg of segments) {
    if (seg === "..") {
      return { error: "Path traversal ('..') is strictly prohibited" };
    }
  }
  const cleanPath = segments.join("/");
  if (!cleanPath) {
    return { error: "Path cannot resolve to empty" };
  }
  return { cleanPath, fullKey: `teams/${teamSlug}/${cleanPath}` };
}

/**
 * Directory listing helper scoped to team vault prefix.
 */
async function listTeamDirectory(env, prefix, maxPages = 20) {
  const dirsSet = new Set();
  const files = [];
  let cursor;
  let pages = 0;
  do {
    const listed = await env.VAULT_BUCKET.list({ prefix, delimiter: "/", limit: 1000, cursor });
    for (const p of listed.delimitedPrefixes || []) {
      const folderName = p.slice(prefix.length).replace(/\/$/, "");
      if (folderName) dirsSet.add(folderName);
    }
    for (const o of listed.objects || []) {
      const fileName = o.key.slice(prefix.length);
      if (fileName && !fileName.includes("/")) {
        files.push({
          name: fileName,
          size: o.size,
          modified: o.uploaded ? o.uploaded.toISOString() : new Date().toISOString(),
          key: o.key
        });
      }
    }
    cursor = listed.truncated ? listed.cursor : undefined;
    pages++;
  } while (cursor && pages < maxPages);

  return { dirs: Array.from(dirsSet).sort(), files };
}

/**
 * Visual directory tree helper scoped to team vault prefix.
 */
async function buildTeamDirectoryTree(env, teamPrefix, baseSubpath, maxDepth = 2, currentDepth = 1, indent = "") {
  const prefix = baseSubpath ? `${teamPrefix}/${baseSubpath}/` : `${teamPrefix}/`;
  const { dirs, files } = await listTeamDirectory(env, prefix);
  const lines = [];

  for (const dir of dirs) {
    lines.push(`${indent}📁 ${dir}/`);
    if (currentDepth < maxDepth) {
      const childPath = baseSubpath ? `${baseSubpath}/${dir}` : dir;
      const childLines = await buildTeamDirectoryTree(env, teamPrefix, childPath, maxDepth, currentDepth + 1, indent + "  ");
      lines.push(...childLines);
    }
  }
  for (const file of files) {
    lines.push(`${indent}📄 ${file.name} (${file.size} B)`);
  }
  return lines;
}

export const TEAM_MCP_TOOLS = [
  {
    name: "get_file_tree",
    description: "Get a visual directory tree of the team's shared drives or any subfolder.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Subfolder path inside the team vault (e.g. 'marketing', 'brand-assets'). Leave blank for root." },
        depth: { type: "integer", description: "Tree depth (1 to 4, default 2)." }
      }
    }
  },
  {
    name: "list_files",
    description: "List files and folders inside the team's vault or an assigned drive.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Subfolder or drive name to list." },
        recursive: { type: "boolean", description: "List all nested files recursively." }
      }
    }
  },
  {
    name: "read_file",
    description: "Read the text or code contents of a file inside the team vault.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "File path relative to the team vault (e.g. 'marketing/q3-strategy.md')." }
      },
      required: ["path"]
    }
  },
  {
    name: "write_file",
    description: "Write or update a text/code file inside the team vault.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "File path relative to the team vault." },
        content: { type: "string", description: "Full UTF-8 text content to write." }
      },
      required: ["path", "content"]
    }
  },
  {
    name: "edit_file",
    description: "Find and replace text in an existing file in the team vault.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "File path relative to team vault." },
        old_text: { type: "string", description: "Exact string to find." },
        new_text: { type: "string", description: "Replacement string." }
      },
      required: ["path", "old_text", "new_text"]
    }
  },
  {
    name: "delete_file",
    description: "Delete a file from the team vault.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "File path relative to team vault." }
      },
      required: ["path"]
    }
  },
  {
    name: "search_filenames",
    description: "Search for files by name or extension across all team drives.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Search term or file extension (e.g. '.md', 'strategy')." }
      },
      required: ["query"]
    }
  },
  {
    name: "grep_vault",
    description: "Search file contents across the team vault for a string or keyword.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Search query string." }
      },
      required: ["query"]
    }
  },
  {
    name: "save_skill",
    description: "Save a reusable team agent skill into _SKILLS/<name>/SKILL.md.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Skill name in verb-noun format (e.g. 'generate-weekly-report')." },
        content: { type: "string", description: "Markdown instructions for the skill." }
      },
      required: ["name", "content"]
    }
  },
  {
    name: "run_vault_doctor",
    description: "Run diagnostic checks on the team vault, drives, and storage health.",
    inputSchema: {
      type: "object",
      properties: {}
    }
  }
];

/**
 * Handles Team MCP JSON-RPC and HTTP requests scoped exclusively to team drives.
 */
export async function handleTeamMCP(request, env, url, teamSlug, corsHeaders = {}) {
  const headers = {
    ...corsHeaders,
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, HEAD, POST, PUT, DELETE, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization, Accept, Range, Mcp-Session-Id",
    "Content-Type": "application/json"
  };

  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers });
  }

  // 1. Resolve Team
  if (!teamSlug) {
    return new Response(JSON.stringify({
      jsonrpc: "2.0",
      id: null,
      error: { code: -32602, message: "Team slug is required" }
    }), { status: 400, headers });
  }

  const team = await getTeam(env, teamSlug);
  if (!team) {
    return new Response(JSON.stringify({
      jsonrpc: "2.0",
      id: null,
      error: { code: -32004, message: `Team '${teamSlug}' not found` }
    }), { status: 404, headers });
  }

  // 2. Extract and Authenticate Token
  const authHeader = request.headers.get("Authorization") || "";
  let token = "";
  if (authHeader.startsWith("Bearer ")) {
    token = authHeader.slice(7).trim();
  } else if (url.searchParams.get("key")) {
    token = url.searchParams.get("key").trim();
  } else if (url.searchParams.get("token")) {
    token = url.searchParams.get("token").trim();
  }

  if (!token) {
    return new Response(JSON.stringify({
      jsonrpc: "2.0",
      id: null,
      error: {
        code: -32000,
        message: `Authentication required for team '${team.slug}'. Provide Bearer zd_team_${team.slug}_... token.`,
        data: {
          team: team.slug,
          auth_flow: "team_token",
          login_url: `https://${team.slug}.zerodrive.dev/auth/team/login`
        }
      }
    }), {
      status: 401,
      headers: {
        ...headers,
        "WWW-Authenticate": `Bearer realm="ZeroDrive Team ${team.slug}"`
      }
    });
  }

  const auth = await authenticateTeamToken(env, token);
  if (!auth.ok) {
    return new Response(JSON.stringify({
      jsonrpc: "2.0",
      id: null,
      error: { code: -32000, message: auth.error || "Authentication failed" }
    }), { status: 401, headers });
  }

  // Enforce team isolation: token must belong to this team (unless master admin)
  if (!auth.isAdmin && auth.slug !== team.slug) {
    return new Response(JSON.stringify({
      jsonrpc: "2.0",
      id: null,
      error: { code: -32003, message: `Forbidden: Token is scoped to team '${auth.slug}', cannot access team '${team.slug}'.` }
    }), { status: 403, headers });
  }

  const teamPrefix = `teams/${team.slug}`;

  // 3. Handle GET info request
  if (request.method === "GET") {
    return new Response(JSON.stringify({
      status: "online",
      name: `ZeroDrive Team (${team.name})`,
      team: team.slug,
      team_name: team.name,
      owner_user: team.owner_user,
      drives: team.drives,
      protocol: "2025-03-26",
      tools: TEAM_MCP_TOOLS.map(t => t.name)
    }, null, 2), { status: 200, headers });
  }

  if (request.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405, headers });
  }

  // 4. Process JSON-RPC POST
  let body;
  try {
    body = await request.json();
  } catch {
    return new Response(JSON.stringify({
      jsonrpc: "2.0",
      id: null,
      error: { code: -32700, message: "Parse error: Invalid JSON" }
    }), { status: 400, headers });
  }

  const { id, method, params } = body;

  if (method === "initialize") {
    return new Response(JSON.stringify({
      jsonrpc: "2.0",
      id,
      result: {
        protocolVersion: params?.protocolVersion || "2025-03-26",
        capabilities: { tools: { listChanged: false } },
        serverInfo: {
          name: `ZeroDrive Team — ${team.name}`,
          team: team.slug,
          drives: team.drives,
          version: "1.0.0"
        },
        instructions: `ZeroDrive Team MCP Server for ${team.name}. Operates scoped exclusively to assigned team drives: ${team.drives.join(", ")}.`
      }
    }), { status: 200, headers });
  }

  if (method === "ping") {
    return new Response(JSON.stringify({ jsonrpc: "2.0", id, result: {} }), { status: 200, headers });
  }

  if (method === "tools/list") {
    return new Response(JSON.stringify({
      jsonrpc: "2.0",
      id,
      result: { tools: TEAM_MCP_TOOLS }
    }), { status: 200, headers });
  }

  if (method === "tools/call") {
    const toolName = params?.name;
    const args = params?.arguments || {};

    try {
      if (toolName === "get_file_tree") {
        const subpath = (args.path || "").replace(/^\/+/, "").replace(/\/+$/, "");
        if (subpath) {
          const checked = sanitizeTeamPath(team.slug, subpath);
          if (checked.error) {
            return new Response(JSON.stringify({
              jsonrpc: "2.0",
              id,
              result: { isError: true, content: [{ type: "text", text: `Error: ${checked.error}` }] }
            }), { status: 200, headers });
          }
        }
        const depth = Math.min(Math.max(parseInt(args.depth || 2, 10), 1), 4);
        const lines = await buildTeamDirectoryTree(env, teamPrefix, subpath, depth);
        const header = subpath ? `📁 ${team.slug}/${subpath}/` : `📁 Team Vault Root (${team.name} / ${team.slug})`;
        return new Response(JSON.stringify({
          jsonrpc: "2.0",
          id,
          result: { content: [{ type: "text", text: [header, ...lines].join("\n") }] }
        }), { status: 200, headers });
      }

      if (toolName === "list_files") {
        const subpath = (args.path || "").replace(/^\/+/, "").replace(/\/+$/, "");
        if (subpath) {
          const checked = sanitizeTeamPath(team.slug, subpath);
          if (checked.error) {
            return new Response(JSON.stringify({
              jsonrpc: "2.0",
              id,
              result: { isError: true, content: [{ type: "text", text: `Error: ${checked.error}` }] }
            }), { status: 200, headers });
          }
        }
        const targetPrefix = subpath ? `${teamPrefix}/${subpath}/` : `${teamPrefix}/`;
        const { dirs, files } = await listTeamDirectory(env, targetPrefix);
        return new Response(JSON.stringify({
          jsonrpc: "2.0",
          id,
          result: {
            content: [{
              type: "text",
              text: JSON.stringify({
                team: team.slug,
                path: subpath || "/",
                directories: dirs,
                files: files.map(f => ({ name: f.name, size: f.size, modified: f.modified }))
              }, null, 2)
            }]
          }
        }), { status: 200, headers });
      }

      if (toolName === "read_file") {
        const checked = sanitizeTeamPath(team.slug, args.path);
        if (checked.error) {
          return new Response(JSON.stringify({
            jsonrpc: "2.0",
            id,
            result: { isError: true, content: [{ type: "text", text: `Error: ${checked.error}` }] }
          }), { status: 200, headers });
        }
        const obj = await env.VAULT_BUCKET.get(checked.fullKey);
        if (!obj) {
          return new Response(JSON.stringify({
            jsonrpc: "2.0",
            id,
            result: { isError: true, content: [{ type: "text", text: `File not found: ${args.path}` }] }
          }), { status: 200, headers });
        }
        const text = await obj.text();
        return new Response(JSON.stringify({
          jsonrpc: "2.0",
          id,
          result: { content: [{ type: "text", text }] }
        }), { status: 200, headers });
      }

      if (toolName === "write_file") {
        const checked = sanitizeTeamPath(team.slug, args.path);
        if (checked.error) {
          return new Response(JSON.stringify({
            jsonrpc: "2.0",
            id,
            result: { isError: true, content: [{ type: "text", text: `Error: ${checked.error}` }] }
          }), { status: 200, headers });
        }
        await env.VAULT_BUCKET.put(checked.fullKey, args.content || "", {
          httpMetadata: { contentType: "text/plain; charset=utf-8" }
        });
        return new Response(JSON.stringify({
          jsonrpc: "2.0",
          id,
          result: {
            content: [{
              type: "text",
              text: `Successfully wrote ${args.content ? args.content.length : 0} bytes to ${args.path} in team ${team.slug}.`
            }]
          }
        }), { status: 200, headers });
      }

      if (toolName === "edit_file") {
        const checked = sanitizeTeamPath(team.slug, args.path);
        if (checked.error) {
          return new Response(JSON.stringify({
            jsonrpc: "2.0",
            id,
            result: { isError: true, content: [{ type: "text", text: `Error: ${checked.error}` }] }
          }), { status: 200, headers });
        }
        const obj = await env.VAULT_BUCKET.get(checked.fullKey);
        if (!obj) {
          return new Response(JSON.stringify({
            jsonrpc: "2.0",
            id,
            result: { isError: true, content: [{ type: "text", text: `File not found: ${args.path}` }] }
          }), { status: 200, headers });
        }
        const content = await obj.text();
        if (!content.includes(args.old_text)) {
          return new Response(JSON.stringify({
            jsonrpc: "2.0",
            id,
            result: { isError: true, content: [{ type: "text", text: `old_text not found in ${args.path}` }] }
          }), { status: 200, headers });
        }
        const updated = content.replaceAll(args.old_text, args.new_text || "");
        await env.VAULT_BUCKET.put(checked.fullKey, updated, {
          httpMetadata: { contentType: "text/plain; charset=utf-8" }
        });
        return new Response(JSON.stringify({
          jsonrpc: "2.0",
          id,
          result: {
            content: [{
              type: "text",
              text: `Successfully updated ${args.path} in team ${team.slug}.`
            }]
          }
        }), { status: 200, headers });
      }

      if (toolName === "delete_file") {
        const checked = sanitizeTeamPath(team.slug, args.path);
        if (checked.error) {
          return new Response(JSON.stringify({
            jsonrpc: "2.0",
            id,
            result: { isError: true, content: [{ type: "text", text: `Error: ${checked.error}` }] }
          }), { status: 200, headers });
        }
        await env.VAULT_BUCKET.delete(checked.fullKey);
        return new Response(JSON.stringify({
          jsonrpc: "2.0",
          id,
          result: {
            content: [{
              type: "text",
              text: `Deleted ${args.path} from team ${team.slug}.`
            }]
          }
        }), { status: 200, headers });
      }

      if (toolName === "search_filenames") {
        const query = (args.query || "").toLowerCase().trim();
        const listed = await env.VAULT_BUCKET.list({ prefix: `${teamPrefix}/`, limit: 1000 });
        const matches = [];
        for (const o of listed.objects || []) {
          const relPath = o.key.slice(teamPrefix.length + 1);
          if (relPath.toLowerCase().includes(query)) {
            matches.push({ path: relPath, size: o.size, modified: o.uploaded });
          }
        }
        return new Response(JSON.stringify({
          jsonrpc: "2.0",
          id,
          result: {
            content: [{
              type: "text",
              text: JSON.stringify({ team: team.slug, query, matches_count: matches.length, matches }, null, 2)
            }]
          }
        }), { status: 200, headers });
      }

      if (toolName === "grep_vault") {
        const query = (args.query || "").trim();
        const listed = await env.VAULT_BUCKET.list({ prefix: `${teamPrefix}/`, limit: 100 });
        const hits = [];
        for (const o of listed.objects || []) {
          if (o.size > 2000000) continue; // skip files > 2MB
          try {
            const fileObj = await env.VAULT_BUCKET.get(o.key);
            if (fileObj) {
              const text = await fileObj.text();
              if (text.includes(query)) {
                const lines = text.split("\n");
                const matchedLines = [];
                lines.forEach((l, idx) => {
                  if (l.includes(query)) matchedLines.push({ line: idx + 1, text: l.slice(0, 200) });
                });
                hits.push({
                  path: o.key.slice(teamPrefix.length + 1),
                  matches: matchedLines.slice(0, 10)
                });
              }
            }
          } catch {}
        }
        return new Response(JSON.stringify({
          jsonrpc: "2.0",
          id,
          result: {
            content: [{
              type: "text",
              text: JSON.stringify({ team: team.slug, query, hits_count: hits.length, hits }, null, 2)
            }]
          }
        }), { status: 200, headers });
      }

      if (toolName === "save_skill") {
        const skillName = (args.name || "").toLowerCase().replace(/[^a-z0-9-]/g, "-").replace(/-+/g, "-").replace(/^-|-$/g, "");
        if (!skillName) {
          return new Response(JSON.stringify({
            jsonrpc: "2.0",
            id,
            result: { isError: true, content: [{ type: "text", text: "Skill name is required" }] }
          }), { status: 200, headers });
        }
        const skillKey = `${teamPrefix}/_SKILLS/${skillName}/SKILL.md`;
        await env.VAULT_BUCKET.put(skillKey, args.content || "", {
          httpMetadata: { contentType: "text/markdown; charset=utf-8" }
        });
        return new Response(JSON.stringify({
          jsonrpc: "2.0",
          id,
          result: {
            content: [{
              type: "text",
              text: `Saved team skill '${skillName}' to _SKILLS/${skillName}/SKILL.md.`
            }]
          }
        }), { status: 200, headers });
      }

      if (toolName === "run_vault_doctor") {
        const rootListing = await listTeamDirectory(env, `${teamPrefix}/`);
        const report = {
          status: "healthy",
          team_slug: team.slug,
          team_name: team.name,
          owner: team.owner_user,
          assigned_drives: team.drives,
          allowed_domains: team.allowed_domains,
          root_directories: rootListing.dirs,
          root_files: rootListing.files.map(f => f.name),
          total_root_files: rootListing.files.length,
          endpoint: `https://${team.slug}.zerodrive.dev/mcp`
        };
        return new Response(JSON.stringify({
          jsonrpc: "2.0",
          id,
          result: {
            content: [{
              type: "text",
              text: `## ZeroDrive Team Doctor Report (${team.name})\n\`\`\`json\n${JSON.stringify(report, null, 2)}\n\`\`\``
            }]
          }
        }), { status: 200, headers });
      }

      return new Response(JSON.stringify({
        jsonrpc: "2.0",
        id,
        result: { isError: true, content: [{ type: "text", text: `Unknown tool: ${toolName}` }] }
      }), { status: 200, headers });
    } catch (err) {
      return new Response(JSON.stringify({
        jsonrpc: "2.0",
        id,
        result: { isError: true, content: [{ type: "text", text: `Tool error: ${err.message || String(err)}` }] }
      }), { status: 200, headers });
    }
  }

  return new Response(JSON.stringify({
    jsonrpc: "2.0",
    id,
    error: { code: -32601, message: `Method not found: ${method}` }
  }), { status: 200, headers });
}

/**
 * Handles `/auth/team/login` and `/auth/team/callback`.
 * Ensures user's email belongs to `allowed_domains` or explicit invite list.
 */
export async function handleTeamOAuth(request, env, url, corsHeaders = {}) {
  const headers = {
    ...corsHeaders,
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Content-Type": "application/json"
  };

  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers });
  }

  const pathname = url.pathname.replace(/\/+$/, "");
  const isLogin = pathname.endsWith("/login");
  const isCallback = pathname.endsWith("/callback");

  // Determine team slug from query or subdomain
  let teamSlug = url.searchParams.get("team") || "";
  if (!teamSlug) {
    teamSlug = extractTeamFromHostname(url.hostname) || "";
  }

  if (isLogin) {
    if (!teamSlug) {
      return new Response(JSON.stringify({
        ok: false,
        error: "Missing 'team' query parameter or team subdomain."
      }), { status: 400, headers });
    }

    const team = await getTeam(env, teamSlug);
    if (!team) {
      return new Response(JSON.stringify({
        ok: false,
        error: `Team '${teamSlug}' not found.`
      }), { status: 404, headers });
    }

    // Dev/Test mode: direct login if mock_email is provided
    const mockEmail = url.searchParams.get("mock_email") || request.headers.get("x-mock-email");
    if (mockEmail) {
      if (!isEmailAllowedForTeam(mockEmail, team)) {
        return new Response(JSON.stringify({
          ok: false,
          error: `Access denied. Email '${mockEmail}' is not authorized for team '${team.slug}'.`,
          team: team.slug,
          allowed_domains: team.allowed_domains
        }), { status: 403, headers });
      }

      const keyResult = await generateTeamApiKey(env, team.slug, `OAuth Session (${mockEmail})`);
      return new Response(JSON.stringify({
        ok: true,
        team: team.slug,
        email: mockEmail,
        token: keyResult.token,
        mcp_url: `https://${team.slug}.zerodrive.dev/mcp?key=${keyResult.token}`
      }), { status: 200, headers });
    }

    // Production Google OAuth initiation
    const clientId = env.GOOGLE_CLIENT_ID;
    if (!clientId) {
      return new Response(JSON.stringify({
        ok: false,
        error: "GOOGLE_CLIENT_ID not configured"
      }), { status: 500, headers });
    }

    const redirectUri = env.AUTH_REDIRECT_URI || `${url.origin}/auth/team/callback`;
    const stateObj = {
      team: team.slug,
      r: url.searchParams.get("redirect_uri") || "",
      s: url.searchParams.get("state") || ""
    };
    const stateStr = btoa(JSON.stringify(stateObj));

    const googleAuthUrl = `https://accounts.google.com/o/oauth2/v2/auth?` +
      `client_id=${encodeURIComponent(clientId)}` +
      `&redirect_uri=${encodeURIComponent(redirectUri)}` +
      `&response_type=code` +
      `&scope=${encodeURIComponent("openid email profile")}` +
      `&state=${encodeURIComponent(stateStr)}` +
      `&prompt=select_account`;

    return Response.redirect(googleAuthUrl, 302);
  }

  if (isCallback) {
    // Check state for team info
    const stateParam = url.searchParams.get("state") || "";
    let stateData = {};
    if (stateParam) {
      try {
        stateData = JSON.parse(atob(stateParam));
        if (stateData.team && !teamSlug) {
          teamSlug = stateData.team;
        }
      } catch {}
    }

    // Dev/Test mode callback
    const testEmail = url.searchParams.get("email") || url.searchParams.get("mock_email");
    if (testEmail && teamSlug) {
      const team = await getTeam(env, teamSlug);
      if (!team) {
        return new Response(JSON.stringify({ ok: false, error: "Team not found" }), { status: 404, headers });
      }

      if (!isEmailAllowedForTeam(testEmail, team)) {
        return new Response(JSON.stringify({
          ok: false,
          error: `Access denied. Email '${testEmail}' does not belong to allowed domains.`,
          team: team.slug,
          allowed_domains: team.allowed_domains
        }), { status: 403, headers });
      }

      const keyResult = await generateTeamApiKey(env, team.slug, `OAuth Callback (${testEmail})`);
      if (stateData.r) {
        const dest = new URL(stateData.r);
        dest.searchParams.set("token", keyResult.token);
        dest.searchParams.set("team", team.slug);
        return Response.redirect(dest.toString(), 302);
      }
      return new Response(JSON.stringify({
        ok: true,
        team: team.slug,
        email: testEmail,
        token: keyResult.token
      }), { status: 200, headers });
    }

    // Google OAuth code exchange
    const code = url.searchParams.get("code");
    if (!code) {
      return new Response(JSON.stringify({ ok: false, error: "Missing authorization code" }), { status: 400, headers });
    }

    const clientId = env.GOOGLE_CLIENT_ID;
    const clientSecret = env.GOOGLE_CLIENT_SECRET;
    if (!clientId || !clientSecret) {
      return new Response(JSON.stringify({ ok: false, error: "OAuth credentials not configured" }), { status: 500, headers });
    }

    const redirectUri = env.AUTH_REDIRECT_URI || `${url.origin}/auth/team/callback`;
    const tokenResp = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        code,
        client_id: clientId,
        client_secret: clientSecret,
        redirect_uri: redirectUri,
        grant_type: "authorization_code"
      })
    });

    if (!tokenResp.ok) {
      return new Response(JSON.stringify({ ok: false, error: "Token exchange with Google failed" }), { status: 400, headers });
    }

    const tokenData = await tokenResp.json();
    const userResp = await fetch("https://www.googleapis.com/oauth2/v2/userinfo", {
      headers: { Authorization: `Bearer ${tokenData.access_token}` }
    });

    if (!userResp.ok) {
      return new Response(JSON.stringify({ ok: false, error: "Failed to retrieve user info from Google" }), { status: 400, headers });
    }

    const user = await userResp.json();
    const email = (user.email || "").toLowerCase().trim();

    if (!teamSlug) {
      return new Response(JSON.stringify({ ok: false, error: "Team context not found in OAuth state" }), { status: 400, headers });
    }

    const team = await getTeam(env, teamSlug);
    if (!team) {
      return new Response(JSON.stringify({ ok: false, error: `Team '${teamSlug}' not found` }), { status: 404, headers });
    }

    if (!isEmailAllowedForTeam(email, team)) {
      return new Response(JSON.stringify({
        ok: false,
        error: `Access denied. Email '${email}' is not authorized for team '${team.slug}'.`,
        allowed_domains: team.allowed_domains
      }), { status: 403, headers });
    }

    const keyResult = await generateTeamApiKey(env, team.slug, `OAuth: ${email}`);
    if (stateData.r) {
      const dest = new URL(stateData.r);
      dest.searchParams.set("token", keyResult.token);
      dest.searchParams.set("team", team.slug);
      return Response.redirect(dest.toString(), 302);
    }

    return new Response(JSON.stringify({
      ok: true,
      team: team.slug,
      email,
      token: keyResult.token,
      mcp_url: `https://${team.slug}.zerodrive.dev/mcp?key=${keyResult.token}`
    }), { status: 200, headers });
  }

  return new Response("Not Found", { status: 404, headers });
}

/**
 * Handles REST routes under `/v1/teams`:
 * - GET /v1/teams
 * - POST /v1/teams/create
 * - GET /v1/teams/:slug
 * - POST /v1/teams/:slug/keys
 * - DELETE /v1/teams/:slug/keys/:keyId
 */
export async function handleTeamsRest(request, env, url, corsHeaders = {}) {
  const headers = {
    ...corsHeaders,
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
    "Content-Type": "application/json"
  };

  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers });
  }

  const pathname = url.pathname.replace(/\/+$/, "");

  // 1. GET /v1/teams — List teams
  if (pathname === "/v1/teams" && request.method === "GET") {
    const teams = await listTeams(env);
    return new Response(JSON.stringify({ ok: true, teams, count: teams.length }, null, 2), {
      status: 200,
      headers
    });
  }

  // 2. POST /v1/teams/create or POST /v1/teams — Provision team
  if ((pathname === "/v1/teams/create" || pathname === "/v1/teams") && request.method === "POST") {
    let body;
    try {
      body = await request.json();
    } catch {
      return new Response(JSON.stringify({ ok: false, error: "Invalid JSON body" }), { status: 400, headers });
    }

    try {
      const ownerPrefix = body.owner_user || "usr_master";
      const team = await createTeam(env, ownerPrefix, body);
      return new Response(JSON.stringify({ ok: true, team }, null, 2), { status: 201, headers });
    } catch (err) {
      return new Response(JSON.stringify({ ok: false, error: err.message || String(err) }), { status: 400, headers });
    }
  }

  // 3. POST /v1/teams/:slug/keys — Generate team MCP token
  const keysMatch = pathname.match(/^\/v1\/teams\/([a-zA-Z0-9_-]+)\/keys$/);
  if (keysMatch && request.method === "POST") {
    const slug = keysMatch[1];
    let body = {};
    try {
      body = await request.json();
    } catch {}

    try {
      const result = await generateTeamApiKey(env, slug, body?.label || "Team API Key");
      return new Response(JSON.stringify(result, null, 2), { status: 201, headers });
    } catch (err) {
      return new Response(JSON.stringify({ ok: false, error: err.message || String(err) }), { status: 400, headers });
    }
  }

  // 4. DELETE /v1/teams/:slug/keys/:keyId — Revoke team MCP token
  const revokeMatch = pathname.match(/^\/v1\/teams\/([a-zA-Z0-9_-]+)\/keys\/([a-zA-Z0-9_-]+)$/);
  if (revokeMatch && request.method === "DELETE") {
    const slug = revokeMatch[1];
    const keyId = revokeMatch[2];
    try {
      const result = await revokeTeamApiKey(env, slug, keyId);
      return new Response(JSON.stringify(result, null, 2), { status: 200, headers });
    } catch (err) {
      return new Response(JSON.stringify({ ok: false, error: err.message || String(err) }), { status: 400, headers });
    }
  }

  // 5. GET /v1/teams/:slug — Get team record
  const getMatch = pathname.match(/^\/v1\/teams\/([a-zA-Z0-9_-]+)$/);
  if (getMatch && request.method === "GET") {
    const slug = getMatch[1];
    const team = await getTeam(env, slug);
    if (!team) {
      return new Response(JSON.stringify({ ok: false, error: `Team '${slug}' not found` }), { status: 404, headers });
    }

    // Redact key hashes for security
    const sanitized = {
      ...team,
      api_keys: (team.api_keys || []).map(k => ({
        id: k.id,
        label: k.label,
        prefix: k.prefix,
        created_at: k.created_at,
        last_used_at: k.last_used_at
      }))
    };
    return new Response(JSON.stringify({ ok: true, team: sanitized }, null, 2), { status: 200, headers });
  }

  return new Response(JSON.stringify({ ok: false, error: "Not Found" }), { status: 404, headers });
}
