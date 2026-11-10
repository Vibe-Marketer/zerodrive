/**
 * ZeroDrive Multi-Drive Provisioning & Domain Isolation Test Suite
 *
 * Verifies:
 * 1. Default primary drive provisioning with quota and stats.
 * 2. Multi-drive creation with slugified IDs, R2 folder initialization, and activity logging.
 * 3. Drive lookup via getDrive and GET /v1/drives/:id.
 * 4. Strict path prefix isolation between primary and secondary drives.
 * 5. Safe drive deletion, primary drive protection, and purge cleanup.
 * 6. Cloudflare Worker REST API routing for /v1/drives endpoints.
 *
 * Run with: node tests/test-multi-drive.js
 */

import assert from "node:assert/strict";
import worker, {
  listDrives,
  createDrive,
  getDrive,
  deleteDrive,
  resolveDrivePrefix,
  slugifyDriveName,
  calculateDriveStats
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
      } else if (data instanceof Uint8Array) {
        buf = Buffer.from(data);
      } else {
        buf = Buffer.from("");
      }
      const etag = `etag_${Math.random().toString(36).slice(2, 10)}`;
      const uploaded = new Date();
      store.set(key, { data: buf, etag, uploaded, httpMetadata: opts?.httpMetadata });
      return { size: buf.length, etag, uploaded };
    },
    async delete(key) {
      store.delete(key);
    },
    async list(opts = {}) {
      const prefix = opts.prefix || "";
      const objects = [];
      const delimitedSet = new Set();
      for (const [k, v] of store.entries()) {
        if (k.startsWith(prefix)) {
          objects.push({ key: k, size: v.data.length, etag: v.etag, uploaded: v.uploaded });
          const rest = k.slice(prefix.length);
          const slash = rest.indexOf("/");
          if (slash !== -1) {
            delimitedSet.add(prefix + rest.slice(0, slash + 1));
          }
        }
      }
      return { objects, delimitedPrefixes: Array.from(delimitedSet) };
    }
  };
}

let passedTests = 0;
let totalTests = 0;

async function test(name, fn) {
  totalTests++;
  try {
    await fn();
    passedTests++;
    console.log(`  ✓ ${name}`);
  } catch (err) {
    console.error(`  ✗ ${name}`);
    console.error(err);
    throw err;
  }
}

async function runTests() {
  console.log("\n========================================================");
  console.log(" ZeroDrive Multi-Drive Provisioning & Isolation Engine");
  console.log("========================================================\n");

  const userPrefix = "tenants/zd_tenant_1/usr_alice_123";

  // Section 1: Utility and Slugification Tests
  console.log("--- Section 1: Drive Naming & Prefix Resolution ---");

  await test("slugifyDriveName converts arbitrary titles to url-safe slugs", () => {
    assert.equal(slugifyDriveName("Work Documents 2026!"), "work-documents-2026");
    assert.equal(slugifyDriveName("  --Media-Vault--  "), "media-vault");
    assert.equal(slugifyDriveName("Clients & Invoices #4"), "clients-invoices-4");
    assert.equal(slugifyDriveName(""), "drive");
    assert.equal(slugifyDriveName(null), "drive");
  });

  await test("resolveDrivePrefix resolves primary vs secondary drive paths correctly", () => {
    // Default primary drive prefix
    assert.equal(resolveDrivePrefix(userPrefix, null), userPrefix);
    assert.equal(resolveDrivePrefix(userPrefix, "primary"), userPrefix);
    assert.equal(resolveDrivePrefix(userPrefix, "default"), userPrefix);
    assert.equal(resolveDrivePrefix(userPrefix, "root"), userPrefix);

    // Secondary isolated drive prefixes
    assert.equal(resolveDrivePrefix(userPrefix, "work-docs"), `${userPrefix}/drives/work-docs`);
    assert.equal(resolveDrivePrefix(userPrefix, "finance"), `${userPrefix}/drives/finance`);
  });

  // Section 2: Core Multi-Drive Operations
  console.log("\n--- Section 2: Multi-Drive Operations (drives.js) ---");

  const mockBucket = createMockR2Bucket();
  const env = {
    VAULT_BUCKET: mockBucket,
    DEFAULT_QUOTA_TB: "5.0",
    MASTER_API_KEY: "zd_test_key"
  };

  await test("listDrives on new vault always includes default primary drive with quota and stats", async () => {
    const drives = await listDrives(env, userPrefix);
    assert.ok(Array.isArray(drives));
    assert.equal(drives.length, 1);

    const primary = drives[0];
    assert.equal(primary.id, "primary");
    assert.equal(primary.is_default, true);
    assert.equal(primary.quota_gb, 5120);
    assert.equal(primary.status, "active");
    assert.ok(primary.stats);
    assert.equal(primary.file_count, 0);
    assert.equal(primary.used_bytes, 0);
  });

  let createdWorkDrive;
  await test("createDrive provisions new secondary drive with slugified ID and .keep placeholder", async () => {
    createdWorkDrive = await createDrive(env, userPrefix, {
      name: "Work Projects & Code",
      description: "Company engineering vault",
      quota_gb: 2000
    });

    assert.equal(createdWorkDrive.id, "work-projects-code");
    assert.equal(createdWorkDrive.name, "Work Projects & Code");
    assert.equal(createdWorkDrive.quota_gb, 2000);
    assert.equal(createdWorkDrive.is_default, false);
    assert.equal(createdWorkDrive.status, "active");
    assert.equal(createdWorkDrive.prefix, "drives/work-projects-code");

    // Verify .keep folder placeholder exists in R2
    const placeholder = await mockBucket.head(`${userPrefix}/drives/work-projects-code/.keep`);
    assert.ok(placeholder, "R2 folder placeholder .keep must be initialized");

    // Verify stored in _SYSTEM/drives.json
    const drivesObj = await mockBucket.get(`${userPrefix}/_SYSTEM/drives.json`);
    assert.ok(drivesObj);
    const drivesList = JSON.parse(await drivesObj.text());
    assert.ok(drivesList.some(d => d.id === "work-projects-code"));

    // Verify activity ledger logged drive creation
    const activityObj = await mockBucket.get(`${userPrefix}/_SYSTEM/activity.json`);
    assert.ok(activityObj);
    const activities = JSON.parse(await activityObj.text());
    assert.ok(activities.some(a => a.action === "create_drive" && a.drive_id === "work-projects-code"));
  });

  await test("listDrives now includes both primary and created secondary drive", async () => {
    const drives = await listDrives(env, userPrefix);
    assert.equal(drives.length, 2);
    assert.equal(drives[0].id, "primary");
    assert.equal(drives[1].id, "work-projects-code");
  });

  await test("getDrive returns drive details by ID or alias", async () => {
    const primary = await getDrive(env, userPrefix, "primary");
    assert.ok(primary);
    assert.equal(primary.id, "primary");

    const defaultAlias = await getDrive(env, userPrefix, "default");
    assert.ok(defaultAlias);
    assert.equal(defaultAlias.id, "primary");

    const work = await getDrive(env, userPrefix, "work-projects-code");
    assert.ok(work);
    assert.equal(work.name, "Work Projects & Code");

    const missing = await getDrive(env, userPrefix, "non-existent-drive");
    assert.equal(missing, null);
  });

  // Section 3: Path Prefix Isolation & Storage Stats
  console.log("\n--- Section 3: Path Prefix Isolation & Storage Stats ---");

  await test("Writing files into different drives isolates prefixes and stats", async () => {
    // 1. Write file to primary drive
    const primaryFileKey = `${userPrefix}/documents/notes.txt`;
    await mockBucket.put(primaryFileKey, "Hello Primary Vault!");

    // 2. Write file to secondary drive
    const secondaryPrefix = resolveDrivePrefix(userPrefix, "work-projects-code");
    const secondaryFileKey = `${secondaryPrefix}/src/app.py`;
    await mockBucket.put(secondaryFileKey, "print('Hello Work Drive!')");

    // Check stats for primary drive (excludes drives/ and _SYSTEM/)
    const primaryStats = await calculateDriveStats(env, userPrefix, "primary");
    assert.equal(primaryStats.file_count, 1);
    assert.equal(primaryStats.used_bytes, Buffer.byteLength("Hello Primary Vault!"));

    // Check stats for secondary drive (only includes work-projects-code)
    // Note: includes the file and the .keep placeholder
    const secondaryStats = await calculateDriveStats(env, userPrefix, "work-projects-code");
    assert.equal(secondaryStats.file_count, 2); // .keep + app.py
    assert.equal(secondaryStats.used_bytes, Buffer.byteLength("print('Hello Work Drive!')"));
  });

  // Section 4: Drive Deletion Safeguards & Purge
  console.log("\n--- Section 4: Drive Deletion & Safeguards ---");

  await test("deleteDrive rejects deletion of the primary / default drive", async () => {
    const delPrimary = await deleteDrive(env, userPrefix, "primary");
    assert.equal(delPrimary.ok, false);
    assert.match(delPrimary.error, /Cannot delete the default primary drive/);

    const delDefault = await deleteDrive(env, userPrefix, "default");
    assert.equal(delDefault.ok, false);
    assert.match(delDefault.error, /Cannot delete the default primary drive/);
  });

  await test("deleteDrive removes custom drive and logs deletion in activity ledger", async () => {
    const result = await deleteDrive(env, userPrefix, "work-projects-code");
    assert.equal(result.ok, true);
    assert.equal(result.status, "deleted");

    // Drive should no longer be listed
    const drives = await listDrives(env, userPrefix);
    assert.equal(drives.length, 1);
    assert.equal(drives[0].id, "primary");

    // Activity ledger logs delete_drive
    const activityObj = await mockBucket.get(`${userPrefix}/_SYSTEM/activity.json`);
    const activities = JSON.parse(await activityObj.text());
    assert.ok(activities.some(a => a.action === "delete_drive" && a.drive_id === "work-projects-code"));
  });

  await test("deleteDrive with purge: true cleans up all R2 objects under drive prefix", async () => {
    // Provision temp drive and create a file in it
    const tempDrive = await createDrive(env, userPrefix, { name: "Temp Scratch" });
    const tempFileKey = `${userPrefix}/drives/${tempDrive.id}/scratch.tmp`;
    await mockBucket.put(tempFileKey, "temporary scratch data");

    // Verify file exists
    assert.ok(await mockBucket.head(tempFileKey));

    // Delete with purge
    const result = await deleteDrive(env, userPrefix, tempDrive.id, { purge: true });
    assert.equal(result.ok, true);

    // Verify file and .keep are purged from R2
    assert.equal(await mockBucket.head(tempFileKey), null);
    assert.equal(await mockBucket.head(`${userPrefix}/drives/${tempDrive.id}/.keep`), null);
  });

  // Section 5: REST Worker Integration Tests (/v1/drives)
  console.log("\n--- Section 5: Worker REST API (/v1/drives) Integration ---");

  const restBucket = createMockR2Bucket();
  const restEnv = {
    VAULT_BUCKET: restBucket,
    MASTER_API_KEY: "zd_test_master_token",
    DEFAULT_QUOTA_TB: "5.0"
  };

  const headers = {
    Authorization: "Bearer zd_test_master_token",
    "Content-Type": "application/json"
  };

  await test("GET /v1/drives returns list with primary drive", async () => {
    const req = new Request("https://api.zerodrive.dev/v1/drives", {
      method: "GET",
      headers
    });
    const res = await worker.fetch(req, restEnv);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.ok, true);
    assert.equal(body.drives.length, 1);
    assert.equal(body.drives[0].id, "primary");
    assert.equal(body.drives[0].is_default, true);
  });

  let restDriveId;
  await test("POST /v1/drives provisions new drive via REST endpoint", async () => {
    const req = new Request("https://api.zerodrive.dev/v1/drives", {
      method: "POST",
      headers,
      body: JSON.stringify({
        name: "Design Vault",
        description: "Figma assets and media",
        quota_gb: 500
      })
    });
    const res = await worker.fetch(req, restEnv);
    assert.equal(res.status, 201);
    const body = await res.json();
    assert.equal(body.ok, true);
    assert.equal(body.drive.id, "design-vault");
    assert.equal(body.drive.quota_gb, 500);
    restDriveId = body.drive.id;
  });

  await test("POST /v1/drives/create alias also works", async () => {
    const req = new Request("https://api.zerodrive.dev/v1/drives/create", {
      method: "POST",
      headers,
      body: JSON.stringify({
        name: "Archive Vault",
        quota_gb: 100
      })
    });
    const res = await worker.fetch(req, restEnv);
    assert.equal(res.status, 201);
    const body = await res.json();
    assert.equal(body.ok, true);
    assert.equal(body.drive.id, "archive-vault");
  });

  await test("POST /v1/drives validates required name parameter", async () => {
    const req = new Request("https://api.zerodrive.dev/v1/drives", {
      method: "POST",
      headers,
      body: JSON.stringify({ description: "No name provided" })
    });
    const res = await worker.fetch(req, restEnv);
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.equal(body.ok, false);
    assert.match(body.error, /required/);
  });

  await test("GET /v1/drives/:id retrieves single drive details", async () => {
    const req = new Request(`https://api.zerodrive.dev/v1/drives/${restDriveId}`, {
      method: "GET",
      headers
    });
    const res = await worker.fetch(req, restEnv);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.ok, true);
    assert.equal(body.drive.name, "Design Vault");

    // Check 404 for missing drive
    const req404 = new Request("https://api.zerodrive.dev/v1/drives/unknown-drive-id", {
      method: "GET",
      headers
    });
    const res404 = await worker.fetch(req404, restEnv);
    assert.equal(res404.status, 404);
  });

  await test("Cross-drive file write and listing isolation via REST API", async () => {
    // Write a file to Design Vault
    const writeReq = new Request(`https://api.zerodrive.dev/v1/files/write?drive_id=${restDriveId}`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        path: "mockups/homepage.png",
        content: "png_bytes_data"
      })
    });
    const writeRes = await worker.fetch(writeReq, restEnv);
    assert.equal(writeRes.status, 200);

    // List files in Design Vault
    const listDesignReq = new Request(`https://api.zerodrive.dev/v1/files?drive_id=${restDriveId}&recursive=true`, {
      method: "GET",
      headers
    });
    const listDesignRes = await worker.fetch(listDesignReq, restEnv);
    assert.equal(listDesignRes.status, 200);
    const designFiles = await listDesignRes.json();
    assert.ok(designFiles.files.some(f => f.path === "mockups/homepage.png"));

    // List files in Primary Vault — should NOT see Design Vault files
    const listPrimaryReq = new Request("https://api.zerodrive.dev/v1/files?recursive=true", {
      method: "GET",
      headers
    });
    const listPrimaryRes = await worker.fetch(listPrimaryReq, restEnv);
    const primaryFiles = await listPrimaryRes.json();
    assert.ok(!primaryFiles.files.some(f => f.path === "mockups/homepage.png"));
  });

  await test("DELETE /v1/drives/:id protects primary and deletes custom drive", async () => {
    // 1. Try deleting primary drive -> Expect 400
    const delPrimaryReq = new Request("https://api.zerodrive.dev/v1/drives/primary", {
      method: "DELETE",
      headers
    });
    const delPrimaryRes = await worker.fetch(delPrimaryReq, restEnv);
    assert.equal(delPrimaryRes.status, 400);

    // 2. Delete custom drive -> Expect 200
    const delCustomReq = new Request(`https://api.zerodrive.dev/v1/drives/${restDriveId}`, {
      method: "DELETE",
      headers
    });
    const delCustomRes = await worker.fetch(delCustomReq, restEnv);
    assert.equal(delCustomRes.status, 200);
    const body = await delCustomRes.json();
    assert.equal(body.ok, true);

    // 3. Confirm it is gone
    const verifyReq = new Request(`https://api.zerodrive.dev/v1/drives/${restDriveId}`, {
      method: "GET",
      headers
    });
    const verifyRes = await worker.fetch(verifyReq, restEnv);
    assert.equal(verifyRes.status, 404);
  });

  console.log("\n========================================================");
  console.log(` Test Results: ${passedTests} / ${totalTests} passed (0 failures)`);
  console.log("========================================================\n");
}

runTests().catch((err) => {
  console.error("Test Suite Failed:", err);
  process.exit(1);
});
