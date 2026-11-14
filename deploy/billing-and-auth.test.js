import test from "node:test";
import assert from "node:assert/strict";
import worker from "./worker.js";
import {
  clearBillingCache,
  getPricingTiers,
  getTier,
  generateSignedLicenseKey,
  verifySignedLicenseKeyFormat,
  createManagedLicense,
  verifyLicenseKey,
  activateLicenseKey,
  revokeManagedLicense,
  buildTenantIdentityForEmail,
  resolveTenantSecretKey,
  sha256Hex,
  createCheckoutSession
} from "./billing.js";

function createMockBucket() {
  const store = new Map();
  return {
    async put(key, val) {
      store.set(key, typeof val === "string" ? val : JSON.stringify(val));
    },
    async get(key) {
      if (!store.has(key)) return null;
      const text = store.get(key);
      return { text: async () => text };
    },
    async list({ prefix = "" } = {}) {
      const objects = [];
      for (const k of store.keys()) {
        if (k.startsWith(prefix)) objects.push({ key: k });
      }
      return { objects };
    },
    _store: store
  };
}

test("Pro and Agency primary plans + backwards-compatible tiers", () => {
  clearBillingCache();
  const tiers = getPricingTiers();
  assert.equal(tiers.pro.id, "pro");
  assert.equal(tiers.pro.price_monthly, 29);
  assert.equal(tiers.pro.list_price_monthly, 49);
  assert.equal(tiers.pro.storage_gb, 1024);
  assert.equal(tiers.agency.id, "agency");
  assert.equal(tiers.agency.price_monthly, 297);
  assert.equal(tiers.agency.list_price_monthly, 497);
  assert.equal(tiers.agency.storage_gb, 10240);
  assert.ok(tiers.free);
  assert.equal(getTier({}, "pro").id, "pro");
  assert.equal(getTier({}, "agency").id, "agency");
});

test("Signed license key generation, activation, binding, and revocation", async () => {
  clearBillingCache();
  const bucket = createMockBucket();
  const env = { VAULT_BUCKET: bucket, LICENSE_SECRET: "test_secret_123" };

  const key = await generateSignedLicenseKey(env, "pro");
  assert.match(key, /^ZD-PRO-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/);

  const sigCheck = await verifySignedLicenseKeyFormat(env, key);
  assert.equal(sigCheck.matched, true);
  assert.equal(sigCheck.signatureValid, true);
  assert.equal(sigCheck.tierId, "pro");

  // Master 20 TB account can never be downgraded by activating a smaller key
  const blockedDowngrade = await activateLicenseKey(env, {
    licenseKey: key,
    machineId: "MAC-UUID-MASTER",
    machineName: "Master Mac",
    os: "macos",
    email: "naegele412@gmail.com"
  });
  assert.equal(blockedDowngrade.activated, false);
  assert.equal(blockedDowngrade.already_higher_plan, true);

  const record = await createManagedLicense(env, { tierId: "agency", customerEmail: "client@acme.com" });
  assert.match(record.license_key, /^ZD-AGY-/);

  const verifyOk = await verifyLicenseKey(env, record.license_key);
  assert.equal(verifyOk.valid, true);
  assert.equal(verifyOk.tier, "agency");
  assert.equal(verifyOk.quota_tb, 10);

  const act = await activateLicenseKey(env, {
    licenseKey: record.license_key,
    machineId: "MAC-UUID-001",
    machineName: "Studio Mac",
    os: "macos",
    email: "client@acme.com"
  });
  assert.equal(act.activated, true);
  assert.equal(act.active_devices, 1);

  await revokeManagedLicense(env, record.license_key);
  const verifyRevoked = await verifyLicenseKey(env, record.license_key);
  assert.equal(verifyRevoked.valid, false);
  assert.equal(verifyRevoked.status, "revoked");
});

test("Strict client drive segregation prevents master vault leakage", async () => {
  const master = await buildTenantIdentityForEmail({}, "naegele412@gmail.com");
  const clientAndrew = await buildTenantIdentityForEmail({}, "andrew@clientcompany.com");

  assert.equal(master.userPrefix, "usr_andrew_8bc7fb477f");
  assert.notEqual(clientAndrew.userPrefix, master.userPrefix);
  assert.notEqual(clientAndrew.accessKeyId, master.accessKeyId);
  assert.notEqual(clientAndrew.secretAccessKey, master.secretAccessKey);
  assert.ok(clientAndrew.tenantPrefix.startsWith("tenants/zd_r2_usr_andrew_"));
});

test("Checkout session never returns AccessDenied checkout.stripe.com/mock URL when Stripe key unset", async () => {
  const session = await createCheckoutSession({}, { tierId: "agency", customerEmail: "client@acme.com" });
  assert.equal(session.tierId, "agency");
  assert.equal(session.amount, 297);
  assert.equal(session.listAmount, 497);
  assert.ok(!session.url.includes("checkout.stripe.com/mock"));
  assert.ok(session.url.startsWith("https://api.zerodrive.dev/v1/billing/checkout/complete"));
});


function createFullMockBucket() {
  const store = new Map();
  return {
    _store: store,
    async head(key) {
      if (!store.has(key)) return null;
      const item = store.get(key);
      return {
        key,
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
        key,
        size: item.data.length,
        etag: item.etag,
        uploaded: item.uploaded,
        httpMetadata: item.httpMetadata,
        body: item.data,
        text: async () => item.data.toString("utf8"),
        arrayBuffer: async () => item.data.buffer.slice(item.data.byteOffset, item.data.byteOffset + item.data.byteLength),
        json: async () => JSON.parse(item.data.toString("utf8"))
      };
    },
    async put(key, val, opts = {}) {
      const buf = typeof val === "string"
        ? Buffer.from(val, "utf8")
        : Buffer.isBuffer(val)
          ? val
          : val instanceof ArrayBuffer
            ? Buffer.from(val)
            : Buffer.from(JSON.stringify(val), "utf8");
      const record = {
        key,
        data: buf,
        etag: `"${Math.random().toString(36).slice(2)}"`,
        uploaded: new Date(),
        httpMetadata: opts.httpMetadata || {}
      };
      store.set(key, record);
      return { key, size: buf.length, etag: record.etag, uploaded: record.uploaded };
    },
    async delete(key) {
      store.delete(key);
    },
    async list({ prefix = "", delimiter = "", limit = 1000 } = {}) {
      const objects = [];
      const delimitedPrefixes = new Set();
      for (const [k, item] of store.entries()) {
        if (!k.startsWith(prefix)) continue;
        const rest = k.slice(prefix.length);
        if (delimiter && rest.includes(delimiter)) {
          delimitedPrefixes.add(prefix + rest.slice(0, rest.indexOf(delimiter) + delimiter.length));
        } else {
          objects.push({
            key: k,
            size: item.data.length,
            etag: item.etag,
            uploaded: item.uploaded,
            httpMetadata: item.httpMetadata
          });
        }
      }
      return {
        objects: objects.slice(0, limit),
        delimitedPrefixes: Array.from(delimitedPrefixes),
        truncated: false
      };
    }
  };
}

function createWorkerSecurityEnv(overrides = {}) {
  const bucket = createFullMockBucket();
  return {
    VAULT_BUCKET: bucket,
    DRIVE_BUCKET: bucket,
    LICENSE_SECRET: "test_license_secret_for_security_regression",
    GOOGLE_CLIENT_SECRET: "test_google_client_secret_for_regression",
    MASTER_API_KEY: "test_master_api_key_for_regression",
    ...overrides
  };
}

async function signS3HeaderRequest({ method = "GET", urlStr, accessKeyId, secretAccessKey, body = "", amzDate = "20261113T120000Z" }) {
  const url = new URL(urlStr);
  const dateStamp = amzDate.slice(0, 8);
  const region = "us-east-1";
  const service = "s3";
  const enc = new TextEncoder();

  async function shaHex(data) {
    const buf = typeof data === "string" ? enc.encode(data) : data;
    const digest = await crypto.subtle.digest("SHA-256", buf);
    return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
  }

  async function hmacRaw(key, msg) {
    const rawKey = typeof key === "string" ? enc.encode(key) : key;
    const cryptoKey = await crypto.subtle.importKey("raw", rawKey, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    return new Uint8Array(await crypto.subtle.sign("HMAC", cryptoKey, enc.encode(msg)));
  }

  function awsEncode(str) {
    return encodeURIComponent(str).replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
  }

  const payloadHash = await shaHex(body);
  const canonicalQuery = Array.from(url.searchParams.entries())
    .map(([k, v]) => [awsEncode(k), awsEncode(v)])
    .sort((a, b) => (a[0] === b[0] ? (a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0) : a[0] < b[0] ? -1 : 1))
    .map(([k, v]) => `${k}=${v}`)
    .join("&");
  const canonicalHeaders = `host:${url.host}\nx-amz-content-sha256:${payloadHash}\nx-amz-date:${amzDate}\n`;
  const signedHeaders = "host;x-amz-content-sha256;x-amz-date";
  const canonicalRequest = [method.toUpperCase(), url.pathname, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].join("\n");
  const scope = `${dateStamp}/${region}/${service}/aws4_request`;
  const stringToSign = `AWS4-HMAC-SHA256\n${amzDate}\n${scope}\n${await shaHex(canonicalRequest)}`;
  const kDate = await hmacRaw(`AWS4${secretAccessKey}`, dateStamp);
  const kRegion = await hmacRaw(kDate, region);
  const kService = await hmacRaw(kRegion, service);
  const kSigning = await hmacRaw(kService, "aws4_request");
  const sigHex = Array.from(await hmacRaw(kSigning, stringToSign)).map((b) => b.toString(16).padStart(2, "0")).join("");

  return new Request(urlStr, {
    method,
    headers: {
      Host: url.host,
      "x-amz-date": amzDate,
      "x-amz-content-sha256": payloadHash,
      Authorization: `AWS4-HMAC-SHA256 Credential=${accessKeyId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${sigHex}`
    },
    body: method === "GET" || method === "HEAD" ? undefined : body
  });
}

test("S3 Proxy rejects unsigned/forged SigV4 requests with 403 and accepts validly signed requests", async () => {
  const env = createWorkerSecurityEnv();
  const buyer = await buildTenantIdentityForEmail(env, "sigv4-buyer@acme.com");
  const resolved = await resolveTenantSecretKey(env, buyer.accessKeyId);
  assert.equal(resolved, buyer.secretAccessKey);

  const s3Url = "https://api.zerodrive.dev/s3/zerodrive-vault-prod?list-type=2";

  const forgedRes = await worker.fetch(new Request(s3Url, {
    headers: {
      Authorization: "AWS4-HMAC-SHA256 Credential=zd_r2_andrew_8bc7fb477f/20261113/us-east-1/s3/aws4_request, SignedHeaders=host, Signature=0000000000000000"
    }
  }), env);
  assert.equal(forgedRes.status, 403);
  assert.ok((await forgedRes.text()).includes("SignatureDoesNotMatch"));

  const wrongSecretReq = await signS3HeaderRequest({
    urlStr: s3Url,
    accessKeyId: buyer.accessKeyId,
    secretAccessKey: "zd_sec_wrong_secret_key"
  });
  const wrongSecretRes = await worker.fetch(wrongSecretReq, env);
  assert.equal(wrongSecretRes.status, 403);

  const validBuyerReq = await signS3HeaderRequest({
    urlStr: s3Url,
    accessKeyId: buyer.accessKeyId,
    secretAccessKey: buyer.secretAccessKey
  });
  const validBuyerRes = await worker.fetch(validBuyerReq, env);
  assert.equal(validBuyerRes.status, 200);

  const master = await buildTenantIdentityForEmail(env, "naegele412@gmail.com");
  const validMasterReq = await signS3HeaderRequest({
    urlStr: s3Url,
    accessKeyId: master.accessKeyId,
    secretAccessKey: master.secretAccessKey
  });
  const validMasterRes = await worker.fetch(validMasterReq, env);
  assert.equal(validMasterRes.status, 200);

  // Simulate rclone (AWS SDK Go v2) signing Accept-Encoding: identity while Cloudflare edge rewrites it to gzip, br
  const rcloneUrl = "https://api.zerodrive.dev/s3/zerodrive-vault-prod/usr_andrew_8bc7fb477f";
  const rcloneUrlObj = new URL(rcloneUrl);
  const amzDate = "20261114T042504Z";
  const dateStamp = amzDate.slice(0, 8);
  const scope = `${dateStamp}/us-east-1/s3/aws4_request`;
  const emptySha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
  const rcloneSignedHeaders = "accept-encoding;amz-sdk-invocation-id;amz-sdk-request;host;x-amz-content-sha256;x-amz-date";
  const invId = "9d583430-5a07-49f1-8aac-005f94d81c8a";
  const sdkReq = "attempt=1; max=10";
  const canonHdrs = `accept-encoding:identity\namz-sdk-invocation-id:${invId}\namz-sdk-request:${sdkReq}\nhost:${rcloneUrlObj.host}\nx-amz-content-sha256:${emptySha}\nx-amz-date:${amzDate}\n`;
  const canonReq = ["HEAD", rcloneUrlObj.pathname, "", canonHdrs, rcloneSignedHeaders, emptySha].join("\n");
  const enc = new TextEncoder();
  const digestHex = async (d) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(d)))).map((b) => b.toString(16).padStart(2, "0")).join("");
  const hmac = async (k, m) => {
    const ck = await crypto.subtle.importKey("raw", typeof k === "string" ? enc.encode(k) : k, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    return new Uint8Array(await crypto.subtle.sign("HMAC", ck, enc.encode(m)));
  };
  const stringToSign = `AWS4-HMAC-SHA256\n${amzDate}\n${scope}\n${await digestHex(canonReq)}`;
  const kSigning = await hmac(await hmac(await hmac(await hmac(`AWS4${master.secretAccessKey}`, dateStamp), "us-east-1"), "s3"), "aws4_request");
  const rcloneSig = Array.from(await hmac(kSigning, stringToSign)).map((b) => b.toString(16).padStart(2, "0")).join("");

  await env.VAULT_BUCKET.put("tenants/zd_r2_andrew_8bc7fb477f/usr_andrew_8bc7fb477f", "ok");
  const edgeMutatedRes = await worker.fetch(new Request(rcloneUrl, {
    method: "HEAD",
    headers: {
      Host: rcloneUrlObj.host,
      "Accept-Encoding": "gzip, br",
      "Amz-Sdk-Invocation-Id": invId,
      "Amz-Sdk-Request": sdkReq,
      "x-amz-content-sha256": emptySha,
      "x-amz-date": amzDate,
      Authorization: `AWS4-HMAC-SHA256 Credential=${master.accessKeyId}/${scope}, SignedHeaders=${rcloneSignedHeaders}, Signature=${rcloneSig}`
    }
  }), env);
  assert.equal(edgeMutatedRes.status, 200);

  const edgeBadSigRes = await worker.fetch(new Request(rcloneUrl, {
    method: "HEAD",
    headers: {
      Host: rcloneUrlObj.host,
      "Accept-Encoding": "gzip, br",
      "Amz-Sdk-Invocation-Id": invId,
      "Amz-Sdk-Request": sdkReq,
      "x-amz-content-sha256": emptySha,
      "x-amz-date": amzDate,
      Authorization: `AWS4-HMAC-SHA256 Credential=${master.accessKeyId}/${scope}, SignedHeaders=${rcloneSignedHeaders}, Signature=${"0".repeat(64)}`
    }
  }), env);
  assert.equal(edgeBadSigRes.status, 403);
});

test("REST/MCP Bearer auth blocks forged tokens and restricts R2 access key IDs to events/activity", async () => {
  const env = createWorkerSecurityEnv();

  for (const badToken of [
    "zd_oauth_master",
    "zd_oauth_master_forged_hex",
    "zd_oauth_fake_token",
    "zd_oauth_usr_alice_deadbeef",
    "usr_fake_tenant",
    "zd_r2_andrew_8bc7fb477f"
  ]) {
    const res = await worker.fetch(new Request("https://api.zerodrive.dev/v1/files", {
      headers: { Authorization: `Bearer ${badToken}` }
    }), env);
    assert.equal(res.status, 401, `Expected 401 for token ${badToken}, got ${res.status}`);
  }

  // Desktop file provider polling uses AccessKeyId on /v1/activity & /v1/events
  const activityRes = await worker.fetch(new Request("https://api.zerodrive.dev/v1/activity?limit=10", {
    headers: { Authorization: "Bearer zd_r2_andrew_8bc7fb477f" }
  }), env);
  assert.equal(activityRes.status, 200);

  // Valid signed user OAuth token is accepted on /v1/files
  const user = await buildTenantIdentityForEmail(env, "oauth-user@acme.com");
  const userHash = await sha256Hex(`${user.userPrefix}:${env.GOOGLE_CLIENT_SECRET}:v2`);
  const validOAuthToken = `zd_oauth_${user.userPrefix}_${userHash.slice(0, 16)}`;
  const filesRes = await worker.fetch(new Request("https://api.zerodrive.dev/v1/files", {
    headers: { Authorization: `Bearer ${validOAuthToken}` }
  }), env);
  assert.equal(filesRes.status, 200);

  // Valid signed license key is accepted on /v1/files
  const lic = await createManagedLicense(env, { tierId: "pro", customerEmail: "lic-user@acme.com" });
  const licFilesRes = await worker.fetch(new Request("https://api.zerodrive.dev/v1/files", {
    headers: { Authorization: `Bearer ${lic.license_key}` }
  }), env);
  assert.equal(licFilesRes.status, 200);
});

test("License admin endpoints reject R2 AccessKeyId and forged zd_oauth_master", async () => {
  const env = createWorkerSecurityEnv();

  for (const badAdminToken of ["zd_r2_andrew_8bc7fb477f", "zd_oauth_master_fake1234", "zd_oauth_master"]) {
    const res = await worker.fetch(new Request("https://api.zerodrive.dev/v1/license/list", {
      headers: { Authorization: `Bearer ${badAdminToken}` }
    }), env);
    assert.ok([401, 403].includes(res.status), `Expected 401/403 for ${badAdminToken}, got ${res.status}`);
  }

  const okRes = await worker.fetch(new Request("https://api.zerodrive.dev/v1/license/list", {
    headers: { Authorization: `Bearer ${env.MASTER_API_KEY}` }
  }), env);
  assert.equal(okRes.status, 200);
});

test("Account creation and vault provisioning enforce 402 payment gate while permitting Free Starter BYOK", async () => {
  const env = createWorkerSecurityEnv();

  const createRes = await worker.fetch(new Request("https://api.zerodrive.dev/v1/auth/create-account", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: "unpaid-pro@example.com", plan: "pro" })
  }), env);
  assert.equal(createRes.status, 402);
  const createJson = await createRes.json();
  assert.equal(createJson.payment_required, true);
  assert.ok(createJson.checkout_url.includes("/v1/billing/checkout"));

  const provRes = await worker.fetch(new Request("https://api.zerodrive.dev/v1/vault/provision", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: "unpaid-vault@example.com" })
  }), env);
  assert.equal(provRes.status, 402);
  const provJson = await provRes.json();
  assert.equal(provJson.payment_required, true);

  const freeCreateRes = await worker.fetch(new Request("https://api.zerodrive.dev/v1/auth/create-account", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: "free-starter@example.com", plan: "free" })
  }), env);
  assert.equal(freeCreateRes.status, 200);
  const freeCreateJson = await freeCreateRes.json();
  assert.equal(freeCreateJson.tier, "Free Starter (BYOK)");
  assert.equal(freeCreateJson.quotaTB, 0.01);
  assert.ok(freeCreateJson.licenseKey.startsWith("zd_free_"));

  const freeProvRes = await worker.fetch(new Request("https://api.zerodrive.dev/v1/vault/provision", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: "free-vault@example.com", tier: "free" })
  }), env);
  assert.equal(freeProvRes.status, 200);
  const freeProvJson = await freeProvRes.json();
  assert.equal(freeProvJson.tier, "Free (BYOK)");
  assert.equal(freeProvJson.quotaTB, 0.01);
});
