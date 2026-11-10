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

await test("All configured tiers exist with correct prices, quotas, and feature flags", () => {
  const tiers = getPricingTiers({});

  // 1. Free Starter ($0)
  assert.equal(tiers.free.id, "free");
  assert.equal(tiers.free.price_monthly, 0);
  assert.equal(tiers.free.price_yearly, 0);
  assert.equal(tiers.free.storage_gb, 10);
  assert.equal(tiers.free.max_drives, 1);
  assert.equal(tiers.free.flags.byok, true);
  assert.equal(tiers.free.flags.dfy_r2, false);

  // 2. Builder ($19/mo, $97/yr)
  assert.equal(tiers.builder.id, "builder");
  assert.equal(tiers.builder.price_monthly, 19.00);
  assert.equal(tiers.builder.price_yearly, 97.00);
  assert.equal(tiers.builder.storage_gb, 256);
  assert.equal(tiers.builder.max_drives, 1);
  assert.equal(tiers.builder.flags.dfy_r2, true);
  assert.equal(tiers.builder.flags.mcp_token, true);

  // 3. Creator ($29/mo, $197/yr)
  assert.equal(tiers.creator.id, "creator");
  assert.equal(tiers.creator.price_monthly, 29.00);
  assert.equal(tiers.creator.price_yearly, 197.00);
  assert.equal(tiers.creator.storage_gb, 512);
  assert.equal(tiers.creator.max_drives, 2);
  assert.equal(tiers.creator.flags.dfy_r2, true);
  assert.equal(tiers.creator.flags.mcp_token, true);

  // 4. Studio ($49/mo, $397/yr)
  assert.equal(tiers.studio.id, "studio");
  assert.equal(tiers.studio.price_monthly, 49.00);
  assert.equal(tiers.studio.price_yearly, 397.00);
  assert.equal(tiers.studio.storage_gb, 1024);
  assert.equal(tiers.studio.max_drives, 4);
  assert.equal(tiers.studio.flags.fleet_rendering, true);
  assert.equal(tiers.studio.flags.agent_skill_registry, true);

  // 5. Studio Max ($99/mo, $897/yr)
  assert.equal(tiers.studio_max.id, "studio_max");
  assert.equal(tiers.studio_max.price_monthly, 99.00);
  assert.equal(tiers.studio_max.price_yearly, 897.00);
  assert.equal(tiers.studio_max.storage_gb, 3072);
  assert.equal(tiers.studio_max.max_drives, 8);

  // 6. Agency Partner ($497/mo, $4,970/yr)
  assert.equal(tiers.agency.id, "agency");
  assert.equal(tiers.agency.price_monthly, 497.00);
  assert.equal(tiers.agency.price_yearly, 4970.00);
  assert.equal(tiers.agency.storage_gb, 10240);
  assert.equal(tiers.agency.seats, 5);
  assert.equal(tiers.agency.flags.custom_subdomain, true);
  assert.equal(tiers.agency.flags.branded_mcp, true);
  assert.equal(tiers.agency.flags.unlimited_drives, true);

  // 7. BYOK Lifetime ($197)
  assert.equal(tiers.byok_lifetime.id, "byok_lifetime");
  assert.equal(tiers.byok_lifetime.price_monthly, 197.00);
  assert.equal(tiers.byok_lifetime.flags.byok, true);
});

await test("Resolves tiers case-insensitively and by aliases (pro -> creator, team -> agency)", () => {
  assert.equal(getTier({}, "PRO").id, "creator");
  assert.equal(getTier({}, "builder").id, "builder");
  assert.equal(getTier({}, "studio").id, "studio");
  assert.equal(getTier({}, "studio_max").id, "studio_max");
  assert.equal(getTier({}, "max").id, "studio_max");
  assert.equal(getTier({}, "agency").id, "agency");
  assert.equal(getTier({}, "team").id, "agency");
  assert.equal(getTier({}, "starter").id, "free");
  assert.equal(getTier({}, "lifetime").id, "byok_lifetime");
  assert.equal(getTier({}, "founder").id, "byok_lifetime");
});

await test("Dynamic tier override via environment variable PRICING_TIERS_OVERRIDE", () => {
  const envOverride = {
    PRICING_TIERS_OVERRIDE: JSON.stringify({
      creator: { price_monthly: 35.00, storage_gb: 750 }
    })
  };
  const tiers = getPricingTiers(envOverride);
  assert.equal(tiers.creator.price_monthly, 35.00);
  assert.equal(tiers.creator.storage_gb, 750);
  assert.equal(tiers.creator.price_yearly, 197.00);
});

await test("Dynamic tier override via granular environment variables", () => {
  const envGranular = {
    TIER_STUDIO_MONTHLY_PRICE: "59.00",
    TIER_STUDIO_STORAGE_GB: "2048"
  };
  const tiers = getPricingTiers(envGranular);
  assert.equal(tiers.studio.price_monthly, 59.00);
  assert.equal(tiers.studio.storage_gb, 2048);
});

await test("Dynamic tier override via admin API helper (setDynamicPricingOverride)", () => {
  clearBillingCache();
  setDynamicPricingOverride("agency", { price_monthly: 597.00, seats: 10 });
  const tiers = getPricingTiers({});
  assert.equal(tiers.agency.price_monthly, 597.00);
  assert.equal(tiers.agency.seats, 10);
  clearBillingCache(); // Reset
});

// -------------------------------------------------------------
// SECTION 2: Stripe Checkout & Portal
// -------------------------------------------------------------
console.log("\n--- Section 2: Stripe Checkout & Customer Portal Sessions ---");

await test("createCheckoutSession provides mock session URL when STRIPE_SECRET_KEY is absent", async () => {
  const session = await createCheckoutSession({}, {
    tierId: "builder",
    billingCycle: "monthly",
    customerEmail: "alice@zerodrive.dev"
  });

  assert.equal(session.mock, true);
  assert.ok(session.id.startsWith("cs_mock_"));
  assert.ok(session.url.includes("https://checkout.stripe.com/mock/builder"));
  assert.equal(session.amount, 19.00);
  assert.equal(session.tierId, "builder");
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

  assert.equal(session.amount, 397.00);
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
      tier_id: "builder",
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
  assert.equal(data.tier, "builder");
  assert.equal(data.quota_gb, 256);
  assert.equal(data.customer_email, "bob@zerodrive.dev");
  assert.ok(data.license_key.startsWith("zd_live_builder_"));
  assert.ok(data.user_prefix.startsWith("tenants/usr_bob_"));

  testLicenseKey = data.license_key;

  // Verify R2 files were provisioned
  const initFile = await mockBucket.get(`${data.user_prefix}/.zd_vault_init`);
  assert.ok(initFile !== null);

  const licenseFile = await mockBucket.get(`_licenses/${testLicenseKey}.json`);
  assert.ok(licenseFile !== null);
  const licenseJson = JSON.parse(await licenseFile.text());
  assert.equal(licenseJson.status, "active");
  assert.equal(licenseJson.quota_gb, 256);
});

await test("customer.subscription.updated upgrades tier and quota dynamically", async () => {
  const updateObj = {
    id: testSubscriptionId,
    customer: testCustomerId,
    status: "active",
    metadata: {
      tier_id: "studio" // Upgrade from Builder to Studio
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
  assert.equal(data.quota_gb, 1024); // Studio has 1TB quota

  // Verify license key now reflects Studio tier and quota
  const verified = await verifyLicenseKey(testEnv, testLicenseKey);
  assert.equal(verified.valid, true);
  assert.equal(verified.tier, "studio");
  assert.equal(verified.quota_gb, 1024);
  assert.equal(verified.max_drives, 4);
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

let builderLicenseKey = null;

await test("Builder license supports 2 machine slots (1 Mac + 1 VPS), rejects 3rd machine", async () => {
  // Provision a new Builder license
  const checkoutPayload = JSON.stringify({
    id: "evt_new_builder",
    type: "checkout.session.completed",
    data: {
      object: {
        customer: "cus_alice_dev",
        subscription: "sub_alice_dev",
        customer_details: { email: "alice.device@zerodrive.dev" },
        metadata: { tier_id: "builder" }
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
  builderLicenseKey = provData.license_key;

  // 1st machine activation (e.g. MacBook Pro M3)
  const act1 = await activateLicenseKey(testEnv, {
    licenseKey: builderLicenseKey,
    machineId: "mac-serial-A1B2C3D4",
    machineName: "Alice's MacBook Pro M3",
    os: "macos"
  });

  assert.equal(act1.valid, true);
  assert.equal(act1.activated, true);
  assert.equal(act1.tier, "builder");
  assert.equal(act1.active_devices, 1);

  // Re-activating the SAME machine succeeds idempotently
  const actSame = await activateLicenseKey(testEnv, {
    licenseKey: builderLicenseKey,
    machineId: "mac-serial-A1B2C3D4"
  });
  assert.equal(actSame.valid, true);
  assert.equal(actSame.already_active, true);
  assert.equal(actSame.active_devices, 1);

  // 2nd machine activation (e.g. 1 VPS / Cloud Agent) succeeds
  const act2 = await activateLicenseKey(testEnv, {
    licenseKey: builderLicenseKey,
    machineId: "vps-hetzner-agent-node",
    machineName: "Alice's 24/7 VPS Agent",
    os: "linux"
  });
  assert.equal(act2.valid, true);
  assert.equal(act2.activated, true);
  assert.equal(act2.active_devices, 2);

  // 3rd machine activation is REJECTED on Builder tier (limit 2 slots)
  const act3 = await activateLicenseKey(testEnv, {
    licenseKey: builderLicenseKey,
    machineId: "win-serial-998877",
    machineName: "Alice's Desktop PC",
    os: "windows"
  });
  assert.equal(act3.valid, true); // key is valid
  assert.equal(act3.activated, false); // but device limit reached
  assert.ok(act3.error.includes("limit reached"));
});

await test("Creator license allows up to 4 machine slots", async () => {
  // Upgrade the license to Creator tier
  const updatePayload = JSON.stringify({
    id: "evt_upgrade_alice",
    type: "customer.subscription.updated",
    data: {
      object: {
        id: "sub_alice_dev",
        customer: "cus_alice_dev",
        status: "active",
        metadata: { tier_id: "creator" }
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

  // Now 3rd device activation succeeds!
  const act3 = await activateLicenseKey(testEnv, {
    licenseKey: builderLicenseKey,
    machineId: "win-serial-998877",
    machineName: "Alice's Desktop PC",
    os: "windows"
  });
  assert.equal(act3.activated, true);
  assert.equal(act3.active_devices, 3);

  // 4th device activation succeeds
  const act4 = await activateLicenseKey(testEnv, {
    licenseKey: builderLicenseKey,
    machineId: "mac-mini-m4-render",
    machineName: "Mac Mini M4",
    os: "macos"
  });
  assert.equal(act4.activated, true);
  assert.equal(act4.active_devices, 4);

  // 5th device activation exceeds Creator limit (4)
  const act5 = await activateLicenseKey(testEnv, {
    licenseKey: builderLicenseKey,
    machineId: "tablet-surfacebook",
    machineName: "Surface Book",
    os: "windows"
  });
  assert.equal(act5.activated, false);
  assert.ok(act5.error.includes("limit reached"));
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
  assert.ok(data.tiers.builder !== undefined);
  assert.ok(data.tiers.creator !== undefined);
  assert.ok(data.tiers.studio !== undefined);
  assert.ok(data.tiers.studio_max !== undefined);
  assert.ok(data.tiers.agency !== undefined);
  assert.ok(data.tiers.byok_lifetime !== undefined);
  assert.equal(data.count, 7);
});

await test("POST /v1/billing/checkout returns checkout session", async () => {
  const req = new Request("https://api.zerodrive.dev/v1/billing/checkout", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      tierId: "builder",
      billingCycle: "monthly",
      customerEmail: "charlie@zerodrive.dev"
    })
  });

  const res = await worker.fetch(req, testEnv);
  assert.equal(res.status, 200);

  const data = await res.json();
  assert.equal(data.ok, true);
  assert.ok(data.session.url.includes("checkout.stripe.com"));
  assert.equal(data.session.tierId, "builder");
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
        metadata: { tier_id: "agency" }
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
  assert.equal(data.tier, "agency");
  assert.equal(data.quota_gb, 10240);
  assert.ok(data.license_key.startsWith("zd_live_agency_"));
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
  assert.equal(data.tier, "agency");
  assert.equal(data.quota_gb, 10240);
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
  assert.equal(data.tier, "agency");
  assert.equal(data.quota_gb, 10240);
  assert.equal(data.drives_allowed, -1); // Unlimited drives on Agency tier!
});

console.log("\n========================================================");
console.log(` Test Results: ${passedTests} / ${totalTests} passed (${totalTests - passedTests} failures)`);
console.log("========================================================\n");

if (totalTests !== passedTests) {
  process.exit(1);
}
