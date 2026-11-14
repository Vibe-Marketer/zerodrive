/**
 * ZeroDrive Cross-Platform Auto-Update & Release Endpoint Test Suite
 *
 * Verifies:
 * 1. Semver parsing and ordering edge cases.
 * 2. release-notes.md parsing and cumulative skipped-version release notes (3.0.0 -> 3.1.0).
 * 3. Cloudflare Worker release endpoints (/v1/releases/latest, /v1/updates/check, /v1/releases/changelog, /v1/releases/appcast.xml).
 * 4. Resumable downloads via /download/<filename> (HEAD, GET, HTTP Range 206 Partial Content, 416 invalid range, 400 traversal).
 * 5. ECDSA P-256 + SHA-256 release signature verification and tamper rejection.
 *
 * Run with: node tests/test-auto-updates.js
 */

import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import worker, {
  parseSemver,
  compareSemver,
  parseReleaseNotesMarkdown,
  computeMissedReleases,
  parseByteRange,
  handleReleasesRequest
} from "../deploy/worker.js";
import {
  UPDATE_SIGNING_PUBLIC_KEY_PEM,
  normalizePlatform
} from "../deploy/releases.js";

function createMockR2Bucket() {
  const store = new Map();
  return {
    _store: store,
    putBinary(key, buffer) {
      const buf = Buffer.isBuffer(buffer) ? buffer : Buffer.from(buffer);
      store.set(key, {
        data: buf,
        etag: `"${crypto.createHash("md5").update(buf).digest("hex")}"`
      });
    },
    async head(key) {
      const item = store.get(key);
      if (!item) return null;
      return {
        size: item.data.length,
        etag: item.etag,
        httpEtag: item.etag
      };
    },
    async get(key, options = {}) {
      const item = store.get(key);
      if (!item) return null;
      let slice = item.data;
      if (options && options.range && typeof options.range.offset === "number") {
        const start = options.range.offset;
        const length = typeof options.range.length === "number" ? options.range.length : (item.data.length - start);
        slice = item.data.subarray(start, start + length);
      }
      return {
        size: slice.length,
        etag: item.etag,
        httpEtag: item.etag,
        body: slice,
        text: async () => slice.toString("utf8")
      };
    }
  };
}

let passed = 0;
async function test(name, fn) {
  await fn();
  console.log(`  [PASS] ${name}`);
  passed += 1;
}

console.log("Running ZeroDrive Auto-Update & Release Verification Tests...\n");

await test("1. parseSemver and compareSemver ordering", async () => {
  assert.deepEqual(parseSemver("v3.1.0"), {
    major: 3,
    minor: 1,
    patch: 0,
    prerelease: "",
    normalized: "3.1.0"
  });
  assert.equal(compareSemver("3.0.0", "3.0.5"), -1);
  assert.equal(compareSemver("3.0.5", "3.1.0"), -1);
  assert.equal(compareSemver("3.1.0", "3.0.0"), 1);
  assert.equal(compareSemver("v3.1.0", "3.1.0+42"), 0);
  assert.equal(compareSemver("3.1.0-beta.1", "3.1.0"), -1);
  assert.equal(compareSemver("3.1.0", "3.1.0-beta.1"), 1);
  assert.equal(normalizePlatform("win64"), "windows");
  assert.equal(normalizePlatform("macOS"), "macos");
});

await test("2. parseReleaseNotesMarkdown parses release-notes.md & skipped versions (3.0.0 -> 3.1.0)", async () => {
  const md = fs.readFileSync(path.resolve("release-notes.md"), "utf8");
  const releases = parseReleaseNotesMarkdown(md);
  assert.ok(releases.length >= 3, "Expected at least 3 entries in release-notes.md");
  assert.equal(releases[0].version, "3.1.0");
  assert.equal(releases[1].version, "3.0.5");
  assert.equal(releases[2].version, "3.0.0");
  assert.ok(releases[0].highlights.length >= 4);

  const { missed, combinedNotesMarkdown } = computeMissedReleases(releases, "3.0.0", "3.1.0");
  assert.deepEqual(
    missed.map((r) => r.version),
    ["3.1.0", "3.0.5"],
    "Upgrading from 3.0.0 -> 3.1.0 must include intermediate 3.0.5 release notes"
  );
  assert.match(combinedNotesMarkdown, /### v3\.1\.0/);
  assert.match(combinedNotesMarkdown, /### v3\.0\.5/);
  assert.doesNotMatch(combinedNotesMarkdown, /### v3\.0\.0/);
});

await test("3. /v1/releases/latest, /v1/updates/check, /v1/releases/changelog, and /v1/releases/appcast.xml", async () => {
  const bucket = createMockR2Bucket();
  const md = fs.readFileSync(path.resolve("release-notes.md"), "utf8");
  const parsedReleases = parseReleaseNotesMarkdown(md);

  const fakeMacPayload = Buffer.from("PK\x03\x04zerodrive-macos-test-archive-0123456789abcdef");
  const macSha = crypto.createHash("sha256").update(fakeMacPayload).digest("hex");

  bucket.putBinary("releases/ZeroDrive-macOS-3.1.0.zip", fakeMacPayload);
  bucket.putBinary(
    "releases/manifest.json",
    Buffer.from(
      JSON.stringify({
        schema: 1,
        latest_version: "3.1.0",
        build: "2",
        published_at: "2026-11-13T21:00:00Z",
        public_key: UPDATE_SIGNING_PUBLIC_KEY_PEM,
        platforms: {
          macos: {
            platform: "macos",
            arch: "arm64",
            filename: "ZeroDrive-macOS-3.1.0.zip",
            url: "https://api.zerodrive.dev/download/ZeroDrive-macOS-3.1.0.zip",
            size: fakeMacPayload.length,
            sha256: macSha,
            signature: "test-sig",
            signature_alg: "ecdsa-p256-sha256",
            team_id: "DTB456HJMJ",
            notarized: false,
            minimum_os: "13.0"
          },
          windows: {
            platform: "windows",
            arch: "x64",
            filename: "ZeroDrive-Windows-3.1.0.zip",
            url: "https://api.zerodrive.dev/download/ZeroDrive-Windows-3.1.0.zip",
            size: 1024,
            sha256: "0".repeat(64),
            signature: "test-win-sig",
            signature_alg: "ecdsa-p256-sha256",
            authenticode_signed: false,
            minimum_os: "Windows 10 1809"
          }
        },
        releases: parsedReleases
      })
    )
  );

  const env = { VAULT_BUCKET: bucket };
  const corsHeaders = { "Access-Control-Allow-Origin": "*" };

  // macOS upgrade available 3.0.0 -> 3.1.0
  const macRes = await handleReleasesRequest(
    new Request("https://api.zerodrive.dev/v1/releases/latest?platform=macos&current_version=3.0.0"),
    env,
    new URL("https://api.zerodrive.dev/v1/releases/latest?platform=macos&current_version=3.0.0"),
    corsHeaders
  );
  assert.equal(macRes.status, 200);
  const macJson = await macRes.json();
  assert.equal(macJson.update_available, true);
  assert.equal(macJson.latest_version, "3.1.0");
  assert.equal(macJson.platform_artifact.platform, "macos");
  assert.equal(macJson.missed_releases.length, 2);

  // Windows already current at 3.1.0
  const winRes = await worker.fetch(
    new Request("https://api.zerodrive.dev/v1/updates/check?platform=windows&current_version=3.1.0"),
    env
  );
  assert.equal(winRes.status, 200);
  const winJson = await winRes.json();
  assert.equal(winJson.update_available, false);
  assert.equal(winJson.platform_artifact.platform, "windows");

  // Changelog full & filtered
  const clRes = await worker.fetch(
    new Request("https://api.zerodrive.dev/v1/releases/changelog?since=3.0.0"),
    env
  );
  assert.equal(clRes.status, 200);
  const clJson = await clRes.json();
  assert.equal(clJson.releases.length, 2);
  assert.ok(clJson.all_releases.length >= 3);

  // Sparkle appcast XML
  const xmlRes = await worker.fetch(
    new Request("https://api.zerodrive.dev/v1/releases/appcast.xml"),
    env
  );
  assert.equal(xmlRes.status, 200);
  assert.match(xmlRes.headers.get("Content-Type") || "", /rss\+xml/);
  const xmlText = await xmlRes.text();
  assert.match(xmlText, /<sparkle:shortVersionString>3\.1\.0<\/sparkle:shortVersionString>/);
  assert.match(xmlText, /<enclosure url="https:\/\/api\.zerodrive\.dev\/download\/ZeroDrive-macOS-3\.1\.0\.zip"/);
});

await test("4. /download/<filename> HEAD, GET, HTTP Range 206 resume, 416, and path traversal 400", async () => {
  const bucket = createMockR2Bucket();
  const payload = Buffer.from("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz");
  const sha = crypto.createHash("sha256").update(payload).digest("hex");
  bucket.putBinary("releases/ZeroDrive-macOS-3.1.0.zip", payload);
  bucket.putBinary(
    "releases/manifest.json",
    Buffer.from(
      JSON.stringify({
        latest_version: "3.1.0",
        platforms: {
          macos: {
            filename: "ZeroDrive-macOS-3.1.0.zip",
            sha256: sha,
            size: payload.length
          }
        },
        releases: []
      })
    )
  );
  const env = { VAULT_BUCKET: bucket };

  // HEAD
  const headRes = await worker.fetch(
    new Request("https://api.zerodrive.dev/download/ZeroDrive-macOS-3.1.0.zip", { method: "HEAD" }),
    env
  );
  assert.equal(headRes.status, 200);
  assert.equal(headRes.headers.get("Accept-Ranges"), "bytes");
  assert.equal(headRes.headers.get("Content-Length"), String(payload.length));
  assert.equal(headRes.headers.get("X-Content-Sha256"), sha);

  // Valid Range 206 Partial Content (bytes 10-29)
  const rangeRes = await worker.fetch(
    new Request("https://api.zerodrive.dev/download/ZeroDrive-macOS-3.1.0.zip", {
      headers: { Range: "bytes=10-29" }
    }),
    env
  );
  assert.equal(rangeRes.status, 206);
  assert.equal(rangeRes.headers.get("Content-Range"), `bytes 10-29/${payload.length}`);
  assert.equal(rangeRes.headers.get("Content-Length"), "20");
  const chunk = Buffer.from(await rangeRes.arrayBuffer());
  assert.equal(chunk.toString("utf8"), payload.subarray(10, 30).toString("utf8"));

  // Out-of-bounds Range 416
  const badRangeRes = await worker.fetch(
    new Request("https://api.zerodrive.dev/download/ZeroDrive-macOS-3.1.0.zip", {
      headers: { Range: `bytes=9999-` }
    }),
    env
  );
  assert.equal(badRangeRes.status, 416);

  // Traversal blocked
  const traversalRes = await worker.fetch(
    new Request("https://api.zerodrive.dev/download/..%2Fsecret.txt"),
    env
  );
  assert.equal(traversalRes.status, 400);

  // parseByteRange edge cases
  assert.deepEqual(parseByteRange("bytes=1024-", 2048), {
    invalid: false,
    start: 1024,
    end: 2047,
    offset: 1024,
    length: 1024
  });
});

await test("5. ECDSA P-256 + SHA-256 signature verification & tamper rejection", async () => {
  const privKeyPath = path.join(os.homedir(), ".zerodrive-keys", "update-signing-private.pem");
  assert.ok(fs.existsSync(privKeyPath), `Missing private signing key at ${privKeyPath}`);
  const privateKeyPem = fs.readFileSync(privKeyPath, "utf8");

  const sampleArtifact = Buffer.from("ZeroDrive synthetic installer payload for P-256 check");
  const sha = crypto.createHash("sha256").update(sampleArtifact).digest("hex");
  const canonicalPayload = `zerodrive-release-v1:macos:3.1.0:${sha}:${sampleArtifact.length}`;

  const signature = crypto.sign("sha256", Buffer.from(canonicalPayload, "utf8"), privateKeyPem);
  const sigBase64 = signature.toString("base64");

  const verifiesValid = crypto.verify(
    "sha256",
    Buffer.from(canonicalPayload, "utf8"),
    UPDATE_SIGNING_PUBLIC_KEY_PEM,
    Buffer.from(sigBase64, "base64")
  );
  assert.equal(verifiesValid, true, "Embedded public key must verify private-key signature");

  // Tamper version
  const tamperedVersion = `zerodrive-release-v1:macos:3.2.0:${sha}:${sampleArtifact.length}`;
  assert.equal(
    crypto.verify("sha256", Buffer.from(tamperedVersion, "utf8"), UPDATE_SIGNING_PUBLIC_KEY_PEM, signature),
    false
  );

  // Tamper SHA
  const badSha = sha.replace(/^./, sha[0] === "a" ? "b" : "a");
  const tamperedSha = `zerodrive-release-v1:macos:3.1.0:${badSha}:${sampleArtifact.length}`;
  assert.equal(
    crypto.verify("sha256", Buffer.from(tamperedSha, "utf8"), UPDATE_SIGNING_PUBLIC_KEY_PEM, signature),
    false
  );

  // Tamper size
  const tamperedSize = `zerodrive-release-v1:macos:3.1.0:${sha}:${sampleArtifact.length + 1}`;
  assert.equal(
    crypto.verify("sha256", Buffer.from(tamperedSize, "utf8"), UPDATE_SIGNING_PUBLIC_KEY_PEM, signature),
    false
  );
});

console.log(`\nAll ${passed} auto-update tests PASSED.`);
