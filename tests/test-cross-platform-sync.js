/**
 * ZeroDrive Cross-Platform Filename Sanitization & Conflict Resolution Test Suite
 *
 * Verifies:
 * 1. Windows illegal character rejection & safe sanitization
 * 2. Windows reserved device name handling (CON, PRN, AUX, NUL, COM1-9, LPT1-9)
 * 3. Unicode normalization (NFC vs NFD Mac decomposition)
 * 4. Concurrent edit conflict branch simulation (X-Conflict-Policy: branch | overwrite)
 * 5. Filesystem endpoints: /v1/files/write, /v1/files/move, /v1/files/rename, /v1/files/mkdir
 *
 * Run with: node tests/test-cross-platform-sync.js
 */

import assert from "node:assert/strict";
import worker, {
  isWindowsReservedName,
  normalizeUnicode,
  validateCrossPlatformPath,
  sanitizeCrossPlatformPath,
  generateConflictedPath,
  evaluateConflict
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
    process.exitCode = 1;
  }
}

async function runTestSuite() {
  console.log("\n========================================================");
  console.log(" ZeroDrive Cross-Platform Sanitizer & Conflict Engine");
  console.log("========================================================\n");

  console.log("--- Section 1: Windows Illegal Characters & Trailing Dots/Spaces ---");

  await test("Windows forbidden characters are flagged by validateCrossPlatformPath", () => {
    const forbidden = [":", "*", "?", '"', "<", ">", "|", "\\", "\x00", "\x1F"];
    for (const char of forbidden) {
      const path = `docs/file${char}name.txt`;
      const res = validateCrossPlatformPath(path);
      assert.equal(res.valid, false, `Expected forbidden char '${char}' to be invalid`);
    }
  });

  await test("Trailing dots and spaces on path segments are rejected", () => {
    const invalidPaths = [
      "folder/test. ",
      "docs/notes.",
      "my directory /file.txt",
      "test...",
      "archive.tar.gz."
    ];
    for (const p of invalidPaths) {
      const res = validateCrossPlatformPath(p);
      assert.equal(res.valid, false, `Expected '${p}' to be invalid due to trailing dot/space`);
      assert.match(res.error, /trailing space or dot/);
    }
  });

  await test("Directory traversal with '..' is rejected", () => {
    const res = validateCrossPlatformPath("folder/../../etc/passwd");
    assert.equal(res.valid, false);
    assert.match(res.error, /directory traversal/);
  });

  await test("sanitizeCrossPlatformPath safely replaces forbidden chars and trims trailing dots/spaces", () => {
    assert.equal(sanitizeCrossPlatformPath("bad:file*name?.txt"), "bad_file_name_.txt");
    assert.equal(sanitizeCrossPlatformPath("docs/report <final> | v1.pdf"), "docs/report _final_ _ v1.pdf");
    assert.equal(sanitizeCrossPlatformPath("folder. /test. "), "folder/test");
    assert.equal(sanitizeCrossPlatformPath("deep\\windows\\path\\file.txt"), "deep/windows/path/file.txt");
    assert.equal(sanitizeCrossPlatformPath("folder//sub///file.txt"), "folder/sub/file.txt");
  });

  await test("Strict mode in sanitizeCrossPlatformPath throws error on invalid input", () => {
    assert.throws(() => {
      sanitizeCrossPlatformPath("invalid:char.txt", { strict: true });
    }, /Invalid cross-platform path/);
  });

  console.log("\n--- Section 2: Windows Reserved DOS Device Names ---");

  const reservedStems = [
    "CON", "PRN", "AUX", "NUL",
    "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
    "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
  ];

  await test("isWindowsReservedName identifies all DOS reserved device names case-insensitively", () => {
    for (const stem of reservedStems) {
      assert.equal(isWindowsReservedName(stem), true, `${stem} should be reserved`);
      assert.equal(isWindowsReservedName(stem.toLowerCase()), true, `${stem.toLowerCase()} should be reserved`);
      assert.equal(isWindowsReservedName(`${stem}.txt`), true, `${stem}.txt should be reserved`);
      assert.equal(isWindowsReservedName(`${stem.toLowerCase()}.json`), true, `${stem.toLowerCase()}.json should be reserved`);
      assert.equal(isWindowsReservedName(`${stem}.tar.gz`), true, `${stem}.tar.gz should be reserved`);
    }
  });

  await test("Non-reserved prefixes are NOT falsely identified as reserved", () => {
    const safeNames = ["contact.txt", "content.md", "auxiliary.js", "nullify.py", "complex.ts", "prompt.sh"];
    for (const name of safeNames) {
      assert.equal(isWindowsReservedName(name), false, `${name} should NOT be reserved`);
    }
  });

  await test("validateCrossPlatformPath rejects reserved device names in root and subdirectories", () => {
    assert.equal(validateCrossPlatformPath("con.txt").valid, false);
    assert.equal(validateCrossPlatformPath("sub/AUX.log").valid, false);
    assert.equal(validateCrossPlatformPath("COM1/data.csv").valid, false);
    assert.equal(validateCrossPlatformPath("lpt9").valid, false);
  });

  await test("sanitizeCrossPlatformPath safely renames reserved device names", () => {
    assert.equal(sanitizeCrossPlatformPath("con.txt"), "con_.txt");
    assert.equal(sanitizeCrossPlatformPath("AUX"), "AUX_");
    assert.equal(sanitizeCrossPlatformPath("docs/COM1.log"), "docs/COM1_.log");
    assert.equal(sanitizeCrossPlatformPath("folder/nul.tar.gz"), "folder/nul_.tar.gz");
    assert.equal(sanitizeCrossPlatformPath("LPT3/test.txt"), "LPT3_/test.txt");
  });

  console.log("\n--- Section 3: Unicode Normalization (Mac NFD vs Canonical NFC) ---");

  await test("Normalizes decomposed macOS NFD filenames to canonical NFC", () => {
    // 'café': 'e' + combining acute accent (\u0065\u0301) vs '\u00e9'
    const nfdCafe = "cafe\u0301.txt";
    const nfcCafe = "caf\u00e9.txt";
    assert.notEqual(nfdCafe, nfcCafe);
    assert.equal(nfdCafe.length, 9);
    assert.equal(nfcCafe.length, 8);

    const normalized = normalizeUnicode(nfdCafe);
    assert.equal(normalized, nfcCafe);
    assert.equal(normalized.length, 8);

    assert.equal(sanitizeCrossPlatformPath(nfdCafe), nfcCafe);

    // 'résumé'
    const nfdResume = "re\u0301sume\u0301.pdf";
    const nfcResume = "r\u00e9sum\u00e9.pdf";
    assert.equal(sanitizeCrossPlatformPath(nfdResume), nfcResume);

    // German umlauts 'über'
    const nfdUmlaut = "u\u0308ber-sync.doc";
    const nfcUmlaut = "\u00fcber-sync.doc";
    assert.equal(sanitizeCrossPlatformPath(nfdUmlaut), nfcUmlaut);
  });

  console.log("\n--- Section 4: Conflict Resolution Engine & Branching Simulation ---");

  await test("generateConflictedPath formats cross-platform branch name correctly", () => {
    const fixedDate = new Date("2026-11-09T17:39:44.000Z");
    const branched = generateConflictedPath("docs/project-plan.md", "macbook-air", fixedDate);
    assert.equal(branched, "docs/project-plan (Conflicted copy - macbook-air - 2026-11-09T17-39-44Z).md");

    // No extension
    const noExt = generateConflictedPath("README", "win-desktop", fixedDate);
    assert.equal(noExt, "README (Conflicted copy - win-desktop - 2026-11-09T17-39-44Z)");

    // Compound extension (.tar.gz)
    const compound = generateConflictedPath("archive.tar.gz", "linux-server", fixedDate);
    assert.equal(compound, "archive (Conflicted copy - linux-server - 2026-11-09T17-39-44Z).tar.gz");

    // Conflicted path itself contains NO illegal Windows characters (no colons)
    assert.equal(validateCrossPlatformPath(branched).valid, true);
    assert.equal(validateCrossPlatformPath(compound).valid, true);
  });

  await test("evaluateConflict branches when ETag mismatches under policy 'branch'", () => {
    const existingMeta = {
      etag: "etag_server_v2",
      uploaded: new Date("2026-11-09T17:00:00Z")
    };
    const evalRes = evaluateConflict({
      existingMeta,
      clientEtag: "etag_client_v1", // Stale client base
      conflictPolicy: "branch",
      targetPath: "notes.txt",
      clientId: "device-mac",
      conflictTimestamp: new Date("2026-11-09T17:39:44Z")
    });

    assert.equal(evalRes.isConflict, true);
    assert.equal(evalRes.action, "branch");
    assert.equal(evalRes.reason, "etag_mismatch");
    assert.equal(evalRes.originalPath, "notes.txt");
    assert.match(evalRes.targetPath, /^notes \(Conflicted copy - device-mac - .+\)\.txt$/);
  });

  await test("evaluateConflict overwrites when policy 'overwrite' is specified despite conflict", () => {
    const existingMeta = {
      etag: "etag_server_v2",
      uploaded: new Date("2026-11-09T17:00:00Z")
    };
    const evalRes = evaluateConflict({
      existingMeta,
      clientEtag: "etag_client_v1",
      conflictPolicy: "overwrite",
      targetPath: "notes.txt"
    });

    assert.equal(evalRes.isConflict, true);
    assert.equal(evalRes.action, "overwrite");
    assert.equal(evalRes.targetPath, "notes.txt");
  });

  await test("evaluateConflict branches when server file is newer than client timestamp", () => {
    const existingMeta = {
      etag: "etag_server_v2",
      uploaded: new Date("2026-11-09T18:00:00Z")
    };
    const evalRes = evaluateConflict({
      existingMeta,
      clientTimestamp: "2026-11-09T17:00:00Z", // Client edited an older version offline
      conflictPolicy: "branch",
      targetPath: "data.json",
      clientId: "device-win"
    });

    assert.equal(evalRes.isConflict, true);
    assert.equal(evalRes.action, "branch");
    assert.equal(evalRes.reason, "timestamp_outdated");
    assert.match(evalRes.targetPath, /^data \(Conflicted copy - device-win - .+\)\.json$/);
  });

  console.log("\n--- Section 5: API Worker Endpoint Integration Tests ---");

  const env = {
    VAULT_BUCKET: createMockR2Bucket(),
    MASTER_API_KEY: "zd_test_master_token"
  };

  const authHeaders = {
    Authorization: "Bearer zd_test_master_token",
    "Content-Type": "application/json"
  };

  await test("POST /v1/files/write rejects invalid Windows path with 400 error", async () => {
    const req = new Request("https://api.zerodrive.dev/v1/files/write", {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({
        path: "folder/invalid:name?.txt",
        content: "test"
      })
    });
    const res = await worker.fetch(req, env);
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.equal(body.ok, false);
    assert.match(body.error, /forbidden character/);
  });

  await test("POST /v1/files/write rejects Windows reserved DOS name with 400 error", async () => {
    const req = new Request("https://api.zerodrive.dev/v1/files/write", {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({
        path: "docs/aux.json",
        content: "{}"
      })
    });
    const res = await worker.fetch(req, env);
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.equal(body.ok, false);
    assert.match(body.error, /reserved device name 'AUX'/i);
  });

  await test("POST /v1/files/write with sanitize=true or X-Sanitize-Path auto-sanitizes invalid path", async () => {
    const req = new Request("https://api.zerodrive.dev/v1/files/write", {
      method: "POST",
      headers: { ...authHeaders, "X-Sanitize-Path": "true" },
      body: JSON.stringify({
        path: "docs/com1.log",
        content: "log content"
      })
    });
    const res = await worker.fetch(req, env);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.ok, true);
    assert.equal(body.path, "docs/com1_.log");

    // Verify stored in mock bucket
    const stored = await env.VAULT_BUCKET.head("tenants/zd_r2_andrew_8bc7fb477f/usr_andrew_8bc7fb477f/docs/com1_.log");
    assert.ok(stored);
  });

  await test("POST /v1/files/write normalizes Mac NFD to NFC in storage", async () => {
    const nfdPath = "docs/re\u0301sume\u0301.pdf";
    const nfcPath = "docs/r\u00e9sum\u00e9.pdf";

    const req = new Request("https://api.zerodrive.dev/v1/files/write", {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({
        path: nfdPath,
        content: "PDF Header"
      })
    });
    const res = await worker.fetch(req, env);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.path, nfcPath);

    // Verify key in R2 is exact NFC
    const stored = await env.VAULT_BUCKET.head(`tenants/zd_r2_andrew_8bc7fb477f/usr_andrew_8bc7fb477f/${nfcPath}`);
    assert.ok(stored);
  });

  await test("Concurrent edit simulation: Mac & Windows offline simultaneous edits trigger conflict branch", async () => {
    const filePath = "team/architecture-spec.md";

    // 1. Initial version written by server
    const initReq = new Request("https://api.zerodrive.dev/v1/files/write", {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({ path: filePath, content: "# Arch Spec v1\nInitial baseline" })
    });
    const initRes = await worker.fetch(initReq, env);
    const initBody = await initRes.json();
    const baseEtag = initBody.etag;
    assert.ok(baseEtag);

    // 2. Client A (macOS) updates the file while Client B is offline
    const macReq = new Request("https://api.zerodrive.dev/v1/files/write", {
      method: "POST",
      headers: { ...authHeaders, "X-Client-Id": "macbook-pro-m3" },
      body: JSON.stringify({ path: filePath, content: "# Arch Spec v2\nEdited on Mac" })
    });
    const macRes = await worker.fetch(macReq, env);
    const macBody = await macRes.json();
    assert.equal(macBody.ok, true);
    assert.notEqual(macBody.etag, baseEtag);

    // 3. Client B (Windows) now connects and uploads changes based on stale v1 ETag
    const winReq = new Request("https://api.zerodrive.dev/v1/files/write", {
      method: "POST",
      headers: {
        ...authHeaders,
        "If-Match": baseEtag,
        "X-Conflict-Policy": "branch",
        "X-Client-Id": "windows-workstation"
      },
      body: JSON.stringify({ path: filePath, content: "# Arch Spec v2b\nEdited offline on Windows" })
    });
    const winRes = await worker.fetch(winReq, env);
    assert.equal(winRes.status, 201);
    assert.equal(winRes.headers.get("X-Conflicted"), "true");

    const winBody = await winRes.json();
    assert.equal(winBody.ok, true);
    assert.equal(winBody.conflicted, true);
    assert.equal(winBody.original_path, filePath);
    assert.match(winBody.path, /^team\/architecture-spec \(Conflicted copy - windows-workstation - .+\)\.md$/);

    // 4. Verify ZERO data loss: both Mac version and Windows conflicted copy exist in bucket
    const macInStorage = await env.VAULT_BUCKET.get(`tenants/zd_r2_andrew_8bc7fb477f/usr_andrew_8bc7fb477f/${filePath}`);
    assert.equal(await macInStorage.text(), "# Arch Spec v2\nEdited on Mac");

    const winInStorage = await env.VAULT_BUCKET.get(`tenants/zd_r2_andrew_8bc7fb477f/usr_andrew_8bc7fb477f/${winBody.path}`);
    assert.equal(await winInStorage.text(), "# Arch Spec v2b\nEdited offline on Windows");
  });

  await test("Concurrent edit with X-Conflict-Policy: overwrite forcefully updates main file", async () => {
    const filePath = "team/shared-notes.txt";

    // Write initial
    const initRes = await worker.fetch(new Request("https://api.zerodrive.dev/v1/files/write", {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({ path: filePath, content: "Initial text" })
    }), env);
    const v1Etag = (await initRes.json()).etag;

    // Simulate concurrent update on server
    await worker.fetch(new Request("https://api.zerodrive.dev/v1/files/write", {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({ path: filePath, content: "Server update" })
    }), env);

    // Client uploads with stale v1 ETag but explicit X-Conflict-Policy: overwrite
    const overwriteRes = await worker.fetch(new Request("https://api.zerodrive.dev/v1/files/write", {
      method: "POST",
      headers: {
        ...authHeaders,
        "If-Match": v1Etag,
        "X-Conflict-Policy": "overwrite"
      },
      body: JSON.stringify({ path: filePath, content: "Client forced overwrite" })
    }), env);

    assert.equal(overwriteRes.status, 200);
    const body = await overwriteRes.json();
    assert.equal(body.conflicted, false);
    assert.equal(body.path, filePath);

    const check = await env.VAULT_BUCKET.get(`tenants/zd_r2_andrew_8bc7fb477f/usr_andrew_8bc7fb477f/${filePath}`);
    assert.equal(await check.text(), "Client forced overwrite");
  });

  await test("POST /v1/files/rename & move validates and sanitizes cross-platform paths", async () => {
    // Write source file
    await worker.fetch(new Request("https://api.zerodrive.dev/v1/files/write", {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({ path: "rename-test.txt", content: "test" })
    }), env);

    // Reject invalid destination (contains Windows forbidden characters)
    const badRenameRes = await worker.fetch(new Request("https://api.zerodrive.dev/v1/files/rename", {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({ source: "rename-test.txt", destination: "bad:name.txt" })
    }), env);
    assert.equal(badRenameRes.status, 400);

    // Rename with sanitize=true
    const goodRenameRes = await worker.fetch(new Request("https://api.zerodrive.dev/v1/files/rename", {
      method: "POST",
      headers: { ...authHeaders, "X-Sanitize-Path": "true" },
      body: JSON.stringify({ source: "rename-test.txt", destination: "good:name.txt" })
    }), env);
    assert.equal(goodRenameRes.status, 200);
    const body = await goodRenameRes.json();
    assert.equal(body.destination, "good_name.txt");

    // Verify old file deleted, new file exists
    assert.equal(await env.VAULT_BUCKET.head("tenants/zd_r2_andrew_8bc7fb477f/usr_andrew_8bc7fb477f/rename-test.txt"), null);
    assert.ok(await env.VAULT_BUCKET.head("tenants/zd_r2_andrew_8bc7fb477f/usr_andrew_8bc7fb477f/good_name.txt"));
  });

  await test("POST /v1/files/mkdir validates path and creates directory placeholder in vault", async () => {
    // Reject invalid directory with Windows reserved name
    const badMkdirRes = await worker.fetch(new Request("https://api.zerodrive.dev/v1/files/mkdir", {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({ path: "my-vault/CON" })
    }), env);
    assert.equal(badMkdirRes.status, 400);

    // Valid mkdir
    const goodMkdirRes = await worker.fetch(new Request("https://api.zerodrive.dev/v1/files/mkdir", {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({ path: "projects/alpha" })
    }), env);
    assert.equal(goodMkdirRes.status, 201);
    const body = await goodMkdirRes.json();
    assert.equal(body.ok, true);
    assert.equal(body.is_directory, true);
    assert.equal(body.path, "projects/alpha");

    // Verify .keep marker in storage
    const marker = await env.VAULT_BUCKET.head("tenants/zd_r2_andrew_8bc7fb477f/usr_andrew_8bc7fb477f/projects/alpha/.keep");
    assert.ok(marker);
  });

  console.log("\n========================================================");
  console.log(` Test Results: ${passedTests} / ${totalTests} passed (0 failures)`);
  console.log("========================================================\n");

  if (passedTests !== totalTests) {
    process.exit(1);
  }
}

runTestSuite();
