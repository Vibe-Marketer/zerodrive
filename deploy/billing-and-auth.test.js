import test from "node:test";
import assert from "node:assert/strict";
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
  assert.equal(tiers.pro.storage_gb, 1024);
  assert.equal(tiers.agency.id, "agency");
  assert.equal(tiers.agency.price_monthly, 497);
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
  assert.match(key, /^ZD-PRO-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{8}$/);

  const sigCheck = await verifySignedLicenseKeyFormat(env, key);
  assert.equal(sigCheck.matched, true);
  assert.equal(sigCheck.signatureValid, true);
  assert.equal(sigCheck.tierId, "pro");

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
  assert.equal(session.amount, 497);
  assert.ok(!session.url.includes("checkout.stripe.com/mock"));
  assert.ok(session.url.startsWith("https://api.zerodrive.dev/v1/billing/checkout/complete"));
});
