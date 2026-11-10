# ZeroDrive launch offer and funnel

Drafted November 10, 2026 with the Offer Machine skill (route: product exists but is not packaged, plus money model). Status: **CONCEPT COMPLETE, ECONOMICS PROVISIONAL.** Nothing here is approved, priced in Stripe, or published.

Inputs read: [product strategy](../docs/product-strategy-and-market-research.md), [founder board verdict](../founder/board.md) (same day), live tier code in `deploy/billing.js`, the [12 Month Millionaire swipe](/Users/Naegele/_LIBRARY/Swipes/12-month-millionaire/ROUTER.md), and Andrew's pasted launch notes and blueprint. The blueprint file it names (`~/workspace/zerodrive-launch/blueprint.md`) does not exist on this Mac; the pasted copy was used.

---

## 0. Launch blocker (verified in code, fix first)

`deploy/worker.js:218` `extractTenantFromAuth` takes the customer ID straight from the `Credential=` text in the request header and never checks the signature. A request with no credential falls through to `default_tenant`. Anyone who knows or guesses a customer ID can list, read, write or delete that customer's files through `/s3/`. This was flagged on November 6 as "safe for one user only" and is still in the code.

No outside person gets a vault, free or paid, until the S3 route verifies a per-customer secret. Checked: code at HEAD only. The live endpoint was not probed.

---

## 1. Answers to Andrew's three questions

### Q1. Keep the free tier? **Yes, but it stops being a tier and becomes the front door.**

In the Brunson funnel, registering for the free event is the front door. Here, **creating a free vault is the registration.** That is stronger than their opt-in: by event day the person has the product installed and has watched their own AI write into it.

Change what free includes, because the board was right that today's free tier hides the product (MCP token off, so it looks like a 10 GB Mountain Duck):

| Free vault (recommended) | Today in `billing.js` |
|---|---|
| 5 GB **hosted by ZeroDrive** (sign in with Google, nothing else to set up) | 10 GB on the user's own Cloudflare account |
| MCP token **on**, with a daily request cap | MCP off |
| 1 computer + 1 AI agent connection | 1 Mac + 1 VPS |
| No skills pack, no fleet, no monthly drop | — |

Why hosted instead of bring-your-own-Cloudflare: asking a stranger to create a Cloudflare account kills registrations, and that sign-up path has not been tested. Hosted 5 GB costs at most about $0.075 per user a month in R2 storage (5 GB × $0.015). 1,000 full free users ≈ $75 a month plus request costs (request costs: missing, measure in the first week).

The free vault's job: one "aha" in five minutes. Connect Claude to the vault, ask it to save a note, see the file appear in Finder.

### Q2. Narrow to Studio with a founder price that climbs $10 every 10 founders up to $97? **Yes. This is the right launch mechanic.** Two conditions.

Recommended ladder (start price is my recommendation; Andrew did not name one):

| Founding seats | Monthly price, locked for as long as they stay subscribed |
|---|---|
| 1–10 | $47 |
| 11–20 | $57 |
| 21–30 | $67 |
| 31–40 | $77 |
| 41–50 | $87 |
| 51 and after | $97 (list price) |

Conditions that make or break it:
1. **$97 is public from day one** on every page. A discount is only believed when the full price was shown before anyone could buy.
2. **The counter is real and the steps are never rolled back.** Show the live seat count. If seat 11 pays $57, nobody after them ever gets $47.

Why this beats Brunson's mechanic for software: he closes pre-orders when the event starts (a cliff). A price step rewards deciding early without shutting the door, so the live event stays a selling floor.

What Studio must include to be worth $97 (storage alone is worth ~$15/TB, so the price has to be carried by the AI and fleet value, not the gigabytes):
- 1 TB managed vault, +$25 per extra TB
- Unlimited computers and AI agents (the fleet: log in from anywhere, Mac, Windows, VPS)
- Hosted MCP for Claude, ChatGPT, Cursor and other agents
- Skills saved into the vault that every agent can reuse
- **Monthly Skills Drop**: new skills delivered into members' vaults, members only, never posted (the retention engine, the Brunson newsletter equivalent)
- Move-in tools for iCloud (proven on Andrew's setup only), Dropbox and Google Drive (not yet tested; leave out of copy until tested)

Cut from the public price page: Builder, Creator, Studio Max, BYOK Lifetime. They stay in the code, hidden. BYOK Lifetime at $197 once undercuts Studio by itself (all three board members said so). Builder at $19 is parked as a possible after-event downsell only (section 4).

### Q3. Agency at $497/mo with white label and reseller rights; $297/mo on a 12-month term capped at 10 TB? **Yes as a founding offer by application, not a public checkout.**

| | Recommended |
|---|---|
| List price | $497/mo |
| Founding Agency | $297/mo on a 12-month agreement, **10 seats only** |
| Storage | 10 TB included, +$25/TB after |
| Includes | White-label domain, branded MCP portal for their clients, client sub-vaults, resale rights at their own price, 5 team seats |
| How sold | Application form on the confirmation page and a pitch on the private founders call; Andrew closes on a call |

Why by application: the board split on Agency (Offers lens: no demand evidence; Monopoly lens: the only tier where customers bring their own customers). An application with a real price tests demand without building more. Do not build the $297 BYOK agency variant until an agency asks for it.

Margin check at full 10 TB use: $297 − $150 storage − ~$9 Stripe ≈ $138 a month (46%) before support time. At 40% use ≈ $228 (77%). Support hours per agency: missing. That is the number that decides whether 10 seats is the right cap.

Extra blocker for Agency: client sub-vaults depend on the tenant fix in section 0 and on `deploy/teams.js`, which was not tested in this review.

---

## 2. Waitlist, beta or live launch? **Live launch. No separate waitlist.**

- A waitlist collects an email and nothing else. The free vault collects an email **and** gets the product into their workflow. The free vault replaces the waitlist.
- Call it **Founding**, not Beta. Beta says unfinished. Founding says early, with a reward for going first.
- Use Andrew's guarantee, made specific to a storage product: **"30 days, full refund, no questions asked. And your files stay yours: download everything for 30 days after you cancel."** Files are plain objects in R2, so this is true by design and answers the biggest fear about moving files to a new drive.
- ReelFarm skill, fleet setup and "the complete stack" should **not** be separate waitlists. Separate waitlists split attention across three products before the first one is sold. They become the bonus stack and the live-only reveal (section 3).

---

## 3. The offer stack (Founding Studio)

**One sentence:** ZeroDrive is the cloud drive your AI actually lives in. Every agent on every machine reads, writes and remembers in one place.

**The enemy:** dumb storage. Drive, Dropbox and iCloud were built for people filing documents. They don't speak MCP, they can't hold your agent's skills, their AI is a sidebar, and they fill your Mac's disk with cache.

| Piece | What it is | Who gets it |
|---|---|---|
| Free vault | 5 GB, MCP on, 1 computer + 1 agent | Everyone who registers |
| Live launch event | 90 minutes on YouTube Live | Everyone who registers |
| **Live-only reveal: "The Fleet Build"** (working name) | Andrew builds a fleet live: Mac, Windows PC and a VPS agent all on one vault, logged in from anywhere, an agent saving a skill that the other machines use. Attendees get the fleet config. **Cut from the replay.** | Live attendees |
| Founding Studio | Everything in section 1, Q2, price locked | Buyers |
| Bonus 1: **The Stack** | Andrew's exact vault structure and skill set, installed into the buyer's vault: "the stack I use to deliver AI and automation for [client size]" | Founding only |
| Bonus 2: ReelFarm skill | Andrew's reel production skill | Founding only |
| Bonus 3: Founders WhatsApp | First 500 paying members, whatever price they paid | Founding only |
| Bonus 4: Private founders call | Right after the public stream ends (Brunson's VIP-room mirror). Agency pitch happens here | Founding only |

Note on the 500 cap vs the 50 price steps: the price steps cover the first 50 seats. The WhatsApp group caps at 500 paying members. They are two different limits and both are real.

**Claim flag:** "8–9 figure entrepreneurs" needs named clients at that revenue before it goes public. The Maccs figures on file are about $1.02M through November 4 (7 figures). Use `[client size]` until Andrew names who qualifies.

---

## 4. Funnel map (the Brunson structure, translated)

```
Ads / organic / email list
        |
1. Register page: "Create your free vault + save your seat for the live launch"
   (Google sign-in = the opt-in)
        |
2. Founding upgrade page (their VIP page): short video from Andrew,
   live seat counter, current step price, $97 shown, bonus stack, guarantee
        |                                   \
3. Checkout + 2 order bumps                  decline -> 4
        |
4. Confirmation: "You're in." Do this now: connect Claude to your vault (5-minute win),
   add the event to your calendar, WhatsApp link (founders), Agency application link
        |
5. Warm-up emails, one belief each (7 touches)
        |
6. Live event -> 7. Founders-only call -> 8. Replay (72 hours, Fleet Build removed)
        |
9. After: price keeps stepping up; $97 list once seat 51 is sold
```

**Order bumps** (checkout, one decision each):
- A. **Concierge Move-In**, $97 once: we move their iCloud folder into ZeroDrive cloud-to-cloud, nothing touches their disk. Cap by capacity. iCloud only until other sources are tested.
- B. **1:1 Fleet Setup**, $197 once, 45 minutes with Andrew, 20 seats. Remove if Andrew won't do calls.

**After checkout:** Founding Agency application, shown only to buyers who say they serve clients.

**Downsell (parked):** after the replay closes, non-buyers with a free vault can be offered Starter at $19/mo (256 GB, MCP, no fleet, no Stack, no Skills Drop). Only switch it on if founding sales stall; it must not be offered during the event.

**Warm-up sequence** (from the pasted blueprint, one belief per touch):
1. Your AI starts from zero every session: no memory, no files, no skills.
2. The enemy tour: the "they don't" list for Drive, Dropbox, iCloud.
3. Recorded demo: an agent filing and reusing real work in a vault.
4. The Fleet Build named and teased, never explained.
5. Seats, the counter, and the price steps.
6. Logistics, and what is cut from the replay.
7. "Will there be a replay?" Yes, minus the Fleet Build.

**Event run of show (90 minutes, not 4 hours):** enemy (10) → live demo in Andrew's own vault (20) → The Fleet Build (25) → offer at the current step price (15) → Q&A and close (20) → end public stream → founders call.

---

## 5. Economics (provisional)

Assumptions are labelled. Request and Worker costs are estimated at $1 per paid user a month: **assumption, measure it.**

| Per member per month | At 40% of 1 TB used | At full 1 TB |
|---|---|---|
| Founding $47 | $47 − $6 storage − $1.66 Stripe − $1 = **~$38 (81%)** | $47 − $15 − $1.66 − $1 = **~$29 (62%)** |
| List $97 | $97 − $6 − $3.11 − $1 = **~$87 (90%)** | $97 − $15 − $3.11 − $1 = **~$78 (80%)** |

If all 50 founding seats sell: 10 × ($47 + $57 + $67 + $77 + $87) = **$3,350 a month**, before bumps and Agency. Ten founding agencies add $2,970 a month on 12-month terms. Refund rate, support hours, ad cost per free vault and free-to-paid conversion: **missing.** No spreadsheet was filled; this table is the economics record for now.

---

## 6. Timeline (recommended dates)

Black Friday is Friday November 27, so avoid that week's inboxes.

| When | What |
|---|---|
| Nov 10–20 | Fix tenant auth. Switch free tier to hosted 5 GB with MCP on. Three people who are not Andrew set up a free vault alone and connect an agent. Watch Brunson's Nov 12 event and file it into the swipe |
| Nov 20–29 | Build register, upgrade, checkout, confirmation pages. Create Stripe prices for the six steps and the bumps. Record the upgrade video and the warm-up demo |
| Tue Dec 1 | Registration opens. Warm-up emails start |
| **Thu Dec 10** | Live launch event + founders call |
| Dec 10–13 | Replay, 72 hours, Fleet Build removed |

---

## 7. Three ways this dies

1. A stranger's files get read by another stranger (section 0).
2. The price step is quietly extended or rolled back once. Every future deadline becomes worthless.
3. The Fleet Build disappoints live. The whole funnel amplifies the reveal, weak or strong. Rehearse it twice on a clean machine.
