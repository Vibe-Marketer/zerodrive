# ZeroDrive launch offer and funnel

Drafted November 10, 2026 with the Offer Machine skill. Revision 2, same day, after Andrew's decisions. Status: **CONCEPT COMPLETE, ECONOMICS PROVISIONAL.** Nothing here is priced in Stripe, built or published.

Inputs read: [product strategy](../docs/product-strategy-and-market-research.md), [founder board verdict](../founder/board.md), live tier code in `deploy/billing.js`, onboarding code, `bin/zerodrive-mcp`, the [12 Month Millionaire swipe](/Users/Naegele/_LIBRARY/Swipes/12-month-millionaire/ROUTER.md), and Andrew's pasted launch notes and blueprint.

## Andrew's decisions (revision 2)

1. **Free stays 10 GB on the user's own Cloudflare.** Andrew pays nothing for free storage. Users sign up, sign in, and press "Connect Cloudflare." Hitting 10 GB is the switch to paid.
2. **Free users get MCP access, no API.**
3. **Bonuses (ReelFarm skill, fleet setup, the full stack) are not ready to share.** The software ships now. The bonuses do not go in the launch stack.
4. **The launch offer is Pro Max as a Founder Special,** price rising $10 for every 10 founders and locked for those who join. Start at $39 or $49 (open, see section 2).
5. **The other paid plan is Agency.**

---

## 0. Launch blockers (verified in code)

1. **Customers are not kept apart.** `deploy/worker.js:218` `extractTenantFromAuth` takes the customer ID from the `Credential=` header without checking the signature, and falls back to `default_tenant`. Anyone who knows or guesses a customer ID could reach that customer's hosted files through `/s3/`. This applies to every paid vault. Free vaults sit in the user's own Cloudflare and are not exposed this way. Live endpoint not probed.
2. **"Connect Cloudflare" is not one click yet.** `OnboardingView.swift` `connectFreeCloudflare` asks the user to paste an account ID, access key, secret key and bucket name. To match "they don't set anything up," it needs a Cloudflare sign-in button that creates the bucket and keys for them. No Cloudflare OAuth code exists in the repo today.
3. **Cloudflare asks for a card before R2 works.** As far as I know, Cloudflare requires a payment method on the account before R2 can be turned on, even within the free 10 GB. Not checked today. Confirm it in the three-tester run, because a card prompt inside Cloudflare is where free signups will drop.
4. **The 10 GB → paid move is not tested.** The plan in the strategy doc (both buckets shown together, cloud-to-cloud copy, checksum, switch) is marked tentative.

---

## 1. Free vault: the front door

| Free vault | |
|---|---|
| Storage | 10 GB in the user's own Cloudflare account. $0 to Andrew |
| Setup | Sign up, sign in, Connect Cloudflare |
| AI access | MCP for AI tools **on that computer** (local `zerodrive-mcp` works through the mounted drive) |
| Not included | API, hosted MCP (Claude.ai, ChatGPT, phone, VPS agents), more machines |
| Upgrade trigger | 10 GB reached, or wanting their AI to reach the vault from anywhere |

Code observation: the hosted MCP at `api.zerodrive.dev` reads only storage Andrew hosts (`env.VAULT_BUCKET`), never a user's own bucket. That fits the plan. **Free = AI on your computer. Paid = AI from anywhere.** That is a second upgrade reason besides the 10 GB limit, and it is the fleet story.

The registration is still the free vault, not a waitlist. By event day the person has the product installed and has watched their AI write into it.

---

## 2. The Founder Special: Pro Max

Pro Max today in `billing.js` is "Studio Max": $99/mo, 3 TB hosted, 8 vaults, unlimited machines.

| Founders | Start at $49 (recommended) | Start at $39 |
|---|---|---|
| 1–10 | $49 | $39 |
| 11–20 | $59 | $49 |
| 21–30 | $69 | $59 |
| 31–40 | $79 | $69 |
| 41–50 | $89 | $79 |
| 51–60 | $99 list | $89 |
| 61+ | $99 list | $99 list |
| Revenue if every step sells | $3,450/mo from 50 founders | $3,840/mo from 60 founders |

**Why $49, not $39: a founder who fills 3 TB on a locked $39 costs you money every month for as long as they stay.**

| Per founder per month | 40% used (1.2 TB) | Full 3 TB |
|---|---|---|
| $39 locked | $39 − $18 storage − $1.43 Stripe − $1 requests = **+$18.57** | $39 − $45 − $1.43 − $1 = **−$8.43** |
| $49 locked | $49 − $18 − $1.72 − $1 = **+$28.28** | $49 − $45 − $1.72 − $1 = **+$1.28** |
| $99 list | $99 − $18 − $3.17 − $1 = **+$76.83** | $99 − $45 − $3.17 − $1 = **+$49.83** |

R2 storage is $15 per TB a month. The $1 for requests and Worker calls is an assumption to measure. If $39 matters for the headline, keep it and give founders 2 TB at that price with +$25 per extra TB.

Rules that make the step mechanic work:
1. **$99 is shown on every page from day one.** A discount is only believed when the full price was public first.
2. **The counter is real and steps never go backwards.**
3. **"Locked" means for as long as they stay subscribed.** Say so on the page. Cancelling and coming back means the current price.

What Pro Max sells (the price is carried by "AI from anywhere," not gigabytes):
- 3 TB hosted vault, nothing to set up
- Hosted MCP: Claude.ai, ChatGPT, Cursor, phone and VPS agents all reach the same vault
- API access
- Unlimited computers, Mac and Windows
- Move-in from iCloud (proven on Andrew's own Macs only; leave Dropbox and Google Drive out of the copy until tested)

**Guarantee:** 30 days, full refund, no questions asked. Your files stay yours: download everything for 30 days after you cancel.

**The bonuses that are not ready:** keep them off the value stack and off the price justification. One line on the page is enough: "Founders get the ReelFarm skill, the fleet playbook and my full stack free as each one is released." Give no dates unless you will keep them. Their release becomes the reason for a second launch event to the free list.

Cut from the public page: Builder, Creator, Studio, BYOK Lifetime. They stay in the code, hidden, for later use.

---

## 3. Agency

| | |
|---|---|
| List | $497/mo |
| Founding Agency | $297/mo on a 12-month agreement, 10 TB included, +$25/TB after, 10 seats |
| Includes | White label domain, branded MCP portal for clients, client sub-vaults, resale rights at their own price, 5 team seats |
| How sold | Application link on the confirmation page; Andrew closes on a call |

Margin at full 10 TB: $297 − $150 storage − ~$9 Stripe ≈ **$138/mo** before support time. Support hours per agency: missing. Client sub-vaults depend on blocker 1 and on `deploy/teams.js`, which was not tested.

---

## 4. Funnel map

```
Ads / organic / email list
        |
1. Register: "Get your free ZeroDrive + save your seat for the live launch"
   (sign up -> sign in -> Connect Cloudflare)
        |
2. Founder Special page: short video, live founder counter, current price, $99 shown,
   what Pro Max adds over free (AI from anywhere, 3 TB hosted, API), guarantee
        |                                   \
3. Checkout (+ optional bump)                 decline -> 4
        |
4. Confirmation: connect your AI now (5-minute win), add the event to your calendar,
   Agency application link
        |
5. Warm-up emails, one belief each
        |
6. Live event -> 7. Founders call -> 8. Replay 72 hours
        |
9. Price keeps stepping up after the event until $99
```

**Order bump (optional):** Concierge Move-In, $97 once. We move their iCloud folder in, cloud to cloud. Cap it by your capacity. Skip it if you don't want the work.

**Live-only moment:** the original plan used the fleet build as the live-only reveal. That isn't ready to hand over, so **show it, don't give it.** Live: an agent on a VPS and Claude on your phone both working in the same vault as your Mac, in real time. That demonstrates exactly what Pro Max adds over free. Cut that segment from the replay.

**Warm-up emails (one belief each):**
1. Your AI starts from zero every session: no memory, no files, no skills.
2. Dumb storage: what Drive, Dropbox and iCloud don't do for AI.
3. Recorded demo: an agent filing and reusing real work in a vault.
4. The live demo named and teased, not explained.
5. The founder counter and the price steps.
6. Logistics and what's cut from the replay.
7. "Is there a replay?" Yes, minus the live demo.

**Event (90 minutes):** dumb storage (10) → your own vault (20) → AI from anywhere, live (25) → Founder Special at the current price (15) → Q&A and close (20) → founders call.

---

## 5. Timeline (recommended)

Black Friday is Friday November 27; avoid that week's inboxes.

| When | What |
|---|---|
| Nov 10–20 | Fix blocker 1. Build one-click Connect Cloudflare. Test 10 GB → paid move. Three non-owners go from signup to their AI writing a file, alone |
| Nov 20–29 | Pages, Stripe prices for each step, upgrade video, warm-up demo |
| Tue Dec 1 | Registration opens; warm-up starts |
| **Thu Dec 10** | Live launch + founders call |
| Dec 10–13 | Replay |

---

## 6. Missing numbers

Free-to-paid conversion, refund rate, average storage used per founder, request cost per user, support hours per agency, ad cost per free signup. None are guessed in the tables above except the $1 request cost, which is labelled.
