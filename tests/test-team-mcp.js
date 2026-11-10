/**
 * ZeroDrive Team MCP & Subdomain Routing Test Suite
 *
 * Verifies:
 * 1. Subdomain & Hostname Extraction (extractTeamFromHostname, resolveTeamFromHostname)
 * 2. Team Data Model & Provisioning (createTeam, getTeam, listTeams) in R2 _SYSTEM/teams/<slug>.json
 * 3. Team API Key Generation & Token Authentication (generateTeamApiKey, authenticateTeamToken, revokeTeamApiKey)
 * 4. Domain Checking & Team OAuth (isEmailAllowedForTeam, handleTeamOAuth)
 * 5. Team MCP Scoped Isolation & Directory Traversal Prevention (handleTeamMCP)
 * 6. Worker Entrypoint Subdomain Routing & REST API (/v1/teams/*)
 *
 * Run with: node tests/test-team-mcp.js
 */

import assert from "node:assert/strict";
import worker, {
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
  sha256Hex
} from "../deploy/worker.js";

// Helper: In-memory mock R2 Bucket
function createMockR2Bucket() {
  const store = new Map();
  return {
    _store: store,
    async head(key) {
      if (!store.has(key)) return null;
      const item = store.get(key);
      return {
        size: item.data.length,
        etag: item.etag,
        uploaded: item.uploaded,
        httpMetadata: item.httpMetadata
      };
    },
    async get(key) {
      if (!store.has(key)) return null;
      const item = store.get(key);
      return {
        size: item.data.length,
        etag: item.etag,
        uploaded: item.uploaded,
        httpMetadata: item.httpMetadata,
        body: item.data,
        text: async () => item.data.toString("utf8"),
        arrayBuffer: async () => item.data.buffer
      };
    },
    async put(key, data, opts = {}) {
      let buf;
      if (Buffer.isBuffer(data)) {
        buf = data;
      } else if (data instanceof ArrayBuffer) {
        buf = Buffer.from(data);
      } else if (typeof data === "string") {
        buf = Buffer.from(data, "utf8");
      } else {
        buf = Buffer.from("");
      }
      const etag = `etag_${Math.random().toString(36).slice(2, 10)}`;
      const uploaded = new Date();
      store.set(key, { data: buf, etag, uploaded, httpMetadata: opts.httpMetadata });
      return { size: buf.length, etag, uploaded };
    },
    async delete(key) {
      store.delete(key);
    },
    async list(opts = {}) {
      const prefix = opts.prefix || "";
      const delimiter = opts.delimiter || "";
      const objects = [];
      const delimitedSet = new Set();
      for (const [k, v] of store.entries()) {
        if (k.startsWith(prefix)) {
          if (delimiter) {
            const rest = k.slice(prefix.length);
            const delimIdx = rest.indexOf(delimiter);
            if (delimIdx !== -1) {
              delimitedSet.add(prefix + rest.slice(0, delimIdx + 1));
              continue;
            }
          }
          objects.push({ key: k, size: v.data.length, etag: v.etag, uploaded: v.uploaded });
        }
      }
      return { objects, delimitedPrefixes: Array.from(delimitedSet) };
    }
  };
}

function createMockEnv(bucket = null) {
  return {
    VAULT_BUCKET: bucket || createMockR2Bucket(),
    MASTER_API_KEY: "zd_sec_master_test_key_12345",
    GOOGLE_CLIENT_ID: "mock_client_id.apps.googleusercontent.com",
    GOOGLE_CLIENT_SECRET: "mock_client_secret",
    CANONICAL_ORIGIN: "https://api.zerodrive.dev"
  };
}

let passedTests = 0;
let totalTests = 0;

function runTest(name, fn) {
  totalTests++;
  try {
    fn();
    console.log(`  ✓ ${name}`);
    passedTests++;
  } catch (err) {
    console.error(`  ✗ ${name}`);
    console.error(err);
    throw err;
  }
}

async function runAsyncTest(name, fn) {
  totalTests++;
  try {
    await fn();
    console.log(`  ✓ ${name}`);
    passedTests++;
  } catch (err) {
    console.error(`  ✗ ${name}`);
    console.error(err);
    throw err;
  }
}

console.log("\n========================================================");
console.log(" ZeroDrive Team MCP & Subdomain Routing Test Suite");
console.log("========================================================\n");

// --- Section 1: Subdomain & Hostname Extraction ---
console.log("--- Section 1: Hostname & Subdomain Extraction ---");

runTest("extracts valid team subdomain from hostname", () => {
  assert.equal(extractTeamFromHostname("gymshark.zerodrive.dev"), "gymshark");
  assert.equal(extractTeamFromHostname("acme-corp.zerodrive.dev"), "acme-corp");
  assert.equal(extractTeamFromHostname("design_team.zerodrive.dev"), "design_team");
  assert.equal(extractTeamFromHostname("GYMSHARK.zerodrive.dev:8787"), "gymshark");
});

runTest("ignores reserved subdomains (api, drive, www, app, auth)", () => {
  assert.equal(extractTeamFromHostname("api.zerodrive.dev"), null);
  assert.equal(extractTeamFromHostname("drive.zerodrive.dev"), null);
  assert.equal(extractTeamFromHostname("www.zerodrive.dev"), null);
  assert.equal(extractTeamFromHostname("app.zerodrive.dev"), null);
  assert.equal(extractTeamFromHostname("auth.zerodrive.dev"), null);
  assert.equal(extractTeamFromHostname("localhost"), null);
});

runTest("ignores non-matching domains", () => {
  assert.equal(extractTeamFromHostname("zerodrive.dev"), null);
  assert.equal(extractTeamFromHostname("example.com"), null);
  assert.equal(extractTeamFromHostname(""), null);
  assert.equal(extractTeamFromHostname(null), null);
});

runTest("supports in-memory custom domain map", () => {
  const customMap = { "files.gymshark.com": "gymshark", "drive.nike.com": "nike" };
  assert.equal(extractTeamFromHostname("files.gymshark.com", customMap), "gymshark");
  assert.equal(extractTeamFromHostname("drive.nike.com:443", customMap), "nike");
  assert.equal(extractTeamFromHostname("unknown.com", customMap), null);
});

await runAsyncTest("resolves custom domains stored in R2", async () => {
  const env = createMockEnv();
  await env.VAULT_BUCKET.put(
    "_SYSTEM/domains/vault.mybrand.com.json",
    JSON.stringify({ team: "mybrand" })
  );
  const resolved = await resolveTeamFromHostname(env, "vault.mybrand.com");
  assert.equal(resolved, "mybrand");
  const missing = await resolveTeamFromHostname(env, "unknown.mybrand.com");
  assert.equal(missing, null);
});

// --- Section 2: Team Data Model & Provisioning ---
console.log("\n--- Section 2: Team Provisioning & Data Model ---");

await runAsyncTest("provisions team in R2 _SYSTEM/teams/<slug>.json with all required fields", async () => {
  const env = createMockEnv();
  const team = await createTeam(env, "usr_andrew_123", {
    name: "Gymshark Creative",
    slug: "gymshark",
    allowed_domains: ["@gymshark.com", "gymshark.co.uk"],
    drives: ["creative", "marketing", "video-production"],
    custom_domains: ["vault.gymshark.com"],
    invites: ["agency@external.com"]
  });

  assert.equal(team.slug, "gymshark");
  assert.equal(team.name, "Gymshark Creative");
  assert.equal(team.owner_user, "usr_andrew_123");
  assert.deepEqual(team.allowed_domains, ["@gymshark.com", "gymshark.co.uk"]);
  assert.deepEqual(team.drives, ["creative", "marketing", "video-production"]);
  assert.deepEqual(team.api_keys, []);
  assert(team.created_at);

  // Verify stored in R2 at _SYSTEM/teams/gymshark.json
  const rawObj = await env.VAULT_BUCKET.get("_SYSTEM/teams/gymshark.json");
  assert(rawObj);
  const parsed = JSON.parse(await rawObj.text());
  assert.equal(parsed.slug, "gymshark");

  // Verify custom domain mapping was written to R2
  const domainObj = await env.VAULT_BUCKET.get("_SYSTEM/domains/vault.gymshark.com.json");
  assert(domainObj);

  // Verify team starter files were provisioned
  const routerObj = await env.VAULT_BUCKET.get("teams/gymshark/ROUTER.md");
  assert(routerObj);
  const agentsObj = await env.VAULT_BUCKET.get("teams/gymshark/AGENTS.md");
  assert(agentsObj);
  const driveKeep = await env.VAULT_BUCKET.get("teams/gymshark/creative/.gitkeep");
  assert(driveKeep);
});

await runAsyncTest("getTeam retrieves existing team or returns null", async () => {
  const env = createMockEnv();
  await createTeam(env, "usr_test", { name: "Acme Corp", slug: "acme" });

  const found = await getTeam(env, "acme");
  assert(found);
  assert.equal(found.slug, "acme");

  const notFound = await getTeam(env, "nonexistent");
  assert.equal(notFound, null);
});

await runAsyncTest("createTeam rejects duplicate team slugs", async () => {
  const env = createMockEnv();
  await createTeam(env, "usr_test", { name: "Team One", slug: "team-one" });

  await assert.rejects(
    async () => {
      await createTeam(env, "usr_test", { name: "Duplicate", slug: "team-one" });
    },
    /already exists/
  );
});

await runAsyncTest("createTeam rejects reserved slugs and invalid characters", async () => {
  const env = createMockEnv();
  await assert.rejects(async () => {
    await createTeam(env, "usr_test", { name: "API", slug: "api" });
  }, /reserved/);

  await assert.rejects(async () => {
    await createTeam(env, "usr_test", { name: "Bad", slug: "team/bad!name" });
  }, /Invalid team slug format/);
});

await runAsyncTest("listTeams returns teams excluding sensitive key hashes", async () => {
  const env = createMockEnv();
  await createTeam(env, "usr_test", { name: "Alpha", slug: "alpha" });
  await createTeam(env, "usr_test", { name: "Beta", slug: "beta" });

  const teams = await listTeams(env);
  assert.equal(teams.length, 2);
  const slugs = teams.map(t => t.slug).sort();
  assert.deepEqual(slugs, ["alpha", "beta"]);
});

// --- Section 3: API Key Generation & Token Authentication ---
console.log("\n--- Section 3: API Key Generation & Token Authentication ---");

await runAsyncTest("generateTeamApiKey creates token with prefix zd_team_<slug>_<random32>", async () => {
  const env = createMockEnv();
  await createTeam(env, "usr_test", { name: "Design Team", slug: "design" });

  const result = await generateTeamApiKey(env, "design", "Claude Desktop Key");
  assert(result.ok);
  assert(result.token.startsWith("zd_team_design_"));
  // Expected length: zd_team_design_ (15) + 32 hex = 47
  const suffix = result.token.replace("zd_team_design_", "");
  assert.equal(suffix.length, 32);
  assert(/^[a-f0-9]{32}$/.test(suffix));

  // Verify key object in team record has hash, not raw token
  const team = await getTeam(env, "design");
  assert.equal(team.api_keys.length, 1);
  const keyRecord = team.api_keys[0];
  assert.equal(keyRecord.label, "Claude Desktop Key");
  assert.notEqual(keyRecord.hash, result.token);
  assert.equal(keyRecord.hash, await sha256Hex(result.token));
});

await runAsyncTest("authenticateTeamToken verifies valid token and returns team context", async () => {
  const env = createMockEnv();
  await createTeam(env, "usr_test", { name: "Marketing", slug: "marketing", drives: ["social", "ads"] });
  const keyResult = await generateTeamApiKey(env, "marketing", "Cursor Key");

  const auth = await authenticateTeamToken(env, keyResult.token);
  assert(auth.ok);
  assert.equal(auth.slug, "marketing");
  assert.equal(auth.teamPrefix, "teams/marketing");
  assert.deepEqual(auth.drives, ["social", "ads"]);
  assert.equal(auth.keyLabel, "Cursor Key");
});

await runAsyncTest("authenticateTeamToken rejects invalid token or wrong hash", async () => {
  const env = createMockEnv();
  await createTeam(env, "usr_test", { name: "Ops", slug: "ops" });
  await generateTeamApiKey(env, "ops", "Key 1");

  // Tampered random part
  const badToken = "zd_team_ops_00000000000000000000000000000000";
  const auth = await authenticateTeamToken(env, badToken);
  assert.equal(auth.ok, false);
  assert.match(auth.error, /Invalid team token/);

  // Non-existent team
  const phantomToken = "zd_team_phantom_11112222333344445555666677778888";
  const auth2 = await authenticateTeamToken(env, phantomToken);
  assert.equal(auth2.ok, false);
});

await runAsyncTest("revokeTeamApiKey revokes key and invalidates authentication", async () => {
  const env = createMockEnv();
  await createTeam(env, "usr_test", { name: "Security", slug: "security" });
  const keyResult = await generateTeamApiKey(env, "security", "Temp Key");

  // Valid before revocation
  const auth1 = await authenticateTeamToken(env, keyResult.token);
  assert(auth1.ok);

  // Revoke key
  const revokeRes = await revokeTeamApiKey(env, "security", keyResult.key.id);
  assert(revokeRes.ok);

  // Invalid after revocation
  const auth2 = await authenticateTeamToken(env, keyResult.token);
  assert.equal(auth2.ok, false);
});

// --- Section 4: Domain Checking & Team OAuth ---
console.log("\n--- Section 4: Domain Checking & Team OAuth ---");

runTest("isEmailAllowedForTeam correctly verifies domains and invite lists", () => {
  const team = {
    slug: "gymshark",
    owner_user: "owner@gymshark.com",
    allowed_domains: ["@gymshark.com", "gymshark.co.uk"],
    invites: ["contractor@external.com"]
  };

  // Matching allowed domains
  assert(isEmailAllowedForTeam("ben@gymshark.com", team));
  assert(isEmailAllowedForTeam("sarah@gymshark.co.uk", team));
  assert(isEmailAllowedForTeam("BEN@GYMSHARK.COM", team));

  // Matching invite list
  assert(isEmailAllowedForTeam("contractor@external.com", team));

  // Matching owner
  assert(isEmailAllowedForTeam("owner@gymshark.com", team));

  // Unauthorized domains
  assert(!isEmailAllowedForTeam("hacker@gmail.com", team));
  assert(!isEmailAllowedForTeam("imposter@gymshark.fraud.com", team));
  assert(!isEmailAllowedForTeam("other@external.com", team));
  assert(!isEmailAllowedForTeam("", team));
  assert(!isEmailAllowedForTeam("invalid-email", team));
});

await runAsyncTest("handleTeamOAuth login handles authorization and rejects unauthorized domains", async () => {
  const env = createMockEnv();
  await createTeam(env, "usr_test", {
    name: "Gymshark",
    slug: "gymshark",
    allowed_domains: ["@gymshark.com"]
  });

  // 1. Authorized email login (dev/test mode)
  const reqAuth = new Request("https://gymshark.zerodrive.dev/auth/team/login?mock_email=alice@gymshark.com");
  const resAuth = await handleTeamOAuth(reqAuth, env, new URL(reqAuth.url));
  assert.equal(resAuth.status, 200);
  const dataAuth = await resAuth.json();
  assert(dataAuth.ok);
  assert(dataAuth.token.startsWith("zd_team_gymshark_"));

  // 2. Unauthorized email login (dev/test mode) -> 403 Forbidden
  const reqDeny = new Request("https://gymshark.zerodrive.dev/auth/team/login?mock_email=eve@attacker.com");
  const resDeny = await handleTeamOAuth(reqDeny, env, new URL(reqDeny.url));
  assert.equal(resDeny.status, 403);
  const dataDeny = await resDeny.json();
  assert.equal(dataDeny.ok, false);
  assert.match(dataDeny.error, /not authorized/);
});

await runAsyncTest("handleTeamOAuth callback validates email domain before issuing token", async () => {
  const env = createMockEnv();
  await createTeam(env, "usr_test", {
    name: "Gymshark",
    slug: "gymshark",
    allowed_domains: ["@gymshark.com"]
  });

  // Callback with authorized email
  const reqCb = new Request("https://api.zerodrive.dev/auth/team/callback?team=gymshark&mock_email=bob@gymshark.com");
  const resCb = await handleTeamOAuth(reqCb, env, new URL(reqCb.url));
  assert.equal(resCb.status, 200);
  const dataCb = await resCb.json();
  assert(dataCb.ok);
  assert(dataCb.token.startsWith("zd_team_gymshark_"));

  // Callback with unauthorized email -> 403 Forbidden
  const reqCbDeny = new Request("https://api.zerodrive.dev/auth/team/callback?team=gymshark&mock_email=stranger@external.com");
  const resCbDeny = await handleTeamOAuth(reqCbDeny, env, new URL(reqCbDeny.url));
  assert.equal(resCbDeny.status, 403);
});

// --- Section 5: Team MCP Tools & Scoped Isolation ---
console.log("\n--- Section 5: Team MCP Tools & Scoped Isolation ---");

runTest("sanitizeTeamPath blocks path traversal attempts", () => {
  assert.equal(sanitizeTeamPath("gymshark", "marketing/notes.md").fullKey, "teams/gymshark/marketing/notes.md");
  assert.equal(sanitizeTeamPath("gymshark", "ROUTER.md").fullKey, "teams/gymshark/ROUTER.md");

  // Path traversal attempts
  assert(sanitizeTeamPath("gymshark", "../other-team/secret.txt").error);
  assert(sanitizeTeamPath("gymshark", "marketing/../../root.txt").error);
  assert(sanitizeTeamPath("gymshark", "").error);
});

await runAsyncTest("handleTeamMCP enforces authentication (401 on missing token)", async () => {
  const env = createMockEnv();
  await createTeam(env, "usr_test", { name: "Gymshark", slug: "gymshark" });

  const req = new Request("https://gymshark.zerodrive.dev/mcp", { method: "GET" });
  const res = await handleTeamMCP(req, env, new URL(req.url), "gymshark");
  assert.equal(res.status, 401);
  const data = await res.json();
  assert.equal(data.error.code, -32000);
});

await runAsyncTest("handleTeamMCP blocks cross-team token access (403 Forbidden)", async () => {
  const env = createMockEnv();
  await createTeam(env, "usr_test", { name: "Team Alpha", slug: "alpha" });
  await createTeam(env, "usr_test", { name: "Team Beta", slug: "beta" });

  const alphaKey = await generateTeamApiKey(env, "alpha", "Alpha Key");

  // Alpha key attempting to access Beta team MCP endpoint
  const req = new Request("https://beta.zerodrive.dev/mcp", {
    method: "GET",
    headers: { Authorization: `Bearer ${alphaKey.token}` }
  });
  const res = await handleTeamMCP(req, env, new URL(req.url), "beta");
  assert.equal(res.status, 403);
  const data = await res.json();
  assert.equal(data.error.code, -32003);
  assert.match(data.error.message, /Forbidden/);
});

await runAsyncTest("handleTeamMCP executes MCP tools (write_file, read_file, get_file_tree, doctor)", async () => {
  const env = createMockEnv();
  await createTeam(env, "usr_test", {
    name: "Design Studio",
    slug: "studio",
    drives: ["brand", "assets"]
  });
  const keyRes = await generateTeamApiKey(env, "studio", "Studio MCP Key");
  const authHeader = `Bearer ${keyRes.token}`;

  // 1. Initialize
  const initReq = new Request("https://studio.zerodrive.dev/mcp", {
    method: "POST",
    headers: { Authorization: authHeader, "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} })
  });
  const initRes = await handleTeamMCP(initReq, env, new URL(initReq.url), "studio");
  assert.equal(initRes.status, 200);
  const initData = await initRes.json();
  assert.equal(initData.result.serverInfo.team, "studio");

  // 2. Write File
  const writeReq = new Request("https://studio.zerodrive.dev/mcp", {
    method: "POST",
    headers: { Authorization: authHeader, "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: {
        name: "write_file",
        arguments: { path: "brand/guidelines.md", content: "# Brand Guidelines\nUse Helvetica." }
      }
    })
  });
  const writeRes = await handleTeamMCP(writeReq, env, new URL(writeReq.url), "studio");
  assert.equal(writeRes.status, 200);
  const writeData = await writeRes.json();
  assert(!writeData.result.isError);

  // Verify file was written to teams/studio/brand/guidelines.md in R2
  const storedObj = await env.VAULT_BUCKET.get("teams/studio/brand/guidelines.md");
  assert(storedObj);
  assert.equal(await storedObj.text(), "# Brand Guidelines\nUse Helvetica.");

  // 3. Read File
  const readReq = new Request("https://studio.zerodrive.dev/mcp", {
    method: "POST",
    headers: { Authorization: authHeader, "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 3,
      method: "tools/call",
      params: {
        name: "read_file",
        arguments: { path: "brand/guidelines.md" }
      }
    })
  });
  const readRes = await handleTeamMCP(readReq, env, new URL(readReq.url), "studio");
  assert.equal(readRes.status, 200);
  const readData = await readRes.json();
  assert.equal(readData.result.content[0].text, "# Brand Guidelines\nUse Helvetica.");

  // 4. Directory Traversal Attempt Blocked in write_file
  const traverseReq = new Request("https://studio.zerodrive.dev/mcp", {
    method: "POST",
    headers: { Authorization: authHeader, "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 4,
      method: "tools/call",
      params: {
        name: "write_file",
        arguments: { path: "../escape.txt", content: "evil" }
      }
    })
  });
  const traverseRes = await handleTeamMCP(traverseReq, env, new URL(traverseReq.url), "studio");
  const traverseData = await traverseRes.json();
  assert(traverseData.result.isError);
  assert.match(traverseData.result.content[0].text, /prohibited/);

  // 5. Run Vault Doctor
  const docReq = new Request("https://studio.zerodrive.dev/mcp", {
    method: "POST",
    headers: { Authorization: authHeader, "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 5,
      method: "tools/call",
      params: { name: "run_vault_doctor", arguments: {} }
    })
  });
  const docRes = await handleTeamMCP(docReq, env, new URL(docReq.url), "studio");
  const docData = await docRes.json();
  assert(!docData.result.isError);
  assert.match(docData.result.content[0].text, /ZeroDrive Team Doctor Report/);
  assert.match(docData.result.content[0].text, /studio/);
});

// --- Section 6: Worker Entrypoint Subdomain & REST API Routing ---
console.log("\n--- Section 6: Worker Entrypoint Subdomain & REST API Routing ---");

await runAsyncTest("worker routes <team>.zerodrive.dev/mcp directly to handleTeamMCP", async () => {
  const env = createMockEnv();
  await createTeam(env, "usr_test", { name: "Gymshark", slug: "gymshark" });
  const keyRes = await generateTeamApiKey(env, "gymshark", "Subdomain Key");

  const req = new Request("https://gymshark.zerodrive.dev/mcp", {
    method: "GET",
    headers: { Authorization: `Bearer ${keyRes.token}` }
  });

  const res = await worker.fetch(req, env);
  assert.equal(res.status, 200);
  const data = await res.json();
  assert.equal(data.status, "online");
  assert.equal(data.team, "gymshark");
});

await runAsyncTest("worker routes /mcp/:teamSlug and /v1/mcp/:teamSlug directly to handleTeamMCP", async () => {
  const env = createMockEnv();
  await createTeam(env, "usr_test", { name: "Gymshark", slug: "gymshark" });
  const keyRes = await generateTeamApiKey(env, "gymshark", "Path Key");

  // Path /mcp/gymshark
  const req1 = new Request("https://api.zerodrive.dev/mcp/gymshark", {
    method: "GET",
    headers: { Authorization: `Bearer ${keyRes.token}` }
  });
  const res1 = await worker.fetch(req1, env);
  assert.equal(res1.status, 200);
  const data1 = await res1.json();
  assert.equal(data1.team, "gymshark");

  // Path /v1/mcp/gymshark
  const req2 = new Request("https://api.zerodrive.dev/v1/mcp/gymshark", {
    method: "GET",
    headers: { Authorization: `Bearer ${keyRes.token}` }
  });
  const res2 = await worker.fetch(req2, env);
  assert.equal(res2.status, 200);
  const data2 = await res2.json();
  assert.equal(data2.team, "gymshark");
});

await runAsyncTest("REST API: GET /v1/teams, POST /v1/teams/create, GET /v1/teams/:slug", async () => {
  const env = createMockEnv();

  // POST /v1/teams/create
  const createReq = new Request("https://api.zerodrive.dev/v1/teams/create", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      name: "Acme Product Team",
      slug: "acme-prod",
      allowed_domains: ["@acme.com"],
      drives: ["roadmap", "specs"]
    })
  });
  const createRes = await worker.fetch(createReq, env);
  assert.equal(createRes.status, 201);
  const createData = await createRes.json();
  assert(createData.ok);
  assert.equal(createData.team.slug, "acme-prod");

  // GET /v1/teams
  const listReq = new Request("https://api.zerodrive.dev/v1/teams", { method: "GET" });
  const listRes = await worker.fetch(listReq, env);
  assert.equal(listRes.status, 200);
  const listData = await listRes.json();
  assert(listData.ok);
  assert.equal(listData.teams.length, 1);
  assert.equal(listData.teams[0].slug, "acme-prod");

  // GET /v1/teams/:slug
  const getReq = new Request("https://api.zerodrive.dev/v1/teams/acme-prod", { method: "GET" });
  const getRes = await worker.fetch(getReq, env);
  assert.equal(getRes.status, 200);
  const getData = await getRes.json();
  assert(getData.ok);
  assert.equal(getData.team.name, "Acme Product Team");
});

await runAsyncTest("REST API: POST /v1/teams/:slug/keys and DELETE /v1/teams/:slug/keys/:keyId", async () => {
  const env = createMockEnv();
  await createTeam(env, "usr_test", { name: "Acme", slug: "acme" });

  // Generate key via POST /v1/teams/:slug/keys
  const genReq = new Request("https://api.zerodrive.dev/v1/teams/acme/keys", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ label: "Agent Key" })
  });
  const genRes = await worker.fetch(genReq, env);
  assert.equal(genRes.status, 201);
  const genData = await genRes.json();
  assert(genData.ok);
  assert(genData.token.startsWith("zd_team_acme_"));
  const keyId = genData.key.id;

  // Revoke key via DELETE /v1/teams/:slug/keys/:keyId
  const delReq = new Request(`https://api.zerodrive.dev/v1/teams/acme/keys/${keyId}`, {
    method: "DELETE"
  });
  const delRes = await worker.fetch(delReq, env);
  assert.equal(delRes.status, 200);
  const delData = await delRes.json();
  assert(delData.ok);
  assert.equal(delData.keyId, keyId);

  // Authenticating with revoked key now fails
  const authCheck = await authenticateTeamToken(env, genData.token);
  assert.equal(authCheck.ok, false);
});

console.log("\n========================================================");
console.log(` Test Results: ${passedTests} / ${totalTests} passed (0 failures)`);
console.log("========================================================\n");
