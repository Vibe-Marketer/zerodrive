/**
 * ZeroDrive Stripe Billing, Webhook & Dynamic Licensing Engine Test Suite
 *
 * Verifies:
 * 1. Configurable Pricing Registry & Dynamic Overrides (Free, Pro, Studio, Team)
 * 2. Stripe Checkout & Customer Portal session creators (including mock mode)
 * 3. Stripe Webhook HMAC-SHA256 signature verification & Automated Vault Provisioning
 * 4. Active Master License Key generation (zd_live_<tier>_<random32>)
 * 5. Subscription lifecycle management (checkout -> update -> cancellation)
 * 6. Dynamic Machine Licensing & Device Activation (enforcing max_drives per tier)
 * 7. HTTP Worker Endpoints:
 *    - GET  /v1/billing/tiers
 *    - POST /v1/billing/checkout
 *    - POST /v1/billing/webhook
 *    - GET  /v1/billing/portal
 *    - GET  /v1/license/verify
 *    - POST /v1/license/activate
 *
 * Run with: node tests/test-billing-and-license.js
 */

import assert from "node:assert/strict";
import worker, {
  getPricingTiers,
  getTier,
  createCheckoutSession,
  createPortalSession,
  handleStripeWebhook,
  verifyLicenseKey,
  activateLicenseKey,
  handleBillingAndLicenseRequest
} from "../deploy/worker.js";

import {
  computeStripeSignature,
  verifyStripeSignature,
  generateLicenseKey,
  clearBillingCache,
  setDynamicPricingOverride
} from "../deploy/billing.js";

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
        buf = Buffer.from(String(data || ""), "utf8");
      }
      const record = {
        key,
        data: buf,
        etag: `"${Math.random().toString(36).slice(2)}"`,
        uploaded: new Date(),
        httpMetadata: opts.httpMetadata || {}
      };
      store.set(key, record);
      return {
        key,
        size: buf.length,
        etag: record.etag,
        uploaded: record.uploaded
      };
    },
    async delete(key) {
      store.delete(key);
    }
  };
}

let totalTests = 0;
let passedTests = 0;

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

console.log("\n========================================================");
console.log(" ZeroDrive Stripe Billing & Dynamic Licensing Engine");
console.log("========================================================\n");

// -------------------------------------------------------------
// SECTION 1: Configurable Pricing Registry
// -------------------------------------------------------------
console.log("--- Section 1: Configurable Pricing Registry & Overrides ---");

await test("All 4 default tiers exist with correct prices, quotas, and feature flags", () => {
  const tiers = getPricingTiers({});

  // 1. Free Starter
  assert.equal(tiers.free.id, "free");
  assert.equal(tiers.free.price_monthly, 0);
  assert.equal(tiers.free.price_yearly, 0);
  assert.equal(tiers.free.storage_gb, 10);
  assert.equal(tiers.free.flags.byok, true);
  assert.equal(tiers.free.flags.dfy_r2, false);

  // 2. Pro
  assert.equal(tiers.pro.id, "pro");
  assert.equal(tiers.pro.price_monthly, 19.99);
  assert.equal(tiers.pro.price_yearly, 199.00);
  assert.equal(tiers.pro.storage_gb, 500);
  assert.equal(tiers.pro.max_drives, 1);
  assert.equal(tiers.pro.flags.dfy_r2, true);
  assert.equal(tiers.pro.flags.mcp_token, true);

  // 3. Studio / Builder
  assert.equal(tiers.studio.id, "studio");
  assert.equal(tiers.studio.price_monthly, 39.00);
  assert.equal(tiers.studio.price_yearly, 390.00);
  assert.equal(tiers.studio.storage_gb, 2048);
  assert.equal(tiers.studio.max_drives, 3);
  assert.equal(tiers.studio.flags.fleet_rendering, true);
  assert.equal(tiers.studio.flags.agent_skill_registry, true);

  // 4. Team / Agency
  assert.equal(tiers.team.id, "team");
  assert.equal(tiers.team.price_monthly, 79.00);
  assert.equal(tiers.team.price_yearly, 790.00);
  assert.equal(tiers.team.storage_gb, 5120);
  assert.equal(tiers.team.seats, 3);
  assert.equal(tiers.team.flags.custom_subdomain, true);
  assert.equal(tiers.team.flags.branded_mcp, true);
  assert.equal(tiers.team.flags.unlimited_drives, true);
});

await test("Resolves tiers case-insensitively and by aliases (builder -> studio, agency -> team)", () => {
  assert.equal(getTier({}, "PRO").id, "pro");
  assert.equal(getTier({}, "builder").id, "studio");
  assert.equal(getTier({}, "studio_builder").id, "studio");
  assert.equal(getTier({}, "agency").id, "team");
  assert.equal(getTier({}, "team_agency").id, "team");
  assert.equal(getTier({}, "starter").id, "free");
  assert.equal(getTier({}, "unknown_tier").id, "pro"); // default fallback
});

await test("Dynamic tier override via environment variable PRICING_TIERS_OVERRIDE", () => {
  const envOverride = {
    PRICING_TIERS_OVERRIDE: JSON.stringify({
      pro: { price_monthly: 24.99, storage_gb: 750 }
    })
  };
  const tiers = getPricingTiers(envOverride);
  assert.equal(tiers.pro.price_monthly, 24.99);
  assert.equal(tiers.pro.storage_gb, 750);
  // Default values preserved where not overridden
  assert.equal(tiers.pro.price_yearly, 199.00);
});

await test("Dynamic tier override via granular environment variables", () => {
  const envGranular = {
    TIER_STUDIO_MONTHLY_PRICE: "49.00",
    TIER_STUDIO_STORAGE_GB: "3000"
  };
  const tiers = getPricingTiers(envGranular);
  assert.equal(tiers.studio.price_monthly, 49.00);
  assert.equal(tiers.studio.storage_gb, 3000);
});

await test("Dynamic tier override via admin API helper (setDynamicPricingOverride)", () => {
  clearBillingCache();
  setDynamicPricingOverride("team", { price_monthly: 89.00, seats: 5 });
  const tiers = getPricingTiers({});
  assert.equal(tiers.team.price_monthly, 89.00);
  assert.equal(tiers.team.seats, 5);
  clearBillingCache(); // Reset
});

// -------------------------------------------------------------
// SECTION 2: Stripe Checkout & Portal
// -------------------------------------------------------------
console.log("\n--- Section 2: Stripe Checkout & Customer Portal Sessions ---");

await test("createCheckoutSession provides mock session URL when STRIPE_SECRET_KEY is absent", async () => {
  const session = await createCheckoutSession({}, {
    tierId: "pro",
    billingCycle: "monthly",
    customerEmail: "alice@zerodrive.dev"
  });

  assert.equal(session.mock, true);
  assert.ok(session.id.startsWith("cs_mock_"));
  assert.ok(session.url.includes("https://checkout.stripe.com/mock/pro"));
  assert.equal(session.amount, 19.99);
  assert.equal(session.tierId, "pro");
  assert.equal(session.customerEmail, "alice@zerodrive.dev");
});

await test("createCheckoutSession handles free tier without Stripe payment", async () => {
  const session = await createCheckoutSession({}, {
    tierId: "free",
    customerEmail: "freeuser@zerodrive.dev"
  });

  assert.equal(session.free, true);
  assert.equal(session.amount, 0);
  assert.ok(session.url.includes("tier=free"));
});

await test("createCheckoutSession respects yearly billing cycle amount", async () => {
  const session = await createCheckoutSession({}, {
    tierId: "studio",
    billingCycle: "yearly",
    customerEmail: "studio@zerodrive.dev"
  });

  assert.equal(session.amount, 390.00);
  assert.equal(session.billingCycle, "yearly");
});

await test("createPortalSession provides mock portal URL when STRIPE_SECRET_KEY is absent", async () => {
  const portal = await createPortalSession({}, {
    customerId: "cus_alice_12345",
    returnUrl: "https://zerodrive.dev/dashboard"
  });

  assert.equal(portal.mock, true);
  assert.ok(portal.id.startsWith("bps_mock_"));
  assert.ok(portal.url.includes("https://billing.stripe.com/mock/cus_alice_12345"));
  assert.equal(portal.customerId, "cus_alice_12345");
});

// -------------------------------------------------------------
// SECTION 3: Stripe Webhook & Automated Provisioning
// -------------------------------------------------------------
console.log("\n--- Section 3: Webhook Verification & Automated Provisioning ---");

const TEST_WEBHOOK_SECRET = "whsec_test_secret_for_zerodrive_hmac";

await test("Web Crypto HMAC-SHA256 generates and verifies valid Stripe signature", async () => {
  const payload = JSON.stringify({ id: "evt_123", type: "ping" });
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const sig = await computeStripeSignature(TEST_WEBHOOK_SECRET, `${timestamp}.${payload}`);
  const header = `t=${timestamp},v1=${sig}`;

  const valid = await verifyStripeSignature(payload, header, TEST_WEBHOOK_SECRET, 300);
  assert.equal(valid, true);
});

await test("Stripe signature verification rejects tampered payload", async () => {
  const payload = JSON.stringify({ id: "evt_123", type: "ping" });
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const sig = await computeStripeSignature(TEST_WEBHOOK_SECRET, `${timestamp}.${payload}`);
  const header = `t=${timestamp},v1=${sig}`;

  const tamperedPayload = JSON.stringify({ id: "evt_123", type: "ping", tampered: true });
  const valid = await verifyStripeSignature(tamperedPayload, header, TEST_WEBHOOK_SECRET, 300);
  assert.equal(valid, false);
});

await test("Stripe signature verification rejects mismatched secret", async () => {
  const payload = JSON.stringify({ id: "evt_123" });
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const sig = await computeStripeSignature("wrong_secret", `${timestamp}.${payload}`);
  const header = `t=${timestamp},v1=${sig}`;

  const valid = await verifyStripeSignature(payload, header, TEST_WEBHOOK_SECRET, 300);
  assert.equal(valid, false);
});

await test("generateLicenseKey formats key as zd_live_<tier>_<random32>", () => {
  const proKey = generateLicenseKey("pro");
  assert.match(proKey, /^zd_live_pro_[0-9a-f]{32}$/);

  const studioKey = generateLicenseKey("studio");
  assert.match(studioKey, /^zd_live_studio_[0-9a-f]{32}$/);

  const teamKey = generateLicenseKey("team");
  assert.match(teamKey, /^zd_live_team_[0-9a-f]{32}$/);
});

let testLicenseKey = null;
let testCustomerId = "cus_bob_98765";
let testSubscriptionId = "sub_bob_112233";
const mockBucket = createMockR2Bucket();
const testEnv = {
  STRIPE_WEBHOOK_SECRET: TEST_WEBHOOK_SECRET,
  VAULT_BUCKET: mockBucket
};

await test("checkout.session.completed provisions vault prefix, assigns quota, generates active license key", async () => {
  clearBillingCache();

  const sessionObj = {
    customer: testCustomerId,
    subscription: testSubscriptionId,
    customer_details: { email: "bob@zerodrive.dev" },
    metadata: {
      tier_id: "pro",
      billing_cycle: "monthly"
    }
  };

  const webhookBody = JSON.stringify({
    id: "evt_test_checkout",
    type: "checkout.session.completed",
    data: { object: sessionObj }
  });

  const timestamp = Math.floor(Date.now() / 1000).toString();
  const sig = await computeStripeSignature(TEST_WEBHOOK_SECRET, `${timestamp}.${webhookBody}`);

  const req = new Request("https://api.zerodrive.dev/v1/billing/webhook", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "stripe-signature": `t=${timestamp},v1=${sig}`
    },
    body: webhookBody
  });

  const res = await handleStripeWebhook(req, testEnv);
  assert.equal(res.status, 200);

  const data = await res.json();
  assert.equal(data.success, true);
  assert.equal(data.event, "checkout.session.completed");
  assert.equal(data.tier, "pro");
  assert.equal(data.quota_gb, 500);
  assert.equal(data.customer_email, "bob@zerodrive.dev");
  assert.ok(data.license_key.startsWith("zd_live_pro_"));
  assert.ok(data.user_prefix.startsWith("tenants/usr_bob_"));

  testLicenseKey = data.license_key;

  // Verify R2 files were provisioned
  const initFile = await mockBucket.get(`${data.user_prefix}/.zd_vault_init`);
  assert.ok(initFile !== null);

  const licenseFile = await mockBucket.get(`_licenses/${testLicenseKey}.json`);
  assert.ok(licenseFile !== null);
  const licenseJson = JSON.parse(await licenseFile.text());
  assert.equal(licenseJson.status, "active");
  assert.equal(licenseJson.quota_gb, 500);
});

await test("customer.subscription.updated upgrades tier and quota dynamically", async () => {
  const updateObj = {
    id: testSubscriptionId,
    customer: testCustomerId,
    status: "active",
    metadata: {
      tier_id: "studio" // Upgrade from Pro to Studio
    }
  };

  const webhookBody = JSON.stringify({
    id: "evt_test_sub_update",
    type: "customer.subscription.updated",
    data: { object: updateObj }
  });

  const timestamp = Math.floor(Date.now() / 1000).toString();
  const sig = await computeStripeSignature(TEST_WEBHOOK_SECRET, `${timestamp}.${webhookBody}`);

  const req = new Request("https://api.zerodrive.dev/v1/billing/webhook", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "stripe-signature": `t=${timestamp},v1=${sig}`
    },
    body: webhookBody
  });

  const res = await handleStripeWebhook(req, testEnv);
  assert.equal(res.status, 200);

  const data = await res.json();
  assert.equal(data.success, true);
  assert.equal(data.tier, "studio");
  assert.equal(data.quota_gb, 2048); // Studio has 2TB quota

  // Verify license key now reflects Studio tier and quota
  const verified = await verifyLicenseKey(testEnv, testLicenseKey);
  assert.equal(verified.valid, true);
  assert.equal(verified.tier, "studio");
  assert.equal(verified.quota_gb, 2048);
  assert.equal(verified.max_drives, 3);
});

await test("customer.subscription.deleted marks license cancelled", async () => {
  const deleteObj = {
    id: testSubscriptionId,
    customer: testCustomerId
  };

  const webhookBody = JSON.stringify({
    id: "evt_test_sub_deleted",
    type: "customer.subscription.deleted",
    data: { object: deleteObj }
  });

  const timestamp = Math.floor(Date.now() / 1000).toString();
  const sig = await computeStripeSignature(TEST_WEBHOOK_SECRET, `${timestamp}.${webhookBody}`);

  const req = new Request("https://api.zerodrive.dev/v1/billing/webhook", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "stripe-signature": `t=${timestamp},v1=${sig}`
    },
    body: webhookBody
  });

  const res = await handleStripeWebhook(req, testEnv);
  assert.equal(res.status, 200);

  const data = await res.json();
  assert.equal(data.success, true);
  assert.equal(data.status, "cancelled");

  // Verify license verification now fails due to cancelled status
  const verified = await verifyLicenseKey(testEnv, testLicenseKey);
  assert.equal(verified.valid, false);
  assert.equal(verified.status, "cancelled");
});

// -------------------------------------------------------------
// SECTION 4: Machine Licensing & Device Activation
// -------------------------------------------------------------
console.log("\n--- Section 4: Dynamic Machine Licensing & Device Activation ---");

let proLicenseKey = null;

await test("Pro license supports 1 device activation, rejects 2nd device", async () => {
  // Provision a new Pro license
  const checkoutPayload = JSON.stringify({
    id: "evt_new_pro",
    type: "checkout.session.completed",
    data: {
      object: {
        customer: "cus_alice_dev",
        subscription: "sub_alice_dev",
        customer_details: { email: "alice.device@zerodrive.dev" },
        metadata: { tier_id: "pro" }
      }
    }
  });

  const ts = Math.floor(Date.now() / 1000).toString();
  const sig = await computeStripeSignature(TEST_WEBHOOK_SECRET, `${ts}.${checkoutPayload}`);
  const provReq = new Request("https://api.zerodrive.dev/v1/billing/webhook", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "stripe-signature": `t=${ts},v1=${sig}`
    },
    body: checkoutPayload
  });
  const provRes = await handleStripeWebhook(provReq, testEnv);
  const provData = await provRes.json();
  proLicenseKey = provData.license_key;

  // 1st machine activation (e.g. MacBook Pro M3)
  const act1 = await activateLicenseKey(testEnv, {
    licenseKey: proLicenseKey,
    machineId: "mac-serial-A1B2C3D4",
    machineName: "Alice's MacBook Pro M3",
    os: "macos"
  });

  assert.equal(act1.valid, true);
  assert.equal(act1.activated, true);
  assert.equal(act1.tier, "pro");
  assert.equal(act1.drives_allowed, 1);
  assert.equal(act1.active_devices, 1);

  // Re-activating the SAME machine succeeds idempotently
  const actSame = await activateLicenseKey(testEnv, {
    licenseKey: proLicenseKey,
    machineId: "mac-serial-A1B2C3D4"
  });
  assert.equal(actSame.valid, true);
  assert.equal(actSame.already_active, true);
  assert.equal(actSame.active_devices, 1);

  // 2nd machine activation (e.g. Windows PC) is REJECTED on Pro tier (limit 1)
  const act2 = await activateLicenseKey(testEnv, {
    licenseKey: proLicenseKey,
    machineId: "win-serial-998877",
    machineName: "Alice's Desktop PC",
    os: "windows"
  });
  assert.equal(act2.valid, true); // key is valid
  assert.equal(act2.activated, false); // but device limit reached
  assert.ok(act2.error.includes("Drive limit reached"));
});

await test("Studio license allows up to 3 devices", async () => {
  // Upgrade the license to Studio tier
  const updatePayload = JSON.stringify({
    id: "evt_upgrade_alice",
    type: "customer.subscription.updated",
    data: {
      object: {
        id: "sub_alice_dev",
        customer: "cus_alice_dev",
        status: "active",
        metadata: { tier_id: "studio" }
      }
    }
  });
  const ts = Math.floor(Date.now() / 1000).toString();
  const sig = await computeStripeSignature(TEST_WEBHOOK_SECRET, `${ts}.${updatePayload}`);
  const upReq = new Request("https://api.zerodrive.dev/v1/billing/webhook", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "stripe-signature": `t=${ts},v1=${sig}`
    },
    body: updatePayload
  });
  await handleStripeWebhook(upReq, testEnv);

  // Now 2nd device activation succeeds!
  const act2 = await activateLicenseKey(testEnv, {
    licenseKey: proLicenseKey,
    machineId: "win-serial-998877",
    machineName: "Alice's Desktop PC",
    os: "windows"
  });
  assert.equal(act2.activated, true);
  assert.equal(act2.active_devices, 2);

  // 3rd device activation succeeds
  const act3 = await activateLicenseKey(testEnv, {
    licenseKey: proLicenseKey,
    machineId: "linux-server-render-node",
    machineName: "Ubuntu Render Box",
    os: "linux"
  });
  assert.equal(act3.activated, true);
  assert.equal(act3.active_devices, 3);

  // 4th device activation exceeds Studio limit (3)
  const act4 = await activateLicenseKey(testEnv, {
    licenseKey: proLicenseKey,
    machineId: "tablet-surfacebook",
    machineName: "Surface Book",
    os: "windows"
  });
  assert.equal(act4.activated, false);
  assert.ok(act4.error.includes("Drive limit reached"));
});

// -------------------------------------------------------------
// SECTION 5: HTTP Worker Endpoints Integration
// -------------------------------------------------------------
console.log("\n--- Section 5: HTTP Worker Endpoints Integration ---");

await test("GET /v1/billing/tiers returns live pricing and feature flags", async () => {
  const req = new Request("https://api.zerodrive.dev/v1/billing/tiers", { method: "GET" });
  const res = await worker.fetch(req, testEnv);
  assert.equal(res.status, 200);

  const data = await res.json();
  assert.equal(data.ok, true);
  assert.ok(data.tiers.free !== undefined);
  assert.ok(data.tiers.pro !== undefined);
  assert.ok(data.tiers.studio !== undefined);
  assert.ok(data.tiers.team !== undefined);
  assert.equal(data.count, 4);
});

await test("POST /v1/billing/checkout returns checkout session", async () => {
  const req = new Request("https://api.zerodrive.dev/v1/billing/checkout", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      tierId: "pro",
      billingCycle: "monthly",
      customerEmail: "charlie@zerodrive.dev"
    })
  });

  const res = await worker.fetch(req, testEnv);
  assert.equal(res.status, 200);

  const data = await res.json();
  assert.equal(data.ok, true);
  assert.ok(data.session.url.includes("checkout.stripe.com"));
  assert.equal(data.session.tierId, "pro");
});

await test("GET /v1/billing/portal returns portal session URL", async () => {
  const req = new Request("https://api.zerodrive.dev/v1/billing/portal?customerId=cus_charlie_555", {
    method: "GET"
  });

  const res = await worker.fetch(req, testEnv);
  assert.equal(res.status, 200);

  const data = await res.json();
  assert.equal(data.ok, true);
  assert.ok(data.session.url.includes("billing.stripe.com"));
  assert.equal(data.session.customerId, "cus_charlie_555");
});

let liveWorkerLicenseKey = null;

await test("POST /v1/billing/webhook provisions active license via Worker router", async () => {
  const webhookBody = JSON.stringify({
    id: "evt_worker_checkout",
    type: "checkout.session.completed",
    data: {
      object: {
        customer: "cus_dave_444",
        subscription: "sub_dave_444",
        customer_details: { email: "dave@zerodrive.dev" },
        metadata: { tier_id: "team" }
      }
    }
  });

  const ts = Math.floor(Date.now() / 1000).toString();
  const sig = await computeStripeSignature(TEST_WEBHOOK_SECRET, `${ts}.${webhookBody}`);

  const req = new Request("https://api.zerodrive.dev/v1/billing/webhook", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "stripe-signature": `t=${ts},v1=${sig}`
    },
    body: webhookBody
  });

  const res = await worker.fetch(req, testEnv);
  assert.equal(res.status, 200);

  const data = await res.json();
  assert.equal(data.success, true);
  assert.equal(data.tier, "team");
  assert.equal(data.quota_gb, 5120);
  assert.ok(data.license_key.startsWith("zd_live_team_"));
  liveWorkerLicenseKey = data.license_key;
});

await test("GET /v1/license/verify?key=... returns valid tier and quota metadata", async () => {
  const req = new Request(`https://api.zerodrive.dev/v1/license/verify?key=${liveWorkerLicenseKey}`, {
    method: "GET"
  });

  const res = await worker.fetch(req, testEnv);
  assert.equal(res.status, 200);

  const data = await res.json();
  assert.equal(data.ok, true);
  assert.equal(data.valid, true);
  assert.equal(data.tier, "team");
  assert.equal(data.quota_gb, 5120);
  assert.ok(data.user_prefix.startsWith("tenants/usr_dave_"));
});

await test("GET /v1/license/verify rejects non-existent or invalid license keys", async () => {
  const req = new Request("https://api.zerodrive.dev/v1/license/verify?key=zd_live_fake_00000000000000000000000000000000", {
    method: "GET"
  });

  const res = await worker.fetch(req, testEnv);
  assert.equal(res.status, 403);

  const data = await res.json();
  assert.equal(data.ok, false);
  assert.equal(data.status, "not_found");
});

await test("POST /v1/license/activate activates client machine ID via REST endpoint", async () => {
  const req = new Request("https://api.zerodrive.dev/v1/license/activate", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      licenseKey: liveWorkerLicenseKey,
      machineId: "mac-studio-m2-ultra-uuid",
      machineName: "Dave's Mac Studio",
      os: "macos"
    })
  });

  const res = await worker.fetch(req, testEnv);
  assert.equal(res.status, 200);

  const data = await res.json();
  assert.equal(data.ok, true);
  assert.equal(data.activated, true);
  assert.equal(data.machine_id, "mac-studio-m2-ultra-uuid");
  assert.equal(data.tier, "team");
  assert.equal(data.quota_gb, 5120);
  assert.equal(data.drives_allowed, -1); // Unlimited drives on Team tier!
});

console.log("\n========================================================");
console.log(` Test Results: ${passedTests} / ${totalTests} passed (${totalTests - passedTests} failures)`);
console.log("========================================================\n");

if (totalTests !== passedTests) {
  process.exit(1);
}
