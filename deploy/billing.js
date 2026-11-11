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
      mcp_token: false,
      fleet_rendering: false,
      agent_skill_registry: false,
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
    aliases: ["pro", "professional"],
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
    name: "Agency Partner",
    aliases: ["team", "team_agency", "partner"],
    price_monthly: 497.00,
    price_yearly: 4970.00,
    storage_gb: 10240, // 10TB
    max_drives: -1, // Unlimited
    max_devices: -1, // Unlimited
    seats: 5,
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

  // If Stripe secret key is absent or mock, return mock checkout session
  const stripeKey = env?.STRIPE_SECRET_KEY;
  if (!stripeKey || stripeKey.startsWith("mock") || stripeKey === "dummy") {
    const sessionId = `cs_mock_${randomHex(16)}`;
    const defaultSuccess = successUrl || `https://zerodrive.dev/checkout/success?session_id=${sessionId}`;
    return {
      id: sessionId,
      url: `https://checkout.stripe.com/mock/${tier.id}?session_id=${sessionId}`,
      successUrl: defaultSuccess,
      tierId: tier.id,
      tierName: tier.name,
      billingCycle: cycle,
      amount: price,
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
  params.append("success_url", successUrl || "https://zerodrive.dev/checkout/success?session_id={CHECKOUT_SESSION_ID}");
  params.append("cancel_url", cancelUrl || "https://zerodrive.dev/pricing");

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

  const cleanKey = licenseKey.trim();
  const license = await loadLicenseRecord(env, cleanKey);

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

  return {
    valid: true,
    tier: license.tier,
    tier_name: license.tier_name,
    quota_gb: license.quota_gb,
    user_prefix: license.user_prefix,
    tenant_id: license.tenant_id,
    customer_id: license.customer_id,
    customer_email: license.customer_email,
    max_drives: license.max_drives,
    status: license.status,
    activated_machines: license.activated_machines || [],
    flags: license.flags || {}
  };
}

/**
 * License activation helper: links a client machine ID to an active license
 */
export async function activateLicenseKey(env = {}, {
  licenseKey,
  machineId,
  machineName = "Default Device",
  os = "unknown"
} = {}) {
  const cleanKey = (licenseKey || "").trim();
  const cleanMachineId = (machineId || "").trim();

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

  if (!Array.isArray(license.activated_machines)) {
    license.activated_machines = [];
  }

  // Check if machine is already registered
  const existing = license.activated_machines.find(m => m.machine_id === cleanMachineId);
  if (existing) {
    return {
      valid: true,
      activated: true,
      already_active: true,
      machine_id: cleanMachineId,
      tier: license.tier,
      quota_gb: license.quota_gb,
      user_prefix: license.user_prefix,
      drives_allowed: license.max_drives,
      active_devices: license.activated_machines.length
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

  return {
    valid: true,
    activated: true,
    machine_id: cleanMachineId,
    tier: license.tier,
    quota_gb: license.quota_gb,
    user_prefix: license.user_prefix,
    drives_allowed: license.max_drives,
    active_devices: license.activated_machines.length
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
        tiers,
        count: Object.keys(tiers).length
      });
    }

    // 2. GET & POST /v1/billing/checkout — creates Stripe Checkout session
    if (pathname === "/v1/billing/checkout" && (method === "GET" || method === "POST")) {
      let tierId = url.searchParams.get("tierId") || url.searchParams.get("tier") || "promax";
      let billingCycle = url.searchParams.get("cycle") || url.searchParams.get("billingCycle") || "monthly";
      let customerEmail = url.searchParams.get("email") || url.searchParams.get("customerEmail") || "user@zerodrive.dev";
      let successUrl = url.searchParams.get("successUrl");
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

      const session = await createCheckoutSession(env, {
        tierId,
        billingCycle,
        customerEmail,
        successUrl,
        cancelUrl
      });

      const acceptHeader = request.headers.get("accept") || "";
      if (method === "GET" && !acceptHeader.includes("application/json")) {
        if (!session.mock && session.url) {
          return Response.redirect(session.url, 302);
        }
        return new Response(renderCheckoutPageHtml(session), {
          status: 200,
          headers: { ...corsHeaders, "Content-Type": "text/html; charset=utf-8" }
        });
      }

      return jsonResp({ ok: true, session });
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

      if (!licenseKey || !machineId) {
        return jsonResp({ ok: false, error: "Both licenseKey and machineId are required" }, 400);
      }

      const activation = await activateLicenseKey(env, { licenseKey, machineId, machineName, os });
      if (!activation.activated) {
        return jsonResp({ ok: false, error: activation.error, ...activation }, 400);
      }

      return jsonResp({ ok: true, ...activation });
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

/**
 * Renders a dark-mode checkout landing page when opened in a browser
 */
function renderCheckoutPageHtml(session) {
  const tierName = session.tierName || "Pro Max";
  const amount = session.amount || 97;
  const cycle = session.billingCycle === "yearly" ? "year" : "month";

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Checkout — ZeroDrive ${tierName}</title>
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
      margin-bottom: 24px;
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
    <div class="badge">Founder Tier</div>
    <div class="title">ZeroDrive ${tierName}</div>
    <p style="color: var(--text-muted); font-size: 14px;">Instant multi-drive cloud partition with unthrottled streaming speed.</p>
    
    <div class="price-row">
      <span class="price-val">$${amount}</span>
      <span class="price-cycle">/ ${cycle}</span>
    </div>

    <ul class="features">
      <li>
        <svg viewBox="0 0 24 24"><polyline points="20 6 9 17 4 12"></polyline></svg>
        <strong>3 TB Dedicated Cloud Storage</strong> (Zero setup, unthrottled)
      </li>
      <li>
        <svg viewBox="0 0 24 24"><polyline points="20 6 9 17 4 12"></polyline></svg>
        <strong>Unlimited Independent Drives</strong> in Finder & File Explorer
      </li>
      <li>
        <svg viewBox="0 0 24 24"><polyline points="20 6 9 17 4 12"></polyline></svg>
        <strong>Unlimited Fleet Machines</strong> (Mac, Windows, Minis)
      </li>
      <li>
        <svg viewBox="0 0 24 24"><polyline points="20 6 9 17 4 12"></polyline></svg>
        <strong>24/7 Agent MCP Token</strong> & skill registry access
      </li>
      <li>
        <svg viewBox="0 0 24 24"><polyline points="20 6 9 17 4 12"></polyline></svg>
        <strong>Zero Egress Fees</strong> & direct multi-cloud streaming
      </li>
    </ul>

    <a href="${session.url || '#'}" class="btn">Proceed to Stripe Checkout</a>
    <div class="note">Encrypted & secure billing powered by Stripe. Cancel anytime in 1-click.</div>
  </div>
</body>
</html>`;
}
