# ZeroDrive Founders Launch: the complete outline

Revision 3, November 10, 2026. Built with the Offer Machine skill; earlier revisions are in git history. Status: **CONCEPT COMPLETE, ECONOMICS PROVISIONAL.** Nothing is priced in Stripe, built or published yet.

Andrew's decisions (rev 3): keep it simple. Free stays 10 GB on the user's own Cloudflare, local MCP only, no API. Founders get the $49 plan for **$29 a month, locked for as long as they keep it.** Partitioning their drive is free. Extra drives: 1 TB $25, 2 TB $40, 3 TB means upgrading to Pro Max ($97). Agency is the high-end plan. Bonuses (ReelFarm, fleet playbook, full stack) are not ready and stay off the offer.

---

## 1. The offer on one page

**One line:** ZeroDrive is the cloud drive your AI actually lives in. Your files in Finder, your AI reading and writing them from anywhere, and your Mac's disk stays empty.

**The enemy:** dumb storage. Drive, Dropbox and iCloud were built for people filing documents. They don't speak MCP, can't hold your AI's skills, fill your disk with cache, and their AI is a sidebar.

| Plan | Price | What it is |
|---|---|---|
| **Free** | $0 | 10 GB on your own Cloudflare. Sign up, sign in, Connect Cloudflare. AI tools on your computer can use it (MCP). No API |
| **ZeroDrive Studio, Founders** | **$29/mo locked** (list $49) | 1 TB hosted, nothing to set up. AI from anywhere: Claude.ai, ChatGPT, Cursor, phone, cloud servers. API. Unlimited computers, Mac and Windows |
| Partition your drive | Free | Split your plan's storage into separate drives (Work, Clients, Personal), each isolated |
| Add a drive | 1 TB +$25/mo · 2 TB +$40/mo | Extra storage that doesn't use your plan's space |
| Pro Max | $97/mo | 3 TB |
| Agency | $497/mo (Founding Agency $297/mo, 12 months, 10 seats, by application) | 10 TB, white label, branded MCP portal for clients, client drives, resale rights, 5 team seats |

**Founder rule:** $29 is available until the replay closes (**Sunday December 13, 11:59 PM ET**). After that, Studio is $49. The price stays $29 as long as they stay subscribed. If they cancel and come back, they pay the current price. Say all of this on the page.

**Guarantee:** 30 days, full refund, no questions asked. Your files stay yours: download everything for 30 days after you cancel.

**Upgrade triggers built into the product:**
1. Free user hits 10 GB → "Move to Studio at the founder price."
2. Free user wants their AI on a phone, Claude.ai or a cloud server → only paid plans have hosted MCP.
3. Studio user fills 1 TB → add a drive or go Pro Max.

**Bonuses not ready:** one line on the founder page, no dates: "Founders get the ReelFarm skill, my fleet playbook and my full AI stack free as each one is released." Their release is the reason for a second launch to the free list in early 2027.

---

## 2. Numbers behind the prices (provisional)

R2 storage is $15 per TB a month. Stripe is 2.9% + $0.30. "Requests" ($1) is an assumption to measure in week one.

| Per subscriber per month | 40% of storage used | 100% used |
|---|---|---|
| Studio Founders $29, 1 TB | $29 − $6 − $1.14 − $1 = **$20.86** | $29 − $15 − $1.14 − $1 = **$11.86** |
| Studio $49, 1 TB | **$40.28** | **$31.28** |
| Add 1 TB, $25 | **$17.98** | **$8.98** |
| Add 2 TB, $40 | **$26.54** | **$8.54** |
| Pro Max $97, 3 TB | **$75.89** | **$48.89** |

Every plan stays positive even when full. Two things to know:
- **A founder can build 3 TB for $69** ($29 + $40 drive). Pro Max is $97 for 3 TB. After launch, Studio + 2 TB is $89, still under $97. Either give Pro Max something extra beyond storage, or accept that most people will add drives instead. Adding drives makes money either way.
- The 2 TB drive at $40 earns least when full ($8.54). Fine at launch; review once real usage is known.

**Goal math (assumptions to replace with real numbers after the event):**

| Step | Assumed rate | For 100 founders |
|---|---|---|
| Registrations (free signups) | — | ~2,500 |
| Show up live | 30% | ~750 |
| Buy live or during replay | 8% of registrations total | ~200 (pessimistic case 100 at 4%) |

100 founders = $2,900 a month. 200 = $5,800. Each Founding Agency adds $297.

---

## 3. The funnel, page by page

```
Traffic -> 1 Register -> 2 Founder page -> 3 Checkout -> 4 Confirmation
                      \-> decline -> 4 Confirmation
-> 5 Warm-up emails -> 6 Live event -> 7 Founders call -> 8 Replay (72 h) -> 9 Close
```

### Page 1: Register (the opt-in)
- Headline idea: "The cloud drive your AI actually lives in. Free. Live launch December 10."
- Short video (2–3 minutes): your own vault, Claude writing a file, it appears in Finder.
- The "they don't" list (Drive, Dropbox, iCloud).
- Event date and time, "the live demo is cut from the replay."
- Button: **Get ZeroDrive free + save my seat** → Google sign-in creates the account and registers them for the event in one step.

### Page 2: Founder page (right after signup; Brunson's VIP page)
- Video from Andrew, 3–5 minutes: why founders, what they get, the deadline.
- "Studio, **$49** → **$29/mo for founders**, locked for as long as you keep it."
- Free vs Studio table: 10 GB vs 1 TB; AI on this computer vs AI from anywhere; no API vs API.
- Partition free, add-drive prices, Pro Max, all shown so nothing is hidden.
- Countdown to Dec 13, 11:59 PM ET.
- Guarantee block.
- Bonuses line (released later, free for founders).
- FAQ: Is my data safe? What if I cancel? Does it work on Windows? What's MCP? What happens at 10 GB? Is it the same Finder? Does it need internet? (Yes, cloud files need internet; say it.)
- Button: **Lock in $29**. Small link: "No thanks, keep my free drive."

### Page 3: Checkout
- Stripe checkout, Studio Founders price (separate Stripe price, not a coupon, so it never expires).
- Order bump (optional): **Concierge Move-In, $97 once.** We move your iCloud folder into ZeroDrive cloud to cloud. Cap it at what you can handle. iCloud only until other sources are tested.

### Page 4: Confirmation
- "You're in." Three steps: 1) Download the app, 2) Connect your AI (5-minute win, with the exact Claude setup), 3) Add the event to your calendar.
- Agency link: "Run an agency? Apply for one of 10 Founding Agency seats."

### Page 8: Replay page
- Event recording minus the live demo segment, countdown to Dec 13, same founder button.

---

## 4. Emails

Use **launch-and-funnel-emails** to write them, **send-check** before each send.

**Free-user onboarding (sent to every signup, starts right away)**
1. Immediately: your drive is ready, connect your AI in 5 minutes.
2. Day 1: three things to ask your AI to do in your vault.
3. Day 3: what happens at 10 GB, and what AI-from-anywhere looks like.

**Warm-up (Dec 1–9), one idea each**
1. Dec 1: Your AI starts from zero every session.
2. Dec 2: Dumb storage, the "they don't" list.
3. Dec 3: Recorded demo, an agent filing and reusing real work.
4. Dec 4: Your Mac's disk is full and it's not your fault (iCloud cache story, your 40 GB lesson).
5. Dec 7: The live demo, named and teased: "AI from anywhere, live."
6. Dec 8: The founder price, the deadline, why it's locked.
7. Dec 9: Logistics. "Is there a replay?" Yes, minus the live demo.

**Event day (Dec 10):** 3 hours before, 1 hour before, "we're live," "the founder price is open" during the event.

**Close (Dec 11–13):** replay is up; FAQ answers; what founders are already doing; 24 hours left; 3 hours left; closed.

**After close (Dec 14+):** non-buyers stay free; their upgrade reason is the 10 GB limit and hosted MCP. The next push is the bonus release.

---

## 5. The live event (Thu Dec 10, YouTube Live, 90 minutes)

| Minutes | Segment |
|---|---|
| 0–10 | Dumb storage: why your AI forgets everything and your disk is full |
| 10–30 | Your own vault: 800,000 files, your skills, your AI working in it |
| 30–55 | **Live-only: AI from anywhere.** An agent on a cloud server and Claude on your phone both working in the same vault as your Mac, live. Cut from the replay |
| 55–70 | The founder offer: $49 → $29 locked, the deadline, guarantee |
| 70–90 | Q&A and close |
| After | Founders call (private link for buyers): onboarding, what's coming, Agency pitch |

Rehearse the live demo twice on a clean machine. It carries the whole launch.

---

## 6. Traffic: where the 2,500 signups come from

Use **list-builder** and **direct-response-copy**.
1. **Your own lists first:** email list, both Instagram accounts, the people you've worked with. Personal DMs to warm contacts convert best.
2. **Content, Dec 1–9:** daily short videos of the product doing something real (AI saving a file, a drive filling with no disk use, partitioning a drive). Use **simple-reels** for editing.
3. **AI builder communities** where you are already a member: Claude, Cursor, vibe-coding groups. Show, don't pitch.
4. **Paid ads (optional):** a small Meta campaign to the register page, plus retargeting of page visitors. Use **static-ads-machine** for concepts and **meta-machine** to run it. Set the daily budget once cost per signup is known.
5. **Affiliates (later):** Brunson's funnel takes `aff=` links. A 30% recurring commission for founders who refer others can wait until after launch.

---

## 7. Build checklist

### Product (must be done before Dec 1)
- [ ] **Fix the customer-separation bug** (`deploy/worker.js:218`: the customer ID is trusted without a signature check). Blocks every paid account.
- [ ] **One-click Connect Cloudflare**: today the user pastes account ID, two keys and a bucket name (`OnboardingView.swift`).
- [ ] Check whether Cloudflare asks free users for a card before storage turns on; design the screen around it.
- [ ] Turn on local MCP for free (`billing.js:47` has `mcp_token: false`).
- [ ] Studio Founders $29 as its own Stripe price; Studio $49; add-drive $25 and $40; Pro Max $97; Agency $497 and $297 annual.
- [ ] Hide Builder, Creator and BYOK Lifetime from public signup.
- [ ] Partition screen shows the real plan size. It falls back to "5.0 TB" when the size is missing (`add-drive-sheet.swift:110`).
- [ ] Free 10 GB → paid move tested end to end, no files lost, Finder path unchanged.
- [ ] Event registration saved with the account (so emails know who signed up).
- [ ] Three people who aren't you go from signup to their AI writing a file, alone, Mac and Windows. Fix what they get stuck on.

### Marketing (Nov 20–30)
- [ ] Register, founder, confirmation and replay pages.
- [ ] Register video and founder video.
- [ ] Recorded demo for email 3.
- [ ] All emails in sections 4 and 5, checked.
- [ ] YouTube Live event scheduled; founders call link.
- [ ] Tracking: Meta pixel, signup and purchase events.
- [ ] **claims-compliance-guard** on every page; **launch-readiness-preflight** before Dec 1.

---

## 8. Timeline

| Dates | Focus |
|---|---|
| Nov 10–16 | Customer-separation fix, one-click Connect Cloudflare, free MCP on, Stripe prices |
| Nov 12 | Watch Brunson's live event; file notes into the swipe |
| Nov 17–20 | Three outside testers; 10 GB → paid move test |
| Nov 20–26 | Pages, videos, emails written |
| Nov 27–30 | Black Friday week: no sends. Preflight, rehearse the demo, schedule everything |
| **Tue Dec 1** | Registration opens; warm-up and daily content start |
| **Thu Dec 10** | Live event + founders call |
| Dec 11–13 | Replay and close |
| Dec 14 | Founder price ends; Studio $49 |
| Dec 15–19 | Read the numbers; onboard founders; plan the bonus launch |

---

## 9. Numbers to watch

Signups per day by source · Cloudflare connect completion rate (where free users drop off) · live attendance · founder purchases live vs replay · refund requests in 30 days · average storage used per founder · request cost per user · Agency applications.

---

## 10. Claims to keep honest

- "8–9 figure entrepreneurs" needs named clients before it goes public. Maccs on file is about $1.02M (7 figures).
- Move-in: iCloud proven on Andrew's Macs only. Leave Dropbox and Google Drive out until tested.
- Cloud files need internet. Say it in the FAQ.
- "800,000 files" is from the Nov 6 vault count (797,000+). Recheck before the event.
