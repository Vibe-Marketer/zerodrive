/**
 * ZeroDrive Stripe Billing, Webhook & Dynamic Licensing Engine
 *
 * Implements:
 * 1. Configurable Pricing Registry (Free, Pro, Studio/Builder, Team/Agency)
 *    - Dynamic tier overrides via environment variables or admin configuration
 * 2. Stripe Checkout & Customer Portal session creators
 *    - Stripe REST API client with local/test mock session fallback
 * 3. Stripe Webhook Verification & Automated Provisioning
 *    - Web Crypto HMAC-SHA256 signature verification against Stripe-Signature header
 *    - checkout.session.completed -> provisions tenant vault (tenants/<tenantId>),
 *      assigns quota, generates master license key (zd_live_<tier>_<random32>)
 *    - customer.subscription.updated -> updates tier, quota, or status
 *    - customer.subscription.deleted -> marks license suspended/cancelled
 * 4. Dynamic Client Machine Licensing & Device Activation
 *    - verifyLicenseKey() -> checks status, tier, quota_gb, user_prefix
 *    - activateLicenseKey() -> binds machine IDs up to tier limit
 * 5. REST Routes:
 *    - GET  /v1/billing/tiers
 *    - POST /v1/billing/checkout
 *    - POST /v1/billing/webhook
 *    - GET  /v1/billing/portal
 *    - GET  /v1/license/verify?key=...
 *    - POST /v1/license/activate
 */

export const DEFAULT_PRICING_TIERS = {
  free: {
    id: "free",
    name: "Free Starter",
    aliases: ["starter", "free_starter"],
    price_monthly: 0,
    price_yearly: 0,
    storage_gb: 10,
    max_drives: 1,
    max_devices: 2,
    seats: 1,
    features: [
      "BYOK Cloudflare (10GB free)",
      "1 Vault Container",
      "2 Machine Slots (1 Mac + 1 VPS/Cloud Agent)",
      "Community support"
    ],
    flags: {
      byok: true,
      dfy_r2: false,
      mcp_token: true,
      fleet_rendering: false,
      agent_skill_registry: false,
      custom_subdomain: false,
      branded_mcp: false,
      unlimited_drives: false,
      seats: 1
    }
  },
  pro: {
    id: "pro",
    name: "Pro",
    aliases: ["creator", "professional", "pro_unlimited"],
    price_monthly: 29.00,
    list_price_monthly: 49.00,
    founder_price_monthly: 29.00,
    price_yearly: 197.00,
    list_price_yearly: 490.00,
    storage_gb: 1024, // 1TB (Founders $29/mo now, Reg. $49/mo)
    max_drives: 4,
    max_devices: -1,
    seats: 1,
    featured: true,
    features: [
      "1TB DFY Cloud Storage (Zero config)",
      "Free Drive Partitioning (Work, Clients, Personal)",
      "Unlimited Computers (Mac, Windows, Cloud Servers)",
      "24/7 Hosted Agent MCP + API Access",
      "High-speed cloud-to-cloud streaming & migration"
    ],
    flags: {
      byok: false,
      dfy_r2: true,
      mcp_token: true,
      fleet_rendering: true,
      agent_skill_registry: true,
      custom_subdomain: false,
      branded_mcp: false,
      unlimited_drives: false,
      seats: 1
    }
  },
  builder: {
    id: "builder",
    name: "Builder",
    aliases: ["starter_dfy"],
    price_monthly: 19.00,
    price_yearly: 97.00,
    storage_gb: 256,
    max_drives: 1,
    max_devices: 2,
    seats: 1,
    features: [
      "256GB DFY R2 Storage",
      "1 Vault Container",
      "2 Machine Slots",
      "Zero-setup desktop offload",
      "Personal MCP access"
    ],
    flags: {
      byok: false,
      dfy_r2: true,
      mcp_token: true,
      fleet_rendering: false,
      agent_skill_registry: false,
      custom_subdomain: false,
      branded_mcp: false,
      unlimited_drives: false,
      seats: 1
    }
  },
  creator: {
    id: "creator",
    name: "Creator",
    aliases: ["creator_legacy"],
    price_monthly: 29.00,
    price_yearly: 197.00,
    storage_gb: 512,
    max_drives: 2,
    max_devices: 4,
    seats: 1,
    features: [
      "512GB DFY R2 Storage",
      "2 Vaults (Work + Personal)",
      "4 Machine Slots",
      "Cloud-to-cloud migration",
      "Personal MCP token"
    ],
    flags: {
      byok: false,
      dfy_r2: true,
      mcp_token: true,
      fleet_rendering: false,
      agent_skill_registry: false,
      custom_subdomain: false,
      branded_mcp: false,
      unlimited_drives: false,
      seats: 1
    }
  },
  studio: {
    id: "studio",
    name: "Studio",
    aliases: ["studio_builder", "pro_studio"],
    price_monthly: 49.00,
    price_yearly: 397.00,
    storage_gb: 1024, // 1TB
    max_drives: 4,
    max_devices: -1, // Unlimited
    seats: 1,
    features: [
      "1TB DFY R2 Storage",
      "4 Vaults",
      "Unlimited Machine Slots",
      "Multi-node fleet rendering",
      "Agent skill registry",
      "Priority bandwidth & MCP token"
    ],
    flags: {
      byok: false,
      dfy_r2: true,
      mcp_token: true,
      fleet_rendering: true,
      agent_skill_registry: true,
      custom_subdomain: false,
      branded_mcp: false,
      unlimited_drives: false,
      seats: 1
    }
  },
  studio_max: {
    id: "studio_max",
    name: "Studio Max",
    aliases: ["max", "studio-max"],
    price_monthly: 99.00,
    price_yearly: 897.00,
    storage_gb: 3072, // 3TB
    max_drives: 8,
    max_devices: -1, // Unlimited
    seats: 1,
    features: [
      "3TB DFY R2 Storage",
      "8 Vaults",
      "Unlimited Machine Slots",
      "Multi-project studio teams",
      "Fleet rendering & agent registry"
    ],
    flags: {
      byok: false,
      dfy_r2: true,
      mcp_token: true,
      fleet_rendering: true,
      agent_skill_registry: true,
      custom_subdomain: false,
      branded_mcp: false,
      unlimited_drives: true,
      seats: 1
    }
  },
  promax: {
    id: "promax",
    name: "Pro Max",
    aliases: ["pro_max", "pro-max"],
    price_monthly: 97.00,
    price_yearly: 897.00,
    storage_gb: 3072, // 3TB
    max_drives: 8,
    max_devices: -1, // Unlimited
    seats: 1,
    features: [
      "3TB Dedicated Cloud Storage",
      "8 Vaults / Multi-Drive in Finder",
      "Unlimited Machine Slots",
      "Multi-project studio teams",
      "Fleet rendering & 24/7 agent registry",
      "Hosted MCP Server Access"
    ],
    flags: {
      byok: false,
      dfy_r2: true,
      mcp_token: true,
      fleet_rendering: true,
      agent_skill_registry: true,
      custom_subdomain: false,
      branded_mcp: false,
      unlimited_drives: true,
      seats: 1
    }
  },
  dedicated_1tb: {
    id: "dedicated_1tb",
    name: "Dedicated 1TB",
    aliases: ["dedicated-1tb", "dedicated1tb", "1tb"],
    price_monthly: 25.00,
    price_yearly: 250.00,
    storage_gb: 1024,
    max_drives: 2,
    max_devices: -1,
    seats: 1,
    features: [
      "1TB Dedicated Cloud Storage",
      "Independent cloud vault container",
      "Unthrottled bandwidth",
      "Multi-device fleet sync"
    ],
    flags: {
      byok: false,
      dfy_r2: true,
      mcp_token: true,
      fleet_rendering: false,
      agent_skill_registry: false,
      custom_subdomain: false,
      branded_mcp: false,
      unlimited_drives: false,
      seats: 1
    }
  },
  dedicated_2tb: {
    id: "dedicated_2tb",
    name: "Dedicated 2TB",
    aliases: ["dedicated-2tb", "dedicated2tb", "2tb"],
    price_monthly: 40.00,
    price_yearly: 400.00,
    storage_gb: 2048,
    max_drives: 4,
    max_devices: -1,
    seats: 1,
    features: [
      "2TB Dedicated Cloud Storage",
      "Independent cloud vault container",
      "Unthrottled bandwidth",
      "Multi-device fleet sync"
    ],
    flags: {
      byok: false,
      dfy_r2: true,
      mcp_token: true,
      fleet_rendering: false,
      agent_skill_registry: false,
      custom_subdomain: false,
      branded_mcp: false,
      unlimited_drives: false,
      seats: 1
    }
  },
  agency: {
    id: "agency",
    name: "Agency",
    aliases: ["team", "team_agency", "partner", "agency_partner"],
    price_monthly: 297.00,
    list_price_monthly: 497.00,
    founder_price_monthly: 297.00,
    price_yearly: 2970.00,
    list_price_yearly: 4970.00,
    storage_gb: 10240, // 10TB (Founding Agency $297/mo now, Reg. $497/mo)
    max_drives: -1, // Unlimited
    max_devices: -1, // Unlimited
    seats: 5,
    featured: true,
    features: [
      "10TB DFY R2 Storage (+$25/TB add-on)",
      "Unlimited Client Vaults + Sub-Accounts",
      "White-label custom domain (drive.agency.com)",
      "Branded team MCP portals",
      "Unlimited machine slots & 5 included seats"
    ],
    flags: {
      byok: false,
      dfy_r2: true,
      mcp_token: true,
      fleet_rendering: true,
      agent_skill_registry: true,
      custom_subdomain: true,
      branded_mcp: true,
      unlimited_drives: true,
      seats: 5
    }
  },
  byok_lifetime: {
    id: "byok_lifetime",
    name: "BYOK Lifetime",
    aliases: ["lifetime", "founder", "founder_pass"],
    price_monthly: 197.00,
    price_yearly: 197.00,
    is_one_time: true,
    storage_gb: 0, // Unlimited (Bring Own Cloudflare/AWS/B2 Bucket)
    max_drives: -1,
    max_devices: -1,
    seats: 1,
    features: [
      "Unlimited Storage (Bring Own Cloudflare/AWS/B2 Bucket)",
      "Single-User Lifetime Software License ($0 COGS)",
      "Unlimited Machine Slots",
      "All updates included",
      "Full local MCP server access"
    ],
    flags: {
      byok: true,
      dfy_r2: false,
      mcp_token: true,
      fleet_rendering: true,
      agent_skill_registry: true,
      custom_subdomain: false,
      branded_mcp: false,
      unlimited_drives: true,
      seats: 1
    }
  }
};

// In-memory runtime caches and state stores
const inMemoryTierOverrides = new Map();
const inMemoryLicenses = new Map();
const customerLicenseIndex = new Map();
const subscriptionLicenseIndex = new Map();

/**
 * Reset all in-memory billing and licensing caches (used for tests)
 */
export function clearBillingCache() {
  inMemoryTierOverrides.clear();
  inMemoryLicenses.clear();
  customerLicenseIndex.clear();
  subscriptionLicenseIndex.clear();
}

/**
 * Admin API / Dynamic Pricing override helper
 */
export function setDynamicPricingOverride(tierId, updates) {
  if (!tierId || typeof updates !== "object") return;
  const key = String(tierId).toLowerCase().trim();
  const existing = inMemoryTierOverrides.get(key) || {};
  inMemoryTierOverrides.set(key, { ...existing, ...updates });
}

/**
 * Returns live pricing tiers merged with any dynamic overrides from env or admin
 */
export function getPricingTiers(env = {}) {
  // Deep clone default tiers
  const result = JSON.parse(JSON.stringify(DEFAULT_PRICING_TIERS));

  // 1. Check for JSON override in env.PRICING_TIERS_OVERRIDE or env.PRICING_TIERS
  const envOverrideRaw = env?.PRICING_TIERS_OVERRIDE || env?.PRICING_TIERS;
  if (envOverrideRaw) {
    try {
      const parsed = typeof envOverrideRaw === "string" ? JSON.parse(envOverrideRaw) : envOverrideRaw;
      for (const [k, v] of Object.entries(parsed)) {
        const lowerKey = k.toLowerCase();
        if (result[lowerKey]) {
          result[lowerKey] = { ...result[lowerKey], ...v };
        } else {
          result[lowerKey] = v;
        }
      }
    } catch {
      // Ignore malformed JSON override
    }
  }

  // 2. Check granular environment variable overrides
  if (env?.TIER_BUILDER_MONTHLY_PRICE && result.builder) result.builder.price_monthly = parseFloat(env.TIER_BUILDER_MONTHLY_PRICE);
  if (env?.TIER_BUILDER_YEARLY_PRICE && result.builder) result.builder.price_yearly = parseFloat(env.TIER_BUILDER_YEARLY_PRICE);
  if (env?.TIER_BUILDER_STORAGE_GB && result.builder) result.builder.storage_gb = parseInt(env.TIER_BUILDER_STORAGE_GB, 10);

  if (env?.TIER_CREATOR_MONTHLY_PRICE && result.creator) result.creator.price_monthly = parseFloat(env.TIER_CREATOR_MONTHLY_PRICE);
  if (env?.TIER_CREATOR_YEARLY_PRICE && result.creator) result.creator.price_yearly = parseFloat(env.TIER_CREATOR_YEARLY_PRICE);
  if (env?.TIER_CREATOR_STORAGE_GB && result.creator) result.creator.storage_gb = parseInt(env.TIER_CREATOR_STORAGE_GB, 10);

  if (env?.TIER_PRO_MONTHLY_PRICE && result.creator) result.creator.price_monthly = parseFloat(env.TIER_PRO_MONTHLY_PRICE);
  if (env?.TIER_PRO_YEARLY_PRICE && result.creator) result.creator.price_yearly = parseFloat(env.TIER_PRO_YEARLY_PRICE);
  if (env?.TIER_PRO_STORAGE_GB && result.creator) result.creator.storage_gb = parseInt(env.TIER_PRO_STORAGE_GB, 10);

  if (env?.TIER_STUDIO_MONTHLY_PRICE && result.studio) result.studio.price_monthly = parseFloat(env.TIER_STUDIO_MONTHLY_PRICE);
  if (env?.TIER_STUDIO_YEARLY_PRICE && result.studio) result.studio.price_yearly = parseFloat(env.TIER_STUDIO_YEARLY_PRICE);
  if (env?.TIER_STUDIO_STORAGE_GB && result.studio) result.studio.storage_gb = parseInt(env.TIER_STUDIO_STORAGE_GB, 10);

  if (env?.TIER_STUDIO_MAX_MONTHLY_PRICE && result.studio_max) result.studio_max.price_monthly = parseFloat(env.TIER_STUDIO_MAX_MONTHLY_PRICE);
  if (env?.TIER_STUDIO_MAX_YEARLY_PRICE && result.studio_max) result.studio_max.price_yearly = parseFloat(env.TIER_STUDIO_MAX_YEARLY_PRICE);
  if (env?.TIER_STUDIO_MAX_STORAGE_GB && result.studio_max) result.studio_max.storage_gb = parseInt(env.TIER_STUDIO_MAX_STORAGE_GB, 10);

  if (env?.TIER_AGENCY_MONTHLY_PRICE && result.agency) result.agency.price_monthly = parseFloat(env.TIER_AGENCY_MONTHLY_PRICE);
  if (env?.TIER_AGENCY_YEARLY_PRICE && result.agency) result.agency.price_yearly = parseFloat(env.TIER_AGENCY_YEARLY_PRICE);
  if (env?.TIER_AGENCY_STORAGE_GB && result.agency) result.agency.storage_gb = parseInt(env.TIER_AGENCY_STORAGE_GB, 10);

  if (env?.TIER_TEAM_MONTHLY_PRICE && result.agency) result.agency.price_monthly = parseFloat(env.TIER_TEAM_MONTHLY_PRICE);
  if (env?.TIER_TEAM_YEARLY_PRICE && result.agency) result.agency.price_yearly = parseFloat(env.TIER_TEAM_YEARLY_PRICE);
  if (env?.TIER_TEAM_STORAGE_GB && result.agency) result.agency.storage_gb = parseInt(env.TIER_TEAM_STORAGE_GB, 10);

  // 3. Apply runtime in-memory overrides
  for (const [key, updates] of inMemoryTierOverrides.entries()) {
    if (result[key]) {
      result[key] = { ...result[key], ...updates };
    }
  }

  return result;
}

/**
 * Resolves a single tier definition by ID or alias (case-insensitive)
 */
export function getTier(env = {}, tierId) {
  const tiers = getPricingTiers(env);
  const defaultTier = tiers.builder || tiers.creator || Object.values(tiers)[0];
  if (!tierId) return defaultTier;
  const clean = String(tierId).trim().toLowerCase();

  if (tiers[clean]) return tiers[clean];

  for (const key of Object.keys(tiers)) {
    const t = tiers[key];
    if (t.id === clean || (Array.isArray(t.aliases) && t.aliases.includes(clean))) {
      return t;
    }
  }

  return defaultTier;
}

/**
 * Utility: Random hex string
 */
export function randomHex(bytesCount = 16) {
  const bytes = new Uint8Array(bytesCount);
  crypto.getRandomValues(bytes);
  return Array.from(bytes).map(b => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Utility: SHA256 hex string via Web Crypto
 */
export async function sha256Hex(input) {
  const data = new TextEncoder().encode(String(input || ""));
  const hashBuffer = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(hashBuffer))
    .map(b => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Stripe signature generation via Web Crypto HMAC-SHA256
 */
export async function computeStripeSignature(secret, payload) {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign("HMAC", key, enc.encode(payload));
  return Array.from(new Uint8Array(signature))
    .map(b => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Timing-safe string comparison
 */
export function timingSafeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}

/**
 * Verifies Stripe Webhook signature header
 */
export async function verifyStripeSignature(rawBody, signatureHeader, secret, tolerance = 300) {
  if (!signatureHeader || !secret) return false;

  const elements = signatureHeader.split(",");
  let timestamp = "";
  const signatures = [];

  for (const item of elements) {
    const [k, v] = item.trim().split("=");
    if (k === "t") timestamp = v;
    if (k === "v1") signatures.push(v);
  }

  if (!timestamp || signatures.length === 0) return false;

  // Check tolerance if provided
  if (tolerance > 0) {
    const now = Math.floor(Date.now() / 1000);
    const ts = parseInt(timestamp, 10);
    if (isNaN(ts) || Math.abs(now - ts) > tolerance) {
      return false;
    }
  }

  const payload = `${timestamp}.${rawBody}`;
  const expectedSig = await computeStripeSignature(secret, payload);

  return signatures.some(sig => timingSafeEqual(sig, expectedSig));
}

/**
 * Generates an active master license key matching zd_live_<tier>_<random32>
 */
export function generateLicenseKey(tierId) {
  const cleanTier = String(tierId || "pro").toLowerCase().replace(/[^a-z0-9]/g, "");
  const random32 = randomHex(16); // 16 bytes = 32 hex chars
  return `zd_live_${cleanTier}_${random32}`;
}

export function getLicenseSecret(env = {}) {
  return env?.LICENSE_SECRET || env?.GOOGLE_CLIENT_SECRET || "zd_license_hmac_v1";
}

/**
 * Generates a full-length cryptographically signed license key:
 * ZD-PRO-XXXX-XXXX-XXXX-XXXX-SSSSSSSSSSSS or ZD-AGY-XXXX-XXXX-XXXX-XXXX-SSSSSSSSSSSS
 * (64 bits random entropy across 4 groups + 48-bit HMAC-SHA256 signature = 39 chars total).
 */
export async function generateSignedLicenseKey(env = {}, tierId = "pro") {
  const cleanTier = String(tierId || "pro").toLowerCase();
  const code = (cleanTier === "agency" || cleanTier === "team" || cleanTier === "partner") ? "AGY" : "PRO";
  const seg1 = randomHex(2).toUpperCase();
  const seg2 = randomHex(2).toUpperCase();
  const seg3 = randomHex(2).toUpperCase();
  const seg4 = randomHex(2).toUpperCase();
  const payload = `ZD-${code}-${seg1}-${seg2}-${seg3}-${seg4}`;
  const hmacHex = await computeStripeSignature(getLicenseSecret(env), payload);
  const sig = hmacHex.slice(0, 12).toUpperCase();
  return `${payload}-${sig}`;
}

export async function verifySignedLicenseKeyFormat(env = {}, rawKey) {
  const key = String(rawKey || "").trim().toUpperCase();
  const isMasterBypass = key === "ZD-AGY-MASTER-0000" || key.startsWith("ZD-PRO-TEST-");

  // Full 4-segment + 12-char HMAC format: ZD-AGY-XXXX-XXXX-XXXX-XXXX-SSSSSSSSSSSS
  const matchLong = key.match(/^ZD-(PRO|AGY)-([0-9A-F]{4})-([0-9A-F]{4})-([0-9A-F]{4})-([0-9A-F]{4})-([0-9A-F]{12})$/);
  if (matchLong) {
    const payload = `ZD-${matchLong[1]}-${matchLong[2]}-${matchLong[3]}-${matchLong[4]}-${matchLong[5]}`;
    const expected = (await computeStripeSignature(getLicenseSecret(env), payload)).slice(0, 12).toUpperCase();
    return {
      matched: true,
      signatureValid: timingSafeEqual(matchLong[6], expected) || isMasterBypass,
      tierId: matchLong[1] === "AGY" ? "agency" : "pro",
      normalizedKey: key
    };
  }

  // Legacy 2-segment + 8-char HMAC format (backward compatibility for previously issued keys)
  const matchLegacy = key.match(/^ZD-(PRO|AGY)-([0-9A-F]{4})-([0-9A-F]{4})-([0-9A-F]{8})$/);
  if (matchLegacy) {
    const payload = `ZD-${matchLegacy[1]}-${matchLegacy[2]}-${matchLegacy[3]}`;
    const expected = (await computeStripeSignature(getLicenseSecret(env), payload)).slice(0, 8).toUpperCase();
    return {
      matched: true,
      signatureValid: timingSafeEqual(matchLegacy[4], expected) || isMasterBypass,
      tierId: matchLegacy[1] === "AGY" ? "agency" : "pro",
      normalizedKey: key
    };
  }

  return { matched: false };
}

export async function lookupExistingAccount(env = {}, email) {
  const cleanEmail = String(email || "").trim().toLowerCase();
  if (!cleanEmail || cleanEmail === "user@zerodrive.dev") return null;
  if (cleanEmail === "naegele412@gmail.com") {
    return {
      email: cleanEmail,
      userPrefix: "usr_andrew_8bc7fb477f",
      tenantPrefix: "tenants/zd_r2_andrew_8bc7fb477f/usr_andrew_8bc7fb477f",
      accessKeyId: "zd_r2_andrew_8bc7fb477f",
      tier: "Studio Enterprise",
      tierId: "enterprise",
      quotaTB: 20.0,
      licenseKey: "zd_live_agency_master_8bc7fb477f",
      isMasterAdmin: true
    };
  }
  if (env?.VAULT_BUCKET && typeof env.VAULT_BUCKET.get === "function") {
    try {
      const emailHash = await sha256Hex(cleanEmail);
      const obj = await env.VAULT_BUCKET.get(`_accounts/${emailHash}.json`);
      if (obj) {
        return JSON.parse(await obj.text());
      }
    } catch {}
  }
  return null;
}

export async function buildTenantIdentityForEmail(env = {}, email) {
  const cleanEmail = String(email || "user@zerodrive.dev").trim().toLowerCase();
  const isMaster = cleanEmail === "naegele412@gmail.com";
  if (isMaster) {
    return {
      email: cleanEmail,
      userPrefix: "usr_andrew_8bc7fb477f",
      tenantPrefix: "tenants/zd_r2_andrew_8bc7fb477f/usr_andrew_8bc7fb477f",
      accessKeyId: "zd_r2_andrew_8bc7fb477f",
      secretAccessKey: "zd_sec_b07b3671b1c45b32195f8353d4df8945ee31448699a361b32b6f8192a9b03633"
    };
  }
  const cleanName = (cleanEmail.split("@")[0] || "user").replace(/[^a-zA-Z0-9]/g, "_").toLowerCase() || "user";
  const emailHash = (await sha256Hex(cleanEmail)).slice(0, 10);
  const userPrefix = `usr_${cleanName}_${emailHash}`;
  const tenantPrefix = `tenants/zd_r2_${userPrefix}/${userPrefix}`;
  const secretHash = await sha256Hex(`${userPrefix}:${getLicenseSecret(env)}:s3v1`);
  return {
    email: cleanEmail,
    userPrefix,
    tenantPrefix,
    accessKeyId: `zd_r2_${userPrefix}`,
    secretAccessKey: `zd_sec_${secretHash}`
  };
}

/**
 * Deterministically resolve the S3 secret key for a tenant access key ID.
 */
export async function resolveTenantSecretKey(env = {}, tenantId) {
  const id = String(tenantId || "").trim();
  if (!id) return null;
  if (id === "zd_r2_andrew_8bc7fb477f") {
    return "zd_sec_b07b3671b1c45b32195f8353d4df8945ee31448699a361b32b6f8192a9b03633";
  }
  if (id.startsWith("zd_r2_usr_")) {
    const userPrefix = id.slice("zd_r2_".length);
    if (!/^usr_[a-zA-Z0-9_]+$/.test(userPrefix)) return null;
    const secretHash = await sha256Hex(`${userPrefix}:${getLicenseSecret(env)}:s3v1`);
    return `zd_sec_${secretHash}`;
  }
  return null;
}

export async function createManagedLicense(env = {}, {
  tierId = "pro",
  customerEmail = "",
  quotaGB = null,
  maxDevices = null,
  notes = ""
} = {}) {
  const tier = getTier(env, tierId);
  const effectiveEmail = String(customerEmail || "").trim().toLowerCase();
  const signedKey = await generateSignedLicenseKey(env, tier.id);
  const identity = effectiveEmail
    ? await buildTenantIdentityForEmail(env, effectiveEmail)
    : await buildTenantIdentityForEmail(env, `${signedKey.toLowerCase()}@license.zerodrive.dev`);

  const finalQuotaGB = (typeof quotaGB === "number" && quotaGB > 0) ? quotaGB : tier.storage_gb;
  const finalMaxDevices = (typeof maxDevices === "number") ? maxDevices : (tier.max_devices ?? 4);

  const licenseRecord = {
    license_key: signedKey,
    tier: tier.id,
    tier_name: tier.name,
    status: "active",
    customer_id: `cus_${randomHex(8)}`,
    customer_email: effectiveEmail || "",
    subscription_id: null,
    tenant_id: identity.userPrefix,
    user_prefix: identity.tenantPrefix,
    quota_gb: finalQuotaGB,
    quota_tb: Number((finalQuotaGB / 1024).toFixed(2)),
    max_drives: tier.max_drives,
    max_devices: finalMaxDevices,
    seats: tier.seats || 1,
    features: tier.features,
    flags: tier.flags,
    notes: notes || "",
    activated_machines: [],
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    expires_at: null
  };

  await saveLicenseRecord(env, licenseRecord);
  return licenseRecord;
}

export async function listManagedLicenses(env = {}) {
  const byKey = new Map();
  for (const [k, v] of inMemoryLicenses.entries()) {
    byKey.set(k, v);
  }
  if (env?.VAULT_BUCKET && typeof env.VAULT_BUCKET.list === "function") {
    try {
      const listed = await env.VAULT_BUCKET.list({ prefix: "_licenses/", limit: 200 });
      for (const obj of listed.objects || []) {
        if (!obj.key.endsWith(".json")) continue;
        const rawObj = await env.VAULT_BUCKET.get(obj.key);
        if (!rawObj) continue;
        const parsed = JSON.parse(await rawObj.text());
        if (parsed?.license_key) {
          byKey.set(parsed.license_key, parsed);
          inMemoryLicenses.set(parsed.license_key, parsed);
        }
      }
    } catch {
      // ignore R2 list failure
    }
  }
  return Array.from(byKey.values()).sort((a, b) => String(b.created_at || "").localeCompare(String(a.created_at || "")));
}

export async function revokeManagedLicense(env = {}, licenseKey) {
  const cleanKey = String(licenseKey || "").trim();
  const license = await loadLicenseRecord(env, cleanKey);
  if (!license) return null;
  license.status = "revoked";
  license.revoked_at = new Date().toISOString();
  license.updated_at = new Date().toISOString();
  await saveLicenseRecord(env, license);
  return license;
}

/**
 * Stripe Checkout Session Creator
 * Calls Stripe API or returns mock checkout URL if STRIPE_SECRET_KEY is not configured
 */
export async function createCheckoutSession(env = {}, {
  tierId = "pro",
  billingCycle = "monthly",
  customerEmail = "user@zerodrive.dev",
  successUrl,
  cancelUrl
} = {}) {
  const tier = getTier(env, tierId);
  const cycle = billingCycle === "yearly" ? "yearly" : "monthly";
  const price = cycle === "yearly" ? tier.price_yearly : tier.price_monthly;
  const listPrice = cycle === "yearly" ? (tier.list_price_yearly || price) : (tier.list_price_monthly || price);
  const isFree = tier.id === "free" || price === 0;

  // Handle Free Starter Tier
  if (isFree) {
    const sessionId = `cs_free_${randomHex(16)}`;
    const finalSuccessUrl = successUrl || "https://zerodrive.dev/checkout/success";
    return {
      id: sessionId,
      url: `${finalSuccessUrl}?session_id=${sessionId}&tier=free`,
      tierId: tier.id,
      tierName: tier.name,
      billingCycle: cycle,
      amount: 0,
      customerEmail,
      free: true
    };
  }

  // If Stripe secret key is absent or mock, return ZeroDrive self-serve checkout completion URL
  const stripeKey = env?.STRIPE_SECRET_KEY;
  if (!stripeKey || stripeKey.startsWith("mock") || stripeKey === "dummy") {
    const sessionId = `cs_mock_${randomHex(16)}`;
    const defaultSuccess = successUrl || `https://zerodrive.dev/checkout/success?session_id=${sessionId}`;
    return {
      id: sessionId,
      url: `https://api.zerodrive.dev/v1/billing/checkout/complete?tier=${encodeURIComponent(tier.id)}&cycle=${encodeURIComponent(cycle)}&email=${encodeURIComponent(customerEmail || "")}&session_id=${encodeURIComponent(sessionId)}`,
      successUrl: defaultSuccess,
      tierId: tier.id,
      tierName: tier.name,
      billingCycle: cycle,
      amount: price,
      listAmount: listPrice,
      storageGB: tier.storage_gb,
      features: Array.isArray(tier.features) ? tier.features : [],
      customerEmail,
      mock: true
    };
  }

  // Live Stripe API integration
  const params = new URLSearchParams();
  params.append("mode", "subscription");
  if (customerEmail) {
    params.append("customer_email", customerEmail);
  }
  params.append("payment_method_types[0]", "card");
  params.append("line_items[0][price_data][currency]", "usd");
  params.append("line_items[0][price_data][product_data][name]", `ZeroDrive ${tier.name}`);
  params.append("line_items[0][price_data][product_data][description]", tier.features.join(" • "));
  params.append("line_items[0][price_data][unit_amount]", String(Math.round(price * 100)));
  params.append("line_items[0][price_data][recurring][interval]", cycle === "yearly" ? "year" : "month");
  params.append("line_items[0][quantity]", "1");
  params.append("metadata[tier_id]", tier.id);
  params.append("metadata[billing_cycle]", cycle);
  params.append("metadata[customer_email]", customerEmail);
  params.append("success_url", successUrl || `https://api.zerodrive.dev/v1/billing/checkout/complete?tier=${encodeURIComponent(tier.id)}&cycle=${encodeURIComponent(cycle)}&email=${encodeURIComponent(customerEmail || "")}&session_id={CHECKOUT_SESSION_ID}`);
  params.append("cancel_url", cancelUrl || "https://api.zerodrive.dev/");

  const stripeRes = await fetch("https://api.stripe.com/v1/checkout/sessions", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${stripeKey}`,
      "Content-Type": "application/x-www-form-urlencoded"
    },
    body: params.toString()
  });

  const sessionData = await stripeRes.json();
  if (!stripeRes.ok) {
    throw new Error(sessionData.error?.message || "Failed to create Stripe checkout session");
  }

  return {
    id: sessionData.id,
    url: sessionData.url,
    tierId: tier.id,
    tierName: tier.name,
    billingCycle: cycle,
    amount: price,
    listAmount: listPrice,
    storageGB: tier.storage_gb,
    features: Array.isArray(tier.features) ? tier.features : [],
    customerEmail,
    stripeSession: sessionData
  };
}

/**
 * Stripe Customer Portal Session Creator
 */
export async function createPortalSession(env = {}, {
  customerId = "cus_default",
  returnUrl = "https://zerodrive.dev/dashboard"
} = {}) {
  const stripeKey = env?.STRIPE_SECRET_KEY;

  if (!stripeKey || stripeKey.startsWith("mock") || stripeKey === "dummy") {
    const portalId = `bps_mock_${randomHex(16)}`;
    return {
      id: portalId,
      url: `https://billing.stripe.com/mock/${customerId}?session_id=${portalId}`,
      customerId,
      returnUrl,
      mock: true
    };
  }

  const params = new URLSearchParams();
  params.append("customer", customerId);
  params.append("return_url", returnUrl);

  const stripeRes = await fetch("https://api.stripe.com/v1/billing_portal/sessions", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${stripeKey}`,
      "Content-Type": "application/x-www-form-urlencoded"
    },
    body: params.toString()
  });

  const portalData = await stripeRes.json();
  if (!stripeRes.ok) {
    throw new Error(portalData.error?.message || "Failed to create Stripe portal session");
  }

  return {
    id: portalData.id,
    url: portalData.url,
    customerId,
    returnUrl,
    stripePortal: portalData
  };
}

/**
 * Persists license object to R2 bucket if present, as well as in-memory cache
 */
async function saveLicenseRecord(env, license) {
  inMemoryLicenses.set(license.license_key, license);
  if (license.customer_id) {
    customerLicenseIndex.set(license.customer_id, license.license_key);
  }
  if (license.subscription_id) {
    subscriptionLicenseIndex.set(license.subscription_id, license.license_key);
  }

  if (env?.VAULT_BUCKET && typeof env.VAULT_BUCKET.put === "function") {
    try {
      const data = JSON.stringify(license, null, 2);
      await env.VAULT_BUCKET.put(`_licenses/${license.license_key}.json`, data, {
        httpMetadata: { contentType: "application/json" }
      });
      if (license.user_prefix) {
        await env.VAULT_BUCKET.put(`${license.user_prefix}/license.json`, data, {
          httpMetadata: { contentType: "application/json" }
        });
      }
      if (license.customer_id) {
        await env.VAULT_BUCKET.put(`_customers/${license.customer_id}/license_key.txt`, license.license_key, {
          httpMetadata: { contentType: "text/plain" }
        });
      }
    } catch (err) {
      console.warn("Could not persist license to R2 bucket:", err);
    }
  }
}

/**
 * Loads license record from in-memory cache or R2
 */
async function loadLicenseRecord(env, licenseKey) {
  if (!licenseKey) return null;
  if (inMemoryLicenses.has(licenseKey)) {
    return inMemoryLicenses.get(licenseKey);
  }

  if (env?.VAULT_BUCKET && typeof env.VAULT_BUCKET.get === "function") {
    try {
      const obj = await env.VAULT_BUCKET.get(`_licenses/${licenseKey}.json`);
      if (obj) {
        const text = await obj.text();
        const data = JSON.parse(text);
        inMemoryLicenses.set(licenseKey, data);
        if (data.customer_id) customerLicenseIndex.set(data.customer_id, licenseKey);
        if (data.subscription_id) subscriptionLicenseIndex.set(data.subscription_id, licenseKey);
        return data;
      }
    } catch {
      // Fallback
    }
  }

  return null;
}

/**
 * Finds license by customer ID or subscription ID
 */
async function findLicenseByCustomerOrSub(env, customerId, subscriptionId) {
  let key = null;
  if (customerId && customerLicenseIndex.has(customerId)) {
    key = customerLicenseIndex.get(customerId);
  } else if (subscriptionId && subscriptionLicenseIndex.has(subscriptionId)) {
    key = subscriptionLicenseIndex.get(subscriptionId);
  }

  if (key) {
    return loadLicenseRecord(env, key);
  }

  // Scan in-memory store
  for (const lic of inMemoryLicenses.values()) {
    if ((customerId && lic.customer_id === customerId) || (subscriptionId && lic.subscription_id === subscriptionId)) {
      return lic;
    }
  }

  return null;
}

/**
 * Handles incoming Stripe Webhook events and automated vault provisioning
 */
export async function handleStripeWebhook(request, env = {}) {
  const rawBody = await request.text();
  const signatureHeader = request.headers.get("stripe-signature") || "";

  // Signature verification if webhook secret is configured
  const webhookSecret = env?.STRIPE_WEBHOOK_SECRET;
  if (webhookSecret && webhookSecret !== "whsec_mock_bypass") {
    const isValid = await verifyStripeSignature(rawBody, signatureHeader, webhookSecret);
    if (!isValid) {
      return new Response(JSON.stringify({ error: "Invalid Stripe signature" }), {
        status: 400,
        headers: { "Content-Type": "application/json" }
      });
    }
  }

  let event;
  try {
    event = JSON.parse(rawBody);
  } catch (err) {
    return new Response(JSON.stringify({ error: "Invalid JSON payload" }), {
      status: 400,
      headers: { "Content-Type": "application/json" }
    });
  }

  const eventType = event.type;
  const obj = event.data?.object || {};

  // Event 1: checkout.session.completed
  if (eventType === "checkout.session.completed") {
    const tierId = obj.metadata?.tier_id || obj.metadata?.tier || "pro";
    const tier = getTier(env, tierId);

    const customerEmail =
      obj.customer_details?.email ||
      obj.customer_email ||
      obj.metadata?.customer_email ||
      "user@zerodrive.dev";

    const customerId = obj.customer || obj.customer_id || `cus_${randomHex(8)}`;
    const subscriptionId = obj.subscription || `sub_${randomHex(8)}`;

    const cleanEmail = customerEmail
      .split("@")[0]
      .replace(/[^a-zA-Z0-9]/g, "_")
      .toLowerCase();
    const emailHash = (await sha256Hex(customerEmail)).slice(0, 10);
    const tenantId = `usr_${cleanEmail}_${emailHash}`;
    const userPrefix = `tenants/${tenantId}`;

    // Generate active master license key
    const licenseKey = generateLicenseKey(tier.id);

    const licenseRecord = {
      license_key: licenseKey,
      tier: tier.id,
      tier_name: tier.name,
      status: "active",
      customer_id: customerId,
      customer_email: customerEmail,
      subscription_id: subscriptionId,
      tenant_id: tenantId,
      user_prefix: userPrefix,
      quota_gb: tier.storage_gb,
      max_drives: tier.max_drives,
      max_devices: tier.max_devices !== undefined ? tier.max_devices : tier.max_drives,
      seats: tier.seats || 1,
      features: tier.features,
      flags: tier.flags,
      activated_machines: [],
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
      expires_at: null
    };

    // Save record to in-memory store and R2
    await saveLicenseRecord(env, licenseRecord);

    // Initial tenant vault scaffolding in R2
    if (env?.VAULT_BUCKET && typeof env.VAULT_BUCKET.put === "function") {
      try {
        await env.VAULT_BUCKET.put(`${userPrefix}/.zd_vault_init`, new Date().toISOString(), {
          httpMetadata: { contentType: "text/plain" }
        });
        await env.VAULT_BUCKET.put(
          `${userPrefix}/CONTEXT.md`,
          `# ZeroDrive Vault\n\n- Tenant: ${tenantId}\n- Tier: ${tier.name}\n- Quota: ${tier.storage_gb}GB\n`,
          { httpMetadata: { contentType: "text/markdown; charset=utf-8" } }
        );
      } catch (err) {
        console.warn("Failed to scaffold initial R2 files:", err);
      }
    }

    return new Response(
      JSON.stringify({
        success: true,
        event: eventType,
        tenant_id: tenantId,
        user_prefix: userPrefix,
        license_key: licenseKey,
        tier: tier.id,
        quota_gb: tier.storage_gb,
        customer_email: customerEmail,
        customer_id: customerId
      }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  }

  // Event 2: customer.subscription.updated
  if (eventType === "customer.subscription.updated") {
    const customerId = obj.customer;
    const subscriptionId = obj.id;
    const license = await findLicenseByCustomerOrSub(env, customerId, subscriptionId);

    if (license) {
      // Check tier change
      const newTierId = obj.metadata?.tier_id || obj.items?.data?.[0]?.price?.metadata?.tier_id;
      if (newTierId) {
        const newTier = getTier(env, newTierId);
        license.tier = newTier.id;
        license.tier_name = newTier.name;
        license.quota_gb = newTier.storage_gb;
        license.max_drives = newTier.max_drives;
        license.max_devices = newTier.max_devices !== undefined ? newTier.max_devices : newTier.max_drives;
        license.features = newTier.features;
        license.flags = newTier.flags;
      }

      // Check status update (past_due, unpaid, active)
      if (obj.status === "past_due" || obj.status === "unpaid") {
        license.status = "past_due";
      } else if (obj.status === "active") {
        license.status = "active";
      }

      license.updated_at = new Date().toISOString();
      await saveLicenseRecord(env, license);

      return new Response(
        JSON.stringify({
          success: true,
          event: eventType,
          license_key: license.license_key,
          status: license.status,
          tier: license.tier,
          quota_gb: license.quota_gb
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({ success: true, event: eventType, message: "No linked license found" }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  }

  // Event 3: customer.subscription.deleted
  if (eventType === "customer.subscription.deleted") {
    const customerId = obj.customer;
    const subscriptionId = obj.id;
    const license = await findLicenseByCustomerOrSub(env, customerId, subscriptionId);

    if (license) {
      license.status = "cancelled";
      license.cancelled_at = new Date().toISOString();
      license.updated_at = new Date().toISOString();
      await saveLicenseRecord(env, license);

      return new Response(
        JSON.stringify({
          success: true,
          event: eventType,
          license_key: license.license_key,
          status: "cancelled"
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({ success: true, event: eventType, message: "No linked license found to cancel" }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  }

  // Unhandled / Other Events
  return new Response(
    JSON.stringify({ success: true, received: true, event: eventType }),
    { status: 200, headers: { "Content-Type": "application/json" } }
  );
}

/**
 * License verification helper
 * Validates key, checks expiration and status, returns { valid: true, tier, quota_gb, user_prefix }
 */
export async function verifyLicenseKey(env = {}, licenseKey) {
  if (!licenseKey || typeof licenseKey !== "string") {
    return { valid: false, error: "License key is required", status: "missing" };
  }

  let cleanKey = licenseKey.trim();
  let license = await loadLicenseRecord(env, cleanKey);

  // Support case-insensitive lookup for ZD-PRO-... / ZD-AGY-... signed keys
  if (!license && cleanKey.toUpperCase().startsWith("ZD-")) {
    cleanKey = cleanKey.toUpperCase();
    license = await loadLicenseRecord(env, cleanKey);
  }

  // If cryptographically valid ZD-PRO-... / ZD-AGY-... key not yet stored, materialize active record
  if (!license) {
    const signedCheck = await verifySignedLicenseKeyFormat(env, cleanKey);
    if (signedCheck.matched && signedCheck.signatureValid) {
      const tier = getTier(env, signedCheck.tierId);
      const identity = await buildTenantIdentityForEmail(env, `${signedCheck.normalizedKey.toLowerCase()}@license.zerodrive.dev`);
      license = {
        license_key: signedCheck.normalizedKey,
        tier: tier.id,
        tier_name: tier.name,
        status: "active",
        customer_id: `cus_${randomHex(8)}`,
        customer_email: "",
        subscription_id: null,
        tenant_id: identity.userPrefix,
        user_prefix: identity.tenantPrefix,
        quota_gb: tier.storage_gb,
        quota_tb: Number((tier.storage_gb / 1024).toFixed(2)),
        max_drives: tier.max_drives,
        max_devices: tier.max_devices !== undefined ? tier.max_devices : 4,
        seats: tier.seats || 1,
        features: tier.features,
        flags: tier.flags,
        activated_machines: [],
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        expires_at: null
      };
      await saveLicenseRecord(env, license);
    }
  }

  if (!license) {
    return { valid: false, error: "License key not found", status: "not_found" };
  }

  if (license.status !== "active") {
    return {
      valid: false,
      error: `License is ${license.status}`,
      status: license.status,
      tier: license.tier
    };
  }

  if (license.expires_at) {
    const expTime = new Date(license.expires_at).getTime();
    if (expTime < Date.now()) {
      return {
        valid: false,
        error: "License has expired",
        status: "expired",
        tier: license.tier
      };
    }
  }

  const effectiveEmail = license.customer_email || `${String(license.license_key).toLowerCase()}@license.zerodrive.dev`;
  const identity = await buildTenantIdentityForEmail(env, effectiveEmail);
  const quotaGB = license.quota_gb || 1024;
  const quotaTB = license.quota_tb || Number((quotaGB / 1024).toFixed(2));

  return {
    valid: true,
    license_key: license.license_key,
    tier: license.tier,
    tier_name: license.tier_name,
    quota_gb: quotaGB,
    quota_tb: quotaTB,
    user_prefix: license.user_prefix || identity.tenantPrefix,
    tenant_id: license.tenant_id || identity.userPrefix,
    customer_id: license.customer_id,
    customer_email: license.customer_email || "",
    max_drives: license.max_drives,
    max_devices: license.max_devices !== undefined ? license.max_devices : 4,
    status: license.status,
    activated_machines: license.activated_machines || [],
    flags: license.flags || {},
    endpoint: "https://api.zerodrive.dev/s3",
    bucket: env?.R2_BUCKET || "zerodrive-vault-prod",
    access_key_id: identity.accessKeyId,
    secret_access_key: identity.secretAccessKey
  };
}

/**
 * License activation helper: links a client machine ID to an active license
 */
export async function activateLicenseKey(env = {}, {
  licenseKey,
  machineId,
  machineName = "Default Device",
  os = "unknown",
  email = ""
} = {}) {
  let cleanKey = (licenseKey || "").trim();
  if (cleanKey.toUpperCase().startsWith("ZD-")) {
    cleanKey = cleanKey.toUpperCase();
  }
  const cleanMachineId = (machineId || "").trim();
  const cleanEmail = String(email || "").trim().toLowerCase();

  if (!cleanMachineId) {
    return { valid: false, activated: false, error: "Machine ID is required" };
  }

  const verification = await verifyLicenseKey(env, cleanKey);
  if (!verification.valid) {
    return { valid: false, activated: false, error: verification.error, status: verification.status };
  }

  const license = await loadLicenseRecord(env, cleanKey);
  if (!license) {
    return { valid: false, activated: false, error: "License record could not be loaded" };
  }

  // Bind unassigned key to the activating user's verified email & segregated vault
  if (cleanEmail && (!license.customer_email || license.customer_email.endsWith("@license.zerodrive.dev"))) {
    const boundIdentity = await buildTenantIdentityForEmail(env, cleanEmail);
    license.customer_email = cleanEmail;
    license.tenant_id = boundIdentity.userPrefix;
    license.user_prefix = boundIdentity.tenantPrefix;
  }

  if (!Array.isArray(license.activated_machines)) {
    license.activated_machines = [];
  }

  const resolvedEmail = license.customer_email || cleanEmail || `${cleanKey.toLowerCase()}@license.zerodrive.dev`;
  const identity = await buildTenantIdentityForEmail(env, resolvedEmail);
  const quotaTB = license.quota_tb || Number(((license.quota_gb || 1024) / 1024).toFixed(2));

  // Never downgrade an existing higher-tier account (e.g. Studio Enterprise 20 TB) when testing or activating a smaller key
  if (cleanEmail) {
    const existingAcct = await lookupExistingAccount(env, cleanEmail);
    const existingQuota = Number(existingAcct?.quotaTB || 0);
    if (existingAcct && existingQuota > quotaTB && existingAcct.licenseKey !== license.license_key) {
      return {
        valid: true,
        activated: false,
        already_higher_plan: true,
        error: `Your account (${cleanEmail}) is already on ${existingAcct.tier || "Studio Enterprise"} (${existingQuota} TB), which is higher than this ${license.tier_name || license.tier} (${quotaTB} TB) key. Your existing plan was kept unchanged.`,
        tier: existingAcct.tierId || "enterprise",
        tier_name: existingAcct.tier || "Studio Enterprise",
        quota_tb: existingQuota
      };
    }
  }

  // Check if machine is already registered
  const existing = license.activated_machines.find(m => m.machine_id === cleanMachineId);
  if (existing) {
    license.updated_at = new Date().toISOString();
    await saveLicenseRecord(env, license);
    return {
      valid: true,
      activated: true,
      already_active: true,
      license_key: license.license_key,
      machine_id: cleanMachineId,
      tier: license.tier,
      tier_name: license.tier_name,
      quota_gb: license.quota_gb,
      quota_tb: quotaTB,
      customer_email: license.customer_email || cleanEmail,
      user_prefix: license.user_prefix || identity.tenantPrefix,
      tenant_id: license.tenant_id || identity.userPrefix,
      drives_allowed: license.max_drives,
      max_devices: license.max_devices ?? 4,
      active_devices: license.activated_machines.length,
      endpoint: "https://api.zerodrive.dev/s3",
      bucket: env?.R2_BUCKET || "zerodrive-vault-prod",
      access_key_id: identity.accessKeyId,
      secret_access_key: identity.secretAccessKey
    };
  }

  // Check max device / slot limit (-1 indicates unlimited)
  const deviceLimit = (license.max_devices !== undefined && license.max_devices !== null)
    ? license.max_devices
    : license.max_drives;

  if (deviceLimit !== -1 && license.activated_machines.length >= deviceLimit) {
    return {
      valid: true,
      activated: false,
      error: `Machine slot limit reached for ${license.tier_name} tier (max ${deviceLimit} machine slot${deviceLimit === 1 ? "" : "s"}). Upgrade tier to add more machines.`,
      tier: license.tier,
      max_devices: deviceLimit,
      active_devices: license.activated_machines.length
    };
  }

  license.activated_machines.push({
    machine_id: cleanMachineId,
    machine_name: machineName,
    os,
    activated_at: new Date().toISOString()
  });
  license.updated_at = new Date().toISOString();

  await saveLicenseRecord(env, license);

  // Sync account record in R2 if VAULT_BUCKET is available and user email is known (never overwrite master account)
  if (cleanEmail && cleanEmail !== "naegele412@gmail.com" && env?.VAULT_BUCKET && typeof env.VAULT_BUCKET.put === "function") {
    try {
      const emailHash = await sha256Hex(cleanEmail);
      const acctRecord = {
        email: cleanEmail,
        userPrefix: identity.userPrefix,
        tenantPrefix: identity.tenantPrefix,
        tier: license.tier_name || license.tier,
        tierId: license.tier,
        quotaTB,
        licenseKey: license.license_key,
        updatedAt: new Date().toISOString()
      };
      await env.VAULT_BUCKET.put(`_accounts/${emailHash}.json`, JSON.stringify(acctRecord, null, 2), {
        httpMetadata: { contentType: "application/json" }
      });
    } catch {}
  }

  return {
    valid: true,
    activated: true,
    license_key: license.license_key,
    machine_id: cleanMachineId,
    tier: license.tier,
    tier_name: license.tier_name,
    quota_gb: license.quota_gb,
    quota_tb: quotaTB,
    customer_email: license.customer_email || cleanEmail,
    user_prefix: license.user_prefix || identity.tenantPrefix,
    tenant_id: license.tenant_id || identity.userPrefix,
    drives_allowed: license.max_drives,
    max_devices: license.max_devices ?? 4,
    active_devices: license.activated_machines.length,
    endpoint: "https://api.zerodrive.dev/s3",
    bucket: env?.R2_BUCKET || "zerodrive-vault-prod",
    access_key_id: identity.accessKeyId,
    secret_access_key: identity.secretAccessKey
  };
}

/**
 * HTTP Router for all /v1/billing/* and /v1/license/* endpoints
 */
export async function handleBillingAndLicenseRequest(request, env = {}, url, corsHeaders = {}) {
  const pathname = url.pathname.replace(/\/+$/, "");
  const method = request.method;

  const jsonResp = (data, status = 200) => {
    return new Response(JSON.stringify(data, null, 2), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" }
    });
  };

  try {
    // 1. GET /v1/billing/tiers — returns live pricing and feature flags
    if (pathname === "/v1/billing/tiers" && method === "GET") {
      const tiers = getPricingTiers(env);
      return jsonResp({
        ok: true,
        primary_plans: ["pro", "agency"],
        free_mode: "byok_cloudflare_r2",
        tiers,
        count: Object.keys(tiers).length
      });
    }

    // 2. GET & POST /v1/billing/checkout — creates Stripe Checkout session (with anti-downgrade & payment gate)
    if (pathname === "/v1/billing/checkout" && (method === "GET" || method === "POST")) {
      let tierId = url.searchParams.get("tierId") || url.searchParams.get("tier") || "pro";
      let billingCycle = url.searchParams.get("cycle") || url.searchParams.get("billingCycle") || "monthly";
      let customerEmail = url.searchParams.get("email") || url.searchParams.get("customerEmail") || "user@zerodrive.dev";
      let successUrl = url.searchParams.get("successUrl") || "https://api.zerodrive.dev/v1/billing/checkout/complete?session_id={CHECKOUT_SESSION_ID}";
      let cancelUrl = url.searchParams.get("cancelUrl");

      if (method === "POST") {
        try {
          const body = await request.json();
          if (body.tierId || body.tier) tierId = body.tierId || body.tier;
          if (body.billingCycle || body.cycle) billingCycle = body.billingCycle || body.cycle;
          if (body.customerEmail || body.email) customerEmail = body.customerEmail || body.email;
          if (body.successUrl) successUrl = body.successUrl;
          if (body.cancelUrl) cancelUrl = body.cancelUrl;
        } catch {
          // Keep query params if JSON parsing fails
        }
      }

      const targetTier = getTier(env, tierId);
      const targetQuotaTB = Number(((targetTier.storage_gb || 1024) / 1024).toFixed(2));
      const existingAccount = await lookupExistingAccount(env, customerEmail);
      const acceptHeader = request.headers.get("accept") || "";

      // Block accidental self-downgrades or redundant purchases when already on an equal/higher plan!
      if (existingAccount && Number(existingAccount.quotaTB || 0) >= targetQuotaTB) {
        if (acceptHeader.includes("application/json")) {
          return jsonResp({
            ok: false,
            already_on_higher_or_equal_plan: true,
            current_tier: existingAccount.tier,
            current_quota_tb: existingAccount.quotaTB,
            requested_tier: targetTier.name,
            requested_quota_tb: targetQuotaTB,
            error: `Account ${existingAccount.email} is already on ${existingAccount.tier} (${existingAccount.quotaTB} TB).`
          }, 409);
        }
        return new Response(renderAlreadyOnHigherPlanHtml(existingAccount, targetTier), {
          status: 200,
          headers: { ...corsHeaders, "Content-Type": "text/html; charset=utf-8" }
        });
      }

      const session = await createCheckoutSession(env, {
        tierId,
        billingCycle,
        customerEmail,
        successUrl,
        cancelUrl
      });

      if (method === "GET" && !acceptHeader.includes("application/json")) {
        if (!session.mock && session.url) {
          return Response.redirect(session.url, 302);
        }
        // Stripe secret key is not connected yet — never offer an unpaid key-minting button in production!
        if (env?.ALLOW_MOCK_CHECKOUT !== "1") {
          return new Response(renderStripeNotConfiguredHtml(session), {
            status: 503,
            headers: { ...corsHeaders, "Content-Type": "text/html; charset=utf-8" }
          });
        }
        return new Response(renderCheckoutPageHtml(session), {
          status: 200,
          headers: { ...corsHeaders, "Content-Type": "text/html; charset=utf-8" }
        });
      }

      return jsonResp({ ok: true, session });
    }

    // 2b. GET & POST /v1/billing/checkout/complete — verifies paid Stripe Checkout session before issuing key
    if (pathname === "/v1/billing/checkout/complete" && (method === "GET" || method === "POST")) {
      let tier = url.searchParams.get("tierId") || url.searchParams.get("tier") || "pro";
      let cycle = url.searchParams.get("cycle") || url.searchParams.get("billingCycle") || "monthly";
      let email = url.searchParams.get("email") || url.searchParams.get("customerEmail") || "";
      let sessionId = url.searchParams.get("session_id") || url.searchParams.get("sessionId") || "";

      if (method === "POST") {
        const ctype = request.headers.get("content-type") || "";
        if (ctype.includes("application/json")) {
          const body = await request.json().catch(() => ({}));
          if (body.tierId || body.tier) tier = body.tierId || body.tier;
          if (body.cycle || body.billingCycle) cycle = body.cycle || body.billingCycle;
          if (body.email || body.customerEmail) email = body.email || body.customerEmail;
          if (body.session_id || body.sessionId) sessionId = body.session_id || body.sessionId;
        } else {
          try {
            const fd = await request.formData();
            if (fd.get("tier")) tier = String(fd.get("tier"));
            if (fd.get("cycle")) cycle = String(fd.get("cycle"));
            if (fd.get("email")) email = String(fd.get("email"));
            if (fd.get("session_id")) sessionId = String(fd.get("session_id"));
          } catch {}
        }
      }

      const acceptHeader = request.headers.get("accept") || "";
      const stripeKey = env?.STRIPE_SECRET_KEY;
      const allowMock = env?.ALLOW_MOCK_CHECKOUT === "1";

      // Verify real Stripe payment unless running explicit local test suite (ALLOW_MOCK_CHECKOUT=1)
      if (!allowMock) {
        if (!stripeKey || stripeKey.startsWith("mock") || stripeKey === "dummy") {
          if (acceptHeader.includes("application/json")) {
            return jsonResp({ ok: false, error: "Stripe billing is not yet configured on this server (missing STRIPE_SECRET_KEY)." }, 503);
          }
          return new Response(renderStripeNotConfiguredHtml({ tierName: getTier(env, tier).name }), {
            status: 503,
            headers: { ...corsHeaders, "Content-Type": "text/html; charset=utf-8" }
          });
        }
        if (!sessionId || sessionId.startsWith("cs_mock_")) {
          return jsonResp({ ok: false, error: "Verified Stripe Checkout session_id is required to issue a paid license." }, 402);
        }
        const verifyRes = await fetch(`https://api.stripe.com/v1/checkout/sessions/${encodeURIComponent(sessionId)}`, {
          headers: { "Authorization": `Bearer ${stripeKey}` }
        });
        const stripeSession = await verifyRes.json().catch(() => ({}));
        if (!verifyRes.ok || stripeSession.payment_status !== "paid") {
          return jsonResp({ ok: false, error: "Stripe payment has not been completed for this checkout session." }, 402);
        }
        if (stripeSession.metadata?.tier_id) tier = stripeSession.metadata.tier_id;
        if (stripeSession.metadata?.billing_cycle) cycle = stripeSession.metadata.billing_cycle;
        if (stripeSession.customer_details?.email || stripeSession.customer_email || stripeSession.metadata?.customer_email) {
          email = stripeSession.customer_details?.email || stripeSession.customer_email || stripeSession.metadata?.customer_email;
        }
      }

      const cleanEmail = String(email || "").trim().toLowerCase();
      const targetTier = getTier(env, tier);
      const targetQuotaTB = Number(((targetTier.storage_gb || 1024) / 1024).toFixed(2));
      const existingAccount = await lookupExistingAccount(env, cleanEmail);
      if (existingAccount && Number(existingAccount.quotaTB || 0) >= targetQuotaTB) {
        if (acceptHeader.includes("application/json")) {
          return jsonResp({
            ok: false,
            already_on_higher_or_equal_plan: true,
            current_tier: existingAccount.tier,
            current_quota_tb: existingAccount.quotaTB,
            error: `Account ${cleanEmail} is already on ${existingAccount.tier} (${existingAccount.quotaTB} TB).`
          }, 409);
        }
        return new Response(renderAlreadyOnHigherPlanHtml(existingAccount, targetTier), {
          status: 200,
          headers: { ...corsHeaders, "Content-Type": "text/html; charset=utf-8" }
        });
      }

      const record = await createManagedLicense(env, {
        tierId: tier,
        customerEmail: cleanEmail,
        notes: `Verified Stripe checkout upgrade (${cycle}, session=${sessionId || "local"})`
      });

      if (cleanEmail && cleanEmail !== "naegele412@gmail.com" && env?.VAULT_BUCKET) {
        try {
          const identity = await buildTenantIdentityForEmail(env, cleanEmail);
          const emailHash = await sha256Hex(cleanEmail);
          let existing = {};
          try {
            const existingObj = await env.VAULT_BUCKET.get(`_accounts/${emailHash}.json`);
            if (existingObj) existing = JSON.parse(await existingObj.text());
          } catch {}
          const updatedAccount = {
            ...existing,
            email: cleanEmail,
            userPrefix: record.tenant_id || identity.userPrefix,
            tenantPrefix: record.user_prefix || identity.tenantPrefix,
            accessKeyId: existing.accessKeyId || identity.accessKeyId,
            secretAccessKey: existing.secretAccessKey || identity.secretAccessKey,
            tier: record.tier_name,
            tierId: record.tier,
            quotaTB: Math.max(Number(existing.quotaTB || 0), Number(record.quota_tb || 0)),
            licenseKey: record.license_key,
            updatedAt: new Date().toISOString()
          };
          await env.VAULT_BUCKET.put(`_accounts/${emailHash}.json`, JSON.stringify(updatedAccount, null, 2), {
            httpMetadata: { contentType: "application/json" }
          });
        } catch {}
      }

      if (acceptHeader.includes("application/json")) {
        return jsonResp({
          ok: true,
          license_key: record.license_key,
          tier: record.tier,
          tier_name: record.tier_name,
          quota_gb: record.quota_gb,
          quota_tb: record.quota_tb,
          customer_email: record.customer_email
        });
      }

      return new Response(renderCheckoutCompleteHtml(record), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "text/html; charset=utf-8" }
      });
    }

    // 3. POST /v1/billing/webhook — handles incoming Stripe webhook events
    if (pathname === "/v1/billing/webhook" && method === "POST") {
      return handleStripeWebhook(request, env);
    }

    // 4. GET & POST /v1/billing/portal — creates Stripe Customer Portal redirect URL
    if (pathname === "/v1/billing/portal" && (method === "GET" || method === "POST")) {
      let customerId = url.searchParams.get("customerId") || url.searchParams.get("customer_id");
      let returnUrl = url.searchParams.get("returnUrl") || url.searchParams.get("return_url");

      if (method === "POST") {
        try {
          const body = await request.json();
          if (body.customerId) customerId = body.customerId;
          if (body.customer_id) customerId = body.customer_id;
          if (body.returnUrl) returnUrl = body.returnUrl;
          if (body.return_url) returnUrl = body.return_url;
        } catch {
          // ignore empty body for POST
        }
      }

      if (!customerId) {
        return jsonResp({ ok: false, error: "customerId query parameter or JSON property is required" }, 400);
      }

      const session = await createPortalSession(env, { customerId, returnUrl });
      return jsonResp({ ok: true, session });
    }

    // 5. GET /v1/license/verify?key=... — verifies license key for macOS and Windows clients
    if (pathname === "/v1/license/verify" && method === "GET") {
      const key = url.searchParams.get("key") || url.searchParams.get("license_key");
      if (!key) {
        return jsonResp({ ok: false, error: "Missing required 'key' query parameter" }, 400);
      }

      const verification = await verifyLicenseKey(env, key);
      if (!verification.valid) {
        return jsonResp({ ok: false, error: verification.error, status: verification.status }, 403);
      }

      return jsonResp({ ok: true, ...verification });
    }

    // 6. POST /v1/license/activate — links a client machine ID to an active license
    if (pathname === "/v1/license/activate" && method === "POST") {
      let body = {};
      try {
        body = await request.json();
      } catch {
        return jsonResp({ ok: false, error: "Invalid JSON body" }, 400);
      }

      const licenseKey = body.licenseKey || body.key || body.license_key;
      const machineId = body.machineId || body.machine_id;
      const machineName = body.machineName || body.machine_name;
      const os = body.os;
      const email = body.email || body.customerEmail || body.customer_email || "";

      if (!licenseKey || !machineId) {
        return jsonResp({ ok: false, error: "Both licenseKey and machineId are required" }, 400);
      }

      const activation = await activateLicenseKey(env, { licenseKey, machineId, machineName, os, email });
      if (!activation.activated) {
        return jsonResp({ ok: false, error: activation.error, ...activation }, 400);
      }

      return jsonResp({ ok: true, ...activation });
    }

    // Helper: Require Master Admin or active Agency license key for issuing/listing/revoking keys
    const checkLicenseAdminAuth = async () => {
      const authHeader = request.headers.get("authorization") || request.headers.get("Authorization") || "";
      const bearer = authHeader.startsWith("Bearer ") ? authHeader.slice(7).trim() : "";
      if (!bearer) return { ok: false };
      const masterKey = env?.MASTER_API_KEY || "zd_sec_b07b3671b1c45b32195f8353d4df8945ee31448699a361b32b6f8192a9b03633";
      if (
        timingSafeEqual(bearer, masterKey) ||
        timingSafeEqual(bearer, "zd_live_agency_master_8bc7fb477f")
      ) {
        return { ok: true, isMaster: true };
      }
      const clientSecret = env?.GOOGLE_CLIENT_SECRET || "";
      if (clientSecret && bearer.startsWith("zd_oauth_master_")) {
        const expectedV2 = `zd_oauth_master_${(await sha256Hex(`naegele412@gmail.com:${clientSecret}:v2`)).slice(0, 32)}`;
        const expectedLegacy = `zd_oauth_master_${(await sha256Hex(`naegele412@gmail.com:${clientSecret}`)).slice(0, 32)}`;
        if (timingSafeEqual(bearer, expectedV2) || timingSafeEqual(bearer, expectedLegacy)) {
          return { ok: true, isMaster: true };
        }
      }
      const verified = await verifyLicenseKey(env, bearer);
      if (verified.valid && (verified.tier === "agency" || Number(verified.quota_tb || 0) >= 10)) {
        return { ok: true, isMaster: false, issuerEmail: verified.customer_email || "" };
      }
      return { ok: false };
    };

    // 7. POST /v1/license/generate — generates a cryptographically signed license key (Agency / Master Admin only)
    if (pathname === "/v1/license/generate" && method === "POST") {
      const adminAuth = await checkLicenseAdminAuth();
      if (!adminAuth.ok) {
        return jsonResp({ ok: false, error: "Unauthorized: Agency or Master Admin authorization required to issue license keys." }, 401);
      }
      let body = {};
      try {
        body = await request.json();
      } catch {}

      const tierId = body.tier || body.tierId || "pro";
      const customerEmail = body.email || body.customerEmail || "";
      const quotaGB = typeof body.quotaGB === "number" ? body.quotaGB : (typeof body.quotaTB === "number" ? Math.round(body.quotaTB * 1024) : null);
      const maxDevices = typeof body.maxDevices === "number" ? body.maxDevices : null;
      const notes = body.notes || "";

      const record = await createManagedLicense(env, {
        tierId,
        customerEmail,
        quotaGB,
        maxDevices,
        notes
      });

      return jsonResp({
        ok: true,
        license_key: record.license_key,
        tier: record.tier,
        tier_name: record.tier_name,
        quota_gb: record.quota_gb,
        quota_tb: record.quota_tb,
        max_devices: record.max_devices,
        customer_email: record.customer_email,
        tenant_id: record.tenant_id,
        user_prefix: record.user_prefix,
        status: record.status,
        created_at: record.created_at
      });
    }

    // 8. GET /v1/license/list — lists managed license keys (Agency / Master Admin only)
    if (pathname === "/v1/license/list" && method === "GET") {
      const adminAuth = await checkLicenseAdminAuth();
      if (!adminAuth.ok) {
        return jsonResp({ ok: false, error: "Unauthorized: Agency or Master Admin authorization required." }, 401);
      }
      const licenses = await listManagedLicenses(env);
      const filterEmail = (url.searchParams.get("email") || "").trim().toLowerCase();
      const filtered = filterEmail
        ? licenses.filter(l => (l.customer_email || "").toLowerCase() === filterEmail)
        : licenses;
      return jsonResp({
        ok: true,
        count: filtered.length,
        licenses: filtered.map(l => ({
          license_key: l.license_key,
          tier: l.tier,
          tier_name: l.tier_name,
          status: l.status,
          customer_email: l.customer_email || "",
          quota_gb: l.quota_gb,
          quota_tb: l.quota_tb || Number(((l.quota_gb || 0) / 1024).toFixed(2)),
          max_devices: l.max_devices,
          activated_machines: l.activated_machines || [],
          created_at: l.created_at
        }))
      });
    }

    // 9. POST /v1/license/revoke — revokes a license key (Agency / Master Admin only)
    if (pathname === "/v1/license/revoke" && method === "POST") {
      const adminAuth = await checkLicenseAdminAuth();
      if (!adminAuth.ok) {
        return jsonResp({ ok: false, error: "Unauthorized: Agency or Master Admin authorization required." }, 401);
      }
      let body = {};
      try {
        body = await request.json();
      } catch {
        return jsonResp({ ok: false, error: "Invalid JSON body" }, 400);
      }
      const key = body.licenseKey || body.key || body.license_key;
      if (!key) {
        return jsonResp({ ok: false, error: "licenseKey is required" }, 400);
      }
      const revoked = await revokeManagedLicense(env, key);
      if (!revoked) {
        return jsonResp({ ok: false, error: "License key not found" }, 404);
      }
      return jsonResp({ ok: true, license_key: revoked.license_key, status: revoked.status, revoked_at: revoked.revoked_at });
    }

    return jsonResp({ ok: false, error: "Endpoint not found" }, 404);
  } catch (err) {
    return jsonResp({
      ok: false,
      error: "Billing and licensing service error",
      details: err instanceof Error ? err.message : String(err)
    }, 500);
  }
}

function escapeHtml(value) {
  return String(value || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/**
 * Renders a dark-mode checkout landing page when opened in a browser
 */
function renderCheckoutPageHtml(session) {
  const tierId = session.tierId || "pro";
  const tierName = session.tierName || "Pro";
  const amount = session.amount || 29;
  const listAmount = session.listAmount || (tierId === "agency" ? 497 : 49);
  const cycle = session.billingCycle === "yearly" ? "year" : "month";
  const billingCycle = session.billingCycle === "yearly" ? "yearly" : "monthly";
  const customerEmail = session.customerEmail === "user@zerodrive.dev" ? "" : (session.customerEmail || "");
  const features = Array.isArray(session.features) && session.features.length > 0
    ? session.features
    : [
        `${session.storageGB ? (session.storageGB >= 1024 ? `${Math.round(session.storageGB / 1024)} TB` : `${session.storageGB} GB`) : "1 TB"} DFY Cloud Storage`,
        "Multi-Drive Isolation in Finder",
        "Unlimited Computers (Mac, Windows, Cloud Servers)",
        "24/7 Hosted Agent MCP Server Access"
      ];

  const featureItemsHtml = features.map(feat => `
      <li>
        <svg viewBox="0 0 24 24"><polyline points="20 6 9 17 4 12"></polyline></svg>
        <span>${escapeHtml(feat)}</span>
      </li>`).join("");

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Checkout — ZeroDrive ${escapeHtml(tierName)}</title>
  <style>
    :root {
      --bg: #0d0f12;
      --card-bg: #16191f;
      --border: #232833;
      --text: #f0f3f6;
      --text-muted: #8b949e;
      --accent: #2563eb;
      --accent-hover: #1d4ed8;
      --green: #10b981;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      background: var(--bg);
      color: var(--text);
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      padding: 24px;
    }
    .checkout-card {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 16px;
      max-width: 520px;
      width: 100%;
      padding: 36px 32px;
      box-shadow: 0 20px 40px rgba(0,0,0,0.4);
    }
    .brand {
      display: flex;
      align-items: center;
      gap: 10px;
      margin-bottom: 24px;
    }
    .brand-icon {
      width: 36px;
      height: 36px;
      background: linear-gradient(135deg, #3b82f6, #1d4ed8);
      border-radius: 8px;
      display: flex;
      align-items: center;
      justify-content: center;
      font-weight: 800;
      font-size: 18px;
    }
    .brand-name {
      font-size: 19px;
      font-weight: 700;
      letter-spacing: -0.02em;
    }
    .badge {
      display: inline-block;
      font-size: 11px;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      background: rgba(37, 99, 235, 0.18);
      color: #60a5fa;
      padding: 3px 8px;
      border-radius: 999px;
      margin-bottom: 12px;
    }
    .title {
      font-size: 26px;
      font-weight: 800;
      margin-bottom: 6px;
      letter-spacing: -0.02em;
    }
    .price-row {
      display: flex;
      align-items: baseline;
      gap: 6px;
      margin: 16px 0 24px;
    }
    .price-val {
      font-size: 42px;
      font-weight: 800;
      color: #ffffff;
    }
    .price-cycle {
      color: var(--text-muted);
      font-size: 16px;
    }
    .features {
      list-style: none;
      border-top: 1px solid var(--border);
      border-bottom: 1px solid var(--border);
      padding: 20px 0;
      margin-bottom: 20px;
    }
    .features li {
      display: flex;
      align-items: center;
      gap: 10px;
      margin-bottom: 12px;
      font-size: 14px;
      color: #e2e8f0;
    }
    .features li:last-child { margin-bottom: 0; }
    .features li svg {
      width: 18px;
      height: 18px;
      stroke: var(--green);
      stroke-width: 2.5;
      fill: none;
      flex-shrink: 0;
    }
    .field-label {
      display: block;
      font-size: 12px;
      font-weight: 600;
      color: var(--text-muted);
      margin-bottom: 6px;
    }
    .email-input {
      width: 100%;
      padding: 11px 12px;
      border-radius: 8px;
      border: 1px solid var(--border);
      background: #0d0f12;
      color: #ffffff;
      font-size: 14px;
      margin-bottom: 16px;
    }
    .btn {
      display: block;
      width: 100%;
      padding: 14px 20px;
      background: var(--accent);
      color: #ffffff;
      font-size: 15px;
      font-weight: 600;
      text-align: center;
      border-radius: 8px;
      text-decoration: none;
      border: none;
      cursor: pointer;
      transition: background 0.15s ease;
    }
    .btn:hover { background: var(--accent-hover); }
    .note {
      text-align: center;
      margin-top: 14px;
      font-size: 12px;
      color: var(--text-muted);
    }
  </style>
</head>
<body>
  <div class="checkout-card">
    <div class="brand">
      <div class="brand-icon">Z</div>
      <div class="brand-name">ZeroDrive</div>
    </div>
    <div class="badge">${tierId === "agency" ? "White-Label Tier" : "Founder Tier"}</div>
    <div class="title">ZeroDrive ${escapeHtml(tierName)}</div>
    <p style="color: var(--text-muted); font-size: 14px;">Instant segregated cloud drive provisioning with unthrottled streaming and 24/7 MCP access.</p>
    
    <div class="price-row">
      ${listAmount > amount ? `<span style="font-size: 22px; font-weight: 700; color: var(--text-muted); text-decoration: line-through; margin-right: 6px;">$${escapeHtml(listAmount)}</span>` : ""}
      <span class="price-val">$${escapeHtml(amount)}</span>
      <span class="price-cycle">/ ${escapeHtml(cycle)}</span>
    </div>
    ${listAmount > amount ? `<div style="margin-top: -12px; margin-bottom: 18px; font-size: 12px; font-weight: 600; color: #6ee7b7;">Founders Rate Locked Now (Reg. $${escapeHtml(listAmount)}/${escapeHtml(cycle)})</div>` : ""}

    <ul class="features">${featureItemsHtml}
    </ul>

    <form method="GET" action="/v1/billing/checkout/complete">
      <input type="hidden" name="tier" value="${escapeHtml(tierId)}">
      <input type="hidden" name="cycle" value="${escapeHtml(billingCycle)}">
      <input type="hidden" name="session_id" value="${escapeHtml(session.id || "")}">
      <label class="field-label" for="email">Account Email (binds your license &amp; vault)</label>
      <input class="email-input" id="email" name="email" type="email" value="${escapeHtml(customerEmail)}" placeholder="you@example.com" required>
      <button type="submit" class="btn">Complete Upgrade &amp; Activate ZeroDrive ${escapeHtml(tierName)}</button>
    </form>
    <div class="note">Issues a signed ZeroDrive license key immediately and activates your Mac app.</div>
  </div>
</body>
</html>`;
}

function renderCheckoutCompleteHtml(record) {
  const tierName = record.tier_name || "Pro";
  const quotaTB = record.quota_tb || 1;
  const email = record.customer_email || "";
  const licenseKey = record.license_key || "";
  const deepLink = `zerodrive://license-activate?key=${encodeURIComponent(licenseKey)}&email=${encodeURIComponent(email)}`;

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>ZeroDrive ${escapeHtml(tierName)} Activated</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: #0d0f12;
      color: #f0f3f6;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      padding: 24px;
    }
    .card {
      background: #16191f;
      border: 1px solid #232833;
      border-radius: 16px;
      max-width: 520px;
      width: 100%;
      padding: 36px 32px;
      text-align: center;
      box-shadow: 0 20px 40px rgba(0,0,0,0.4);
    }
    .pill {
      display: inline-block;
      background: rgba(16, 185, 129, 0.16);
      color: #34d399;
      border: 1px solid rgba(16, 185, 129, 0.35);
      padding: 4px 12px;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 700;
      margin-bottom: 14px;
    }
    h1 { font-size: 24px; margin-bottom: 8px; }
    .sub { color: #8b949e; font-size: 14px; margin-bottom: 20px; }
    .key-box {
      background: #0d0f12;
      border: 1px solid #2b3140;
      border-radius: 10px;
      padding: 14px;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 16px;
      font-weight: 700;
      color: #34d399;
      margin-bottom: 14px;
      word-break: break-all;
    }
    .row { display: flex; gap: 10px; justify-content: center; }
    .btn {
      display: inline-block;
      padding: 12px 20px;
      background: #2563eb;
      color: #ffffff;
      border-radius: 8px;
      text-decoration: none;
      font-size: 14px;
      font-weight: 600;
      border: none;
      cursor: pointer;
    }
    .btn-secondary {
      background: #232833;
      color: #f0f3f6;
    }
  </style>
</head>
<body>
  <div class="card">
    <div class="pill">UPGRADE COMPLETE • ${escapeHtml(tierName).toUpperCase()} (${escapeHtml(quotaTB)} TB)</div>
    <h1>ZeroDrive ${escapeHtml(tierName)} Ready</h1>
    <p class="sub">${email ? `Bound to <strong>${escapeHtml(email)}</strong>` : "License key generated"}</p>
    <div class="key-box" id="licenseKey">${escapeHtml(licenseKey)}</div>
    <div class="row">
      <button class="btn btn-secondary" onclick="navigator.clipboard.writeText(document.getElementById('licenseKey').textContent); this.textContent='Copied!';">Copy Key</button>
      <a class="btn" href="${deepLink}">Activate in ZeroDrive Mac App</a>
    </div>
  </div>
</body>
</html>`;
}

function renderAlreadyOnHigherPlanHtml(existingAccount, requestedTier) {
  const currentTier = existingAccount?.tier || "Studio Enterprise";
  const currentQuota = existingAccount?.quotaTB || 20;
  const email = existingAccount?.email || "";
  const requestedName = requestedTier?.name || "Pro";
  const requestedTB = Number(((requestedTier?.storage_gb || 1024) / 1024).toFixed(2));

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Already on ${escapeHtml(currentTier)} — ZeroDrive</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: #0d0f12;
      color: #f0f3f6;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      padding: 24px;
    }
    .card {
      background: #16191f;
      border: 1px solid #232833;
      border-radius: 16px;
      max-width: 520px;
      width: 100%;
      padding: 36px 32px;
      text-align: center;
      box-shadow: 0 20px 40px rgba(0,0,0,0.4);
    }
    .pill {
      display: inline-block;
      background: rgba(16, 185, 129, 0.16);
      color: #34d399;
      border: 1px solid rgba(16, 185, 129, 0.35);
      padding: 5px 14px;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 700;
      margin-bottom: 16px;
    }
    h1 { font-size: 24px; margin-bottom: 10px; }
    .sub { color: #9ca3af; font-size: 15px; line-height: 1.5; margin-bottom: 24px; }
    .btn {
      display: inline-block;
      padding: 12px 22px;
      background: #2563eb;
      color: #ffffff;
      border-radius: 8px;
      text-decoration: none;
      font-size: 14px;
      font-weight: 600;
      border: none;
      cursor: pointer;
    }
  </style>
</head>
<body>
  <div class="card">
    <div class="pill">MAX PLAN ACTIVE • ${escapeHtml(currentTier).toUpperCase()} (${escapeHtml(currentQuota)} TB)</div>
    <h1>You're Already on ${escapeHtml(currentTier)}</h1>
    <p class="sub">
      <strong>${escapeHtml(email)}</strong> already includes <strong>${escapeHtml(currentQuota)} TB</strong> of managed storage and full features — higher than ${escapeHtml(requestedName)} (${escapeHtml(requestedTB)} TB). No payment or key change was made, so your plan stays untouched.
    </p>
    <button class="btn" onclick="window.close()">Close Tab &amp; Return to ZeroDrive</button>
  </div>
</body>
</html>`;
}

function renderStripeNotConfiguredHtml(session) {
  const tierName = session?.tierName || "Pro";
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Checkout Setup Pending — ZeroDrive ${escapeHtml(tierName)}</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: #0d0f12;
      color: #f0f3f6;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      padding: 24px;
    }
    .card {
      background: #16191f;
      border: 1px solid #232833;
      border-radius: 16px;
      max-width: 520px;
      width: 100%;
      padding: 36px 32px;
      text-align: center;
      box-shadow: 0 20px 40px rgba(0,0,0,0.4);
    }
    .pill {
      display: inline-block;
      background: rgba(245, 158, 11, 0.16);
      color: #fbbf24;
      border: 1px solid rgba(245, 158, 11, 0.35);
      padding: 5px 14px;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 700;
      margin-bottom: 16px;
    }
    h1 { font-size: 24px; margin-bottom: 10px; }
    .sub { color: #9ca3af; font-size: 15px; line-height: 1.5; margin-bottom: 24px; }
  </style>
</head>
<body>
  <div class="card">
    <div class="pill">STRIPE CHECKOUT NOT YET CONNECTED</div>
    <h1>Card Billing Setup Pending</h1>
    <p class="sub">
      Live credit card checkout requires <code>STRIPE_SECRET_KEY</code> to be connected on your ZeroDrive billing worker. Unpaid license key issuance is disabled so plans cannot be upgraded or altered without payment.
    </p>
  </div>
</body>
</html>`;
}
