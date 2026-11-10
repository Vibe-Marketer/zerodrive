# Monopoly lens
Score: 4/10 | Vote: FUND IF

## What is strong
- A small market is nameable: people running AI agents across several machines (Mac, Windows, VPS). The Monopoly lens wants a small market owned first, and this is one.
- Agent-native features (hosted MCP, `zd` CLI, skill registry, VPS mount, fleet rendering) are the only parts that Dropbox, Google Drive, iCloud and the BYO-storage tools (Mountain Duck, CloudMounter, RcloneView) do not offer, per the owner's unverified competitor list. Studio, Studio Max and BYOK Lifetime hold up because they carry these features.
- Agency Partner is the only tier with a real switching cost and distribution: a white-label domain and sub-accounts mean each agency brings its own clients.
- Plain objects and $0 egress give the owner a pricing edge over LucidLink's per-TB model.

## What would kill it (the top 3, most dangerous first)
1. **No durable advantage a bigger player cannot copy.** An MCP server in front of R2 is a thin layer. Plain-object storage means users can leave easily, and a storage company (including Cloudflare) could ship MCP access quickly. The proof run (three renders, about 25 minutes versus an estimated 90+ serial, about 3.6x) comes from using four machines in parallel, not from the drive. It is one run by the owner, not 10x on something a buyer measured.
2. **The ladder undercuts its own differentiator.** Free Starter has the MCP token, skill registry and fleet rendering switched off, so it competes with free BYO tools on their terms. Builder ($19, 256 GB) sits next to Fabric Drive ($18, 250 GB), a pure price fight. BYOK Lifetime ($197 once, fleet features included, unlimited storage) undercuts Studio at $397/yr for any user who has a bucket, and it brings no recurring revenue.
3. **Distribution is unanswered.** No customers, no stated channel, and the $1M claim leans on 200 Agency partners. Check: 200 x $4,970 = $994,000, fine. But 1,700 Studio only reaches $1M at monthly billing (1,700 x $49 x 12 = $999,600). At the $397 annual price it takes about 2,519 (1,000,000 / 397).

Also noted: the margins figures check out at monthly price (Builder: 256 GB x 60% x $0.015 = $2.30, 87.9%), but on annual prices they fall (Studio Max annual is $74.75/mo, giving about 63% at 60% usage), before request and Stripe costs.

## The questions I would ask the founder
- What is the secret, in one sentence, that a storage company does not know?
- Who are the first 100 buyers, where do they gather, and what does each cost to reach? (/founder-consumer)
- Which one segment do you own first, and why does the ladder have seven tiers for it?
- Which competitors already ship MCP or agent access? (/founder-competitors)
- What are the R2 request and Worker costs per active user, and the margin after Stripe at annual prices? (/founder-cfo)
- What does a customer lose by leaving, since the files are plain objects?

## If FUND IF: the conditions
1. Pick one small market (agent fleets, or agencies) and sell only that. Cut or merge the tiers that compete on price alone (Builder, Creator).
2. Show 10 paying customers, or 100 waitlist sign-ups with a real price, before more building.
3. Build one thing a copycat cannot: switching cost or a network effect (shared skill registry, agency client base). Decide whether BYOK Lifetime stays given it undercuts Studio.
4. Run the CFO numbers at annual prices with request and Stripe costs; restate the $1M path.
5. Verify the competitor list independently.
