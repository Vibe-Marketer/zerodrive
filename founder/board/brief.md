# Board brief: ZeroDrive offer ladder and pricing

Read this whole file. You cannot see the conversation it came from. The question for the board: **is this offer ladder and pricing the right one to launch with, and what would make it fail?**

## The product (what exists today, per the owner's repo and status docs)

ZeroDrive is a cloud drive for people working with AI agents and several machines.

- macOS Finder integration (Apple FileProvider) with 0-byte placeholders that fill in on open; Windows Explorer integration (Cloud Files API). Local files not opened for 7 days are evicted back to placeholders when free disk space drops under 20 GB.
- Files are stored as plain objects in Cloudflare R2 ($0.015 per GB per month, $0 egress). Not a proprietary block format.
- Real-time change push (under 100 ms) between machines; conflicts create a "Conflicted copy" file instead of overwriting.
- Large-file upload that avoids Cloudflare's 100 MB request limit (multipart, files up to 5 TB), and video byte-range streaming from the edge cache.
- A hosted MCP server (api.zerodrive.dev/mcp, bearer token) and a CLI (`zd`) so agents on any machine read and write the vault. A skill registry for agents.
- One-line mount of the vault on a Linux VPS so a cloud agent sees the same files.
- Cloud-to-cloud migration (e.g. iCloud to the vault) with no local disk used; folder offload leaves a symlink at the original path.
- Proof it works: on 2026-11-10 the owner ran three 4K/60fps render jobs in parallel across a 4-machine fleet (about 25 minutes versus an estimated 90+ minutes serial), using the drive as job queue, asset store and output delivery. The owner's own vault holds about 148 GB in about 797,000 objects.
- Billing and licensing are implemented (Stripe checkout, webhook provisioning, license keys, machine-slot limits) with the ladder below.

## The ladder as coded and as proposed

| Tier | Price | Hosted storage | Vaults | Machine slots | Notes |
|---|---|---|---|---|---|
| Free Starter | $0 | 10 GB, user's own Cloudflare bucket (BYOK) | 1 | 2 (1 Mac + 1 VPS) | In code, the free tier has the MCP token, agent skill registry and fleet rendering switched off |
| Builder | $19/mo or $97/yr | 256 GB | 1 | 2 | Zero-setup desktop offload, personal MCP token |
| Creator | $29/mo or $197/yr | 512 GB | 2 | 4 | Work and personal vault split, cloud-to-cloud migration |
| Studio | $49/mo or $397/yr | 1 TB | 4 | Unlimited | Fleet rendering, agent skill registry |
| Studio Max | $99/mo or $897/yr | 3 TB | 8 | Unlimited | Fleet rendering, agent skill registry |
| Agency Partner | $497/mo or $4,970/yr | 10 TB, +$25 per TB | Unlimited plus sub-accounts | Unlimited, 5 seats | White-label custom domain (drive.agency.com), branded MCP |
| BYOK Lifetime | $197 once | Unlimited, user's own bucket (copy says Cloudflare, AWS or B2) | Unlimited | Unlimited | Single user, all updates, fleet rendering and skill registry included |

Under consideration, not built: an Agency BYOK option at $297/mo where the agency provisions its own Cloudflare account and handles its own billing.

Annual price as a share of 12 months at the monthly price: Builder 43%, Creator 57%, Studio 68%, Studio Max 76%, Agency 83%.

## Costs the owner has recorded

- R2 storage $0.015 per GB per month, $0 egress. R2 also charges per request (Class A and B operations) and there are Cloudflare Worker request costs; neither is in the owner's margin figures.
- The owner's stated gross margins: Builder 87.9%, Creator 84.1%, Studio 81.2%, Studio Max 72.1%, Agency 69.8%. The lower four tiers assume about 60% of included storage is used; Agency assumes it is nearly full.
- Stripe card fees are not included in those margins.

## Competitors as recorded by the owner (not independently verified)

- Mountain Duck: $49 one-time, bring your own storage. CloudMounter: $29.99/yr or $44.99 lifetime. RcloneView: free to $99.80 lifetime. All BYO storage.
- LucidLink: $27 to $32 per seat per month plus about $80 per TB per month; proprietary block format.
- Fabric Drive: $18/mo for 250 GB, $54/mo for 1 TB, 1 TB cap.
- ExpanDrive: subscription. Dropbox, Google Drive, iCloud: consumer cloud, no agent or fleet features.
- Owner's claim of difference: agent fleet support (MCP and skills), native OS integration without a heavy resident app, plain-object storage, $0 egress, the drive as a render queue, VPS mount.

## The owner's own claims about the business

- Reaching $1M annual revenue needs about 200 Agency partners or about 1,700 Studio subscribers.
- The free tier costs ZeroDrive $0 per user because users bring their own Cloudflare account (10 GB free there), and upgrading migrates their files into a hosted vault cloud-to-cloud.
- An earlier decision records Cloudflare R2 as the only storage backend. The BYOK Lifetime copy also names AWS and B2. A storage-alternatives memo says B2 has not passed a live ZeroDrive test.

## What is not known

- Number of paying customers: none recorded. Customer demand for any tier has not been tested with real buyers.
- Budget, runway, team size beyond the owner: not stated.
- Whether the free tier's Cloudflare account auto-provisioning is possible through an official third-party sign-in. Not confirmed.
- Whether the Worker can serve an agency's own Cloudflare bucket at the same speed as a hosted one.
