# Board summary: ZeroDrive offer ladder and pricing

Memos: [offers](board/offers.md), [monopoly](board/monopoly.md), [product](board/product.md). Brief: [brief](board/brief.md).

## The vote

**3 FUND IF, 0 fund, 0 pass. Average score 4.7 out of 10** (Offers 5, Monopoly 4, Product 5).

The board backs the product and wants the ladder cut down and tested with real buyers before more is built. No member said pass.

## Risks raised by more than one member (most shared first)

1. **The free tier hides the product (all three).** Free has the MCP token, skill registry and fleet rendering switched off, so a free user gets what looks like a 10 GB Mountain Duck. The agent-fleet hook only appears at $19 or $49.
2. **BYOK Lifetime ($197 once) undercuts Studio (all three).** It includes fleet rendering, the skill registry and unlimited slots, so any buyer who can make a bucket has no reason to pay $397 a year. It also brings no recurring revenue.
3. **The lifetime copy names AWS and B2, but only R2 is decided and B2 has not passed a live test (all three).**
4. **No evidence of demand (all three).** No paying customers, no named channel for the first 100 buyers, no guarantee. The proof is one owner-run render test, and the 90+ minute serial time is an estimate. The Monopoly lens adds that the speed-up comes from using four machines, not from the drive.
5. **Too many tiers and limits (all three, different cuts).** Seven tiers and three limits (storage, vaults, slots) on a product whose headline is agents and fleets. Creator sits between $19 and $49 with no fleet feature; Studio Max is Studio with more storage.
6. **Unit economics are not finished (all three).** Margins reproduce for storage alone. They are lower on annual prices and unmodeled for request costs, Worker costs and Stripe fees. At 60% storage use, annual margins are about 71% for Builder and about 63% for Studio Max. At full use they are about 52% and 38%.
7. **The $1M claim (Offers and Monopoly).** 200 Agency x $4,970 = $994k. 1,700 Studio reaches $1M only at monthly billing; at the $397 annual price it takes about 2,520.

## Where the board disagrees

| Tier | Offers | Monopoly | Product |
|---|---|---|---|
| Builder $19 | keep | cut: a price fight with Fabric Drive | keep |
| Creator $29 | cut for now | cut | fold into the gap |
| Studio $49 | keep, strongest | keep | keep |
| Studio Max $99 | keep | not addressed | make it extra storage on Studio |
| Agency $497 | hold until buyers ask | strongest: only real switching cost and distribution | keep |
| $297 Agency BYOK | not yet | not addressed | do not build until an agency asks |

The sharpest disagreement is Agency. The Offers lens sees an unproven tier with no demand evidence; the Monopoly lens sees the only tier where customers bring their own customers.

## Conditions (checklist for the rest of the pack)

- [ ] Reprice or limit BYOK Lifetime so it cannot undercut Studio: drop fleet rendering and the registry, or charge at least 12 months of Studio. Remove AWS and B2 from the copy until each passes a live test. (`/founder-pricing`, `/founder-cfo`)
- [ ] Cut the ladder to about three or four paid tiers. Candidates: Builder, Studio, Agency, with Studio Max as extra storage. Show buyers two limits (storage, machines), not three. (`/founder-consumer`, `/founder-pricing`)
- [ ] Give free users a limited MCP token and the VPS slot so they can see an agent use the drive, if the Worker cost is tolerable. (`/founder-cfo`)
- [ ] Name tiers by outcome (machines, agents, jobs), not gigabytes, and add a guarantee that has been costed. (`/founder-offer`, `/founder-cfo`)
- [ ] Pick one small market to own first, agent fleets or agencies, and say the secret in one sentence. (`/founder-competitors`, `/founder-consumer`)
- [ ] Get real evidence before more building: 10 paying customers, or 100 waitlist sign-ups at a real price. Have three non-owners finish setup unaided. (`/founder-launch`)
- [ ] Run the numbers at annual prices with R2 request costs, Worker costs and Stripe fees, and restate the $1M path. (`/founder-cfo`)
- [ ] Confirm that competitor prices are current and find out who already ships MCP or agent access. (`/founder-competitors`)
- [ ] Check the unconfirmed seams: free-to-hosted migration, Cloudflare account setup for free users, and the Worker serving an agency-owned bucket at hosted speed.
- [ ] Do not build the $297 Agency BYOK until a real agency asks for it.

## The strongest version the board can see

A product for people who run agents across several machines, sold on that one outcome and not on gigabytes. A free tier that lets someone watch an agent on a VPS use their Mac's files in the first few minutes. One clear hero tier, Studio at about $49, where the fleet features begin. Builder as the entry step and Agency as the white-label tier for the buyers who bring clients, with extra storage sold as an add-on instead of more tiers. BYOK Lifetime kept only as a capped, limited founder offer. Launched on real pre-sales rather than on a finished ladder. This is narrower than the seven-tier ladder pitched: it trades breadth for one claim a buyer can test in five minutes.
