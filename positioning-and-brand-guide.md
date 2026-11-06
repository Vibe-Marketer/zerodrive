# ZeroDrive: Product Positioning & Brand Guide

Version 1.0 | November 3, 2026 | Strategic working brief

## 1. How to use this guide

This is the single working reference for ZeroDrive's product definition, positioning, audiences, messaging, and brand direction. Use it to brief a designer, copywriter, developer, or marketing partner. Future website, onboarding, launch, and sales materials should draw from this guide rather than invent separate product stories.

**Status:** The product intent and competitive discussion are grounded in Andrew's November 1–3 conversations and the saved specification. Persona priorities, messaging hierarchy, commercial packaging, and brand direction below are recommendations, not approved decisions or validated market findings. This document is not a production-readiness assessment.

Labels:
- **Established intent:** Supported by Andrew's stated goals or the product discussion.
- **Recommended:** The proposed default to adopt or revise.
- **Requires proof:** A product, performance, price, or competitive claim that must be verified before publishing as fact.

## 2. The product, clearly defined

### Customer explanation

ZeroDrive makes your cloud storage work like a drive on your Mac, so you can browse and use your files without downloading them in full or filling up your hard drive. Keep terabytes within reach, right in Finder, without carrying an external drive.

This is the intended product experience, not a claim that all workloads currently deliver it. In longer explanations, pair it with the limits below.

### Plain product definition

A native macOS app and menu-bar companion that connects cloud storage to Finder, streams requested file data on demand, and manages temporary local storage for new or changed files while they upload.

### What happens in practice

1. Install ZeroDrive and connect supported storage. The proposed commercial model offers managed ZeroDrive storage or bring-your-own storage.
2. Browse files through a familiar Finder drive. File and folder information can be loaded without downloading all file contents.
3. Open a cloud file. The intended streaming path retrieves the portions requested by the application rather than requiring a complete permanent local copy.
4. Save or add a file. Normal drive writes temporarily stage locally while uploading.
5. Reclaim that temporary local space after a successful upload. Show pending uploads and recovery state clearly.

The expanded specification also proposes bringing connected cloud accounts together under one Finder drive. Provider availability and behavior must be verified individually.

### What ZeroDrive is not

- Not an AI knowledge base, chatbot, or semantic-search product.
- Not primarily a new file manager. Real Finder remains central.
- Not a claim that a remote drive is equivalent to a local SSD for every application.
- Not an internet-free or zero-latency storage solution.
- Not a replacement for a backup strategy merely because files are stored in the cloud.
- Not a promise that active databases, applications, compiler caches, or dependency folders can move off the Mac without consequences.

### Physical limits that stay visible

Cloud-only files need internet access. Ordinary new or modified files use temporary local storage while uploading, potentially as large as the file being written. Opening speed depends on the connection, provider, file format, and application. Source files and working assets can be suitable even when active package installs, databases, and build directories are not.

## 3. The customer problem and value proposition

### The recognizable problem

“My Mac is running out of space, but moving files somewhere else usually means making them harder to use.”

People can buy cloud capacity yet still struggle with local caches, full-file downloads, external drives, and uncertainty about where files actually live. The target is the trade-off between freeing local space and keeping files conveniently usable.

### Core job to be done

“When my Mac is getting full, help me keep large files somewhere else while keeping them easy to find and use, without making me manage a technical storage system.”

### Value proposition

**Keep terabytes of files accessible on your Mac without filling its SSD, carrying external drives, or managing complicated cloud-storage tools.**

### Value hierarchy

1. **Practical result:** More room on the Mac while files remain within reach.
2. **Everyday convenience:** Familiar access through Finder and existing applications.
3. **Confidence:** Understand what is safely uploaded and what is still local.
4. **Control:** Choose supported storage and retain independently accessible files.
5. **Economic flexibility:** Expand cloud capacity rather than relying only on internal SSD upgrades. Actual savings depend on usage and pricing.

Do not sell abstract “cloud unification” before establishing why a person would care.

## 4. Positioning

### Recommended category

**Cloud-backed drive for Mac.**

Supporting descriptor: **On-demand cloud storage, right in Finder.**

Use “cloud streaming drive” in technical explanations. Avoid leading with “virtual filesystem,” “NFS,” “rclone wrapper,” or “cloud storage OS.” ZeroDrive's customer category is the experience it delivers, not its implementation.

### Recommended positioning statement

For Mac creators and independent professionals whose large files have outgrown their internal SSD, ZeroDrive is a cloud-backed drive that keeps files accessible through Finder without requiring a full local copy just to use them. It combines on-demand streaming, straightforward setup, and visible upload management with the choice of managed or bring-your-own storage.

### Competitive thesis

**The streaming experience of an enterprise drive, the simplicity of a consumer Mac app, and the affordability and ownership of ordinary cloud storage.**

This is the strategic combination discussed in the original chat. It is not a verified assertion that no competitor offers any overlapping combination.

### Brand promise

**More room on your Mac. Your files still within reach.**

### The point of view

Freeing space should not mean making your files inconvenient. Cloud capacity is only useful if people can comfortably use what they put there.

### The enemy

The trade-off between an empty local drive and an accessible working library. Criticize the trade-off, not customers or blanket categories of competitors.

## 5. Priority personas

These are behavioral hypotheses, not researched buyer profiles. Do not invent ages, income levels, market sizes, or purchasing statistics. A person may match multiple personas.

### Persona 1: The space-constrained independent creator

**Recommended initial priority: Primary.**

- Situation: Produces videos, recordings, design exports, or other large assets on a Mac. Older work remains useful but consumes space.
- Trigger: A large import/export fails, storage fills before a project, or another external drive becomes necessary.
- Desired outcome: Keep an accessible library without turning the Mac into its permanent storage location.
- Current workaround: Move folders between external SSDs, cloud folders, and local working folders; repeatedly delete caches.
- Main objection: “Will my files actually open when I need them, and are my uploads safe?”
- Message: “Keep your creative library within reach without keeping it all on your Mac.”
- Proof needed: A realistic large-file open/seek demonstration, visible local-space measurements, upload-state clarity, and recovery tests with relevant applications.
- Boundary: Do not promise every editing workflow works entirely in the cloud. Application behavior must be tested.

### Persona 2: The independent professional with a growing project library

**Recommended priority: Secondary, close to the primary audience.**

- Situation: A consultant, designer, agency owner, or solo founder keeps years of client deliverables and project assets on a Mac.
- Trigger: Needs an old project unexpectedly, cannot remember which disk holds it, or is reluctant to delete anything.
- Desired outcome: Keep an organized, reachable archive without becoming a storage administrator.
- Current workaround: Multiple external disks, web-based cloud downloads, and manual folder shuffling.
- Main objection: “Is this another system I have to learn or migrate everything into?”
- Message: “Keep past projects within reach, not permanently on your Mac.”
- Proof needed: Simple onboarding, Finder navigation, file retrieval, and a clear explanation of migration and storage ownership.
- Boundary: Team collaboration, client permissions, compliance, and shared editing are separate requirements, not implied capabilities.

### Persona 3: The storage-conscious developer or AI power user

**Recommended priority: Secondary and useful for technically informed early feedback.**

- Situation: Holds large datasets, model assets, media, archives, or reference libraries and is comfortable choosing a storage provider.
- Trigger: SSD pressure or frustration with command-line mounting and maintenance.
- Desired outcome: Use their own storage with a dependable Mac interface and fewer manual interventions.
- Current workaround: Raw rclone, scripts, object-storage dashboards, or basic mounting tools.
- Main objection: “Why pay for something I can assemble myself?”
- Message: “Your cloud storage, available in Finder. Less configuration and less babysitting.”
- Proof needed: Transparent architecture, exact credential handling, ordinary-file interoperability, lifecycle recovery, and supported workload documentation.
- Boundary: Do not target active node_modules, build caches, live databases, or all development directories as the use case. This is for appropriate large assets and libraries, not universally remote execution.

### Persona 4: The cloud-fragmented Mac user

**Recommended priority: Expansion angle, contingent on working integrations.**

- Situation: Files are spread across a personal cloud drive, another provider, and object storage.
- Trigger: Repeated downloads and switching between apps or browser tabs to find files.
- Desired outcome: Browse supported cloud accounts from one familiar drive.
- Main objection: “Does this copy or move everything? What happens to my existing accounts?”
- Message: “Your connected clouds, together in Finder.”
- Proof needed: A real multi-provider demonstration, clear account boundaries, accurate refresh behavior, and no misleading implication that all accounts are physically merged.
- Boundary: Only name providers confirmed to work. Connecting accounts does not imply deduplication, universal search of file contents, or automatic migration.

### Persona 5: The enterprise-tool user who wants individual-scale simplicity

**Recommended priority: Later, comparison-led acquisition.**

- Situation: Understands streaming storage but finds a current plan, workflow, or specialized storage format unsuitable for personal use.
- Trigger: A renewal, increasing capacity needs, or a desire to regain direct storage control.
- Desired outcome: Appropriate streaming functionality without unnecessary enterprise complexity.
- Main objection: “What capabilities, reliability, or collaboration do I lose?”
- Message: “A cloud-backed drive built around an individual Mac workflow.”
- Proof needed: A dated, exact feature and total-cost comparison with a clear migration path.
- Boundary: Do not imply equivalence with enterprise collaboration, support, security, or performance.

### Initial audience decision

Recommended first audience: **Independent Mac creators and professionals with large working libraries and limited internal storage.**

Do not launch as “storage for everyone.” Use developers as a distinct technical narrative, and multi-cloud organization as an expansion benefit rather than making both mandatory parts of the opening message.

## 6. Messaging angles

Angles are different entry points into the same product promise, not separate identities. The examples below are draft copy, not observed performance winners.

### Angle A: Your Mac is full, not obsolete

- Customer problem: A capable Mac feels constrained by storage.
- Draft hook: “Your Mac still works. It's just out of room.”
- Bridge: Keep appropriate large files in the cloud while accessing them through Finder.
- Best fit: Broad awareness among creators and independent professionals.
- Required proof: Before/after local-space demonstration after completed upload and cleanup.
- Avoid: Guaranteed hardware savings or implying all system data can be offloaded.

### Angle B: Cloud storage you can actually work from

- Customer problem: Files are in the cloud but using them still means downloading large copies.
- Draft hook: “Putting files in the cloud shouldn't mean downloading them all over again.”
- Bridge: Explain partial-data streaming with one concrete file example.
- Best fit: People already frustrated by cloud-drive behavior.
- Required proof: Actual bytes transferred and local storage used during a supported workflow.
- Avoid: Claiming every alternative always downloads every whole file.

### Angle C: Stop carrying your archive

- Customer problem: Work is scattered across external drives that must be present.
- Draft hook: “Your files shouldn't depend on which drive you brought.”
- Bridge: A reachable cloud-backed library through Finder.
- Best fit: Mobile creators and independent professionals with reliable connectivity.
- Required proof: Access from a normal working location and clear connectivity limits.
- Avoid: Implying internet-independent access or that external drives have no role.

### Angle D: Your storage. Your files. Your choice.

- Customer problem: Concern about lock-in and losing direct access to files.
- Draft hook: “Keep your files in your cloud, not trapped inside another app.”
- Bridge: Supported bring-your-own storage and ordinary accessible file objects.
- Best fit: Technical users and ownership-conscious buyers.
- Required proof: Retrieve a file with an independent tool, verify it, and explain credentials and exit behavior.
- Avoid: Claiming every competing format is proprietary or insecure.

### Angle E: Know what is safely uploaded

- Customer problem: Uncertainty about whether closing an app or laptop risks unfinished work.
- Draft hook: “Is that file in the cloud, or still only on your Mac?”
- Bridge: Visible pending uploads, clear local status, and guarded lifecycle actions.
- Best fit: Trust-building demos, onboarding, and conversion-stage materials.
- Required proof: Restart, disconnect, and pending-upload recovery tests.
- Avoid: “Impossible to lose a file” or absolute protection claims.

### Angle F: One familiar place for your clouds

- Customer problem: Files spread across cloud accounts and browser interfaces.
- Draft hook: “Different clouds. One place to browse them.”
- Bridge: Supported accounts appear as distinct folders in one Finder drive.
- Best fit: Integration-aware buyers after provider support is proven.
- Required proof: Working multi-account mount, refresh behavior, and clear source labels.
- Avoid: Suggesting a single storage pool, consolidated billing, or a sync engine unless implemented.

### Recommended messaging sequence

Lead with A or B. Explain the Finder experience. Establish confidence with E. Use D for differentiation and technical buyers. Introduce F only when it simplifies the explanation instead of increasing cognitive load.

## 7. Competitive positioning and evidence boundaries

The original AI Studio discussion grouped alternatives into enterprise streaming products, prosumer cloud mounters, and open-source engines. Preserve the useful distinctions without repeating its unsupported absolutes or prices.

### iCloud, Google Drive, Dropbox

Conversation thesis: Cloud capacity and visible filenames do not necessarily mean a file can be used without substantial local download/cache usage.

ZeroDrive distinction to demonstrate: Appropriate file use through on-demand reads with a deliberately limited local read footprint.

Verification required: Exact product version, mode, operating system, application, and file behavior. Do not claim all consumer cloud clients always hydrate every complete file.

### Mountain Duck and ExpanDrive

Conversation thesis: Cloud mounting itself is not novel. The opportunity is the particular combination of streaming behavior, temporary-write cleanup, upload-state visibility, and easy Mac operation.

Important nuance: The original chat acknowledged Mountain Duck has an online-only mode. “Competitors cannot stream” is not a defensible blanket message.

Verification required: Compare exact connection/cache modes and equivalent workflows. Do not publish speed, cache, or missing-feature accusations without testing.

### LucidLink, Suite Studios, and other streaming products

Conversation thesis: Individual-scale usability and storage freedom, with ordinary files in supported storage rather than reliance on a specialized block/chunk representation.

Verification required: Current individual/BYOS plans, actual storage formats and exit paths, costs, and collaboration differences. Do not use old chat pricing or imply performance equivalence.

### JuiceFS

Conversation thesis: A solo Mac user may not want to operate a metadata service or rely on a filesystem-specific chunk representation to recover normal files.

Verification required: Current supported metadata configurations, client setup, and actual operational burden. Do not claim a database server is universally mandatory or use corruption predictions as sales arguments.

### Raw rclone and GUI wrappers

Conversation thesis: The engine exists; ZeroDrive's product value is setup, supervision, visibility, safety controls, and daily usability.

Verification required: What current wrappers already provide and which ZeroDrive controls actually work. Be transparent about using open-source infrastructure.

### Moat: disciplined definition

**Differentiation thesis:** Streaming + familiar Mac usability + storage freedom + visible, dependable upload handling in one product.

**Potential defensibility:** Repeatedly demonstrated reliability across difficult real workflows, accumulated recovery/compatibility knowledge, excellent onboarding, support quality, and customer trust.

**Not yet established:** A proven durable moat, exclusive technology, network effects, switching-cost advantages, or a validated market with no comparable alternatives.

## 8. Brand foundation

### Brand essence

**Accessible space, without the storage chore.**

### Desired emotional outcome

Relief first: “I have room again.” Confidence second: “I know where my files are and can still use them.” Control third: “I am not trapped in another system.”

### Personality

- Calm, not breathless.
- Clear, not technical for its own sake.
- Capable, not magical.
- Honest about file state, not reassuring without evidence.
- Native and unobtrusive, not another destination demanding attention.

### Voice rules

1. Start with a recognizable problem or result.
2. Say “Mac,” “files,” “Finder,” “upload,” and “space” before implementation terminology.
3. Use concrete explanations: “Still uploading: 2 files” beats “Optimizing your cloud experience.”
4. Explain limits at the point they affect a decision.
5. Separate “saved locally” from “uploaded.” Never use “safe in the cloud” before confirmation.
6. Avoid inflated language: revolutionary, limitless, frictionless, zero lag, infinitely scalable, and guaranteed zero data loss.
7. Speak differently to beginners and technical buyers without changing the underlying truth.

### Naming architecture, recommended

- **ZeroDrive:** The product and application. Preserve this spelling and capitalization.
- **ZeroDrive Cloud:** Proposed managed-storage offering, only when commercially available.
- **Your cloud / Bring your own storage:** User-facing name for connecting existing compatible storage.
- **Vault:** Optional label for primary cloud storage, not a separate product or security claim.
- **Pending uploads:** Plain-language label for the temporary local write queue. “Spool” belongs in advanced settings.
- **Staging & Retakes:** Creator-specific workflow name; use a more general pending-upload label outside that context.

Do not call an offering “free,” “open-source,” or “open-core” until the actual license, distribution, entitlement, and pricing decisions support it.

### Meaning of “Zero”

The name expresses the goal of avoiding a permanent full local copy for supported cloud-file reads. It does not mean zero memory, zero network transfer, zero local bytes under every condition, zero cost, or zero waiting. Marketing must not let the name make a broader promise than the product can deliver.

## 9. Visual brand direction

This is a recommended design brief, not an approved logo or finished identity system.

- **Overall feel:** A calm, precise Mac utility. Prioritize legibility, visible file state, and useful space over decorative complexity.
- **Interface:** Familiar native hierarchy, restrained surfaces, clear connection labels, and distinct local/uploaded states.
- **Color:** Start with neutral light/dark surfaces and one restrained accent. Reserve warning/error colors for actual state. Do not assign final hex values before accessibility and identity review.
- **Typography:** Prefer a highly readable system-style sans serif with clear numerals for capacities and transfer status. Verify licensing for any public brand font.
- **Logo exploration:** A simple mark suggesting accessible storage or an open drive. Avoid relying solely on a generic cloud icon. Test recognizability at menu-bar and app-icon sizes.
- **Photography and graphics:** Show the Mac workflow and real files, not abstract server racks or AI imagery.
- **Motion:** Clarify progress and state transitions. Never suggest an upload has completed through decorative animation.
- **Trust cues:** Separate cloud capacity from local staging usage; show queued, uploading, completed, and failed states in text as well as color.

Still open: final logo, palette, font family, icon system, and trademark/domain clearance. Product naming is established for this project, not legally cleared by this brief.

## 10. Core message system and draft copy

### Recommended primary headline

**More room on your Mac. Your files still within reach.**

### Supporting copy

ZeroDrive makes your cloud storage work like a drive in Finder, streaming the file data you need instead of keeping a full local copy. Browse your library, open supported files, and let background uploads handle the move to the cloud.

### Short descriptor

**A cloud-backed drive for your Mac.**

### Supporting proof themes

- Familiar access through Finder.
- On-demand access to appropriate large files.
- Clear visibility into pending uploads and temporary local storage.
- Managed or bring-your-own storage, as available.
- Independently accessible files in supported cloud storage.

### Recommended tagline

**More room. Still within reach.**

The tagline is a recommendation for approval, not an established brand asset.

### Longer product introduction

Running out of space should not mean losing easy access to your files. ZeroDrive connects supported cloud storage to Finder so your large files can live in the cloud without becoming something you have to download in full every time you use them. It manages uploads and temporary local storage in the background, with clear status so you know what is uploaded and what is still on your Mac.

### Calls to action by actual availability

- Before public availability: “Join the waitlist,” only when a real signup path exists.
- Controlled testing: “Request early access,” only when requests can be fulfilled.
- Working public release: “Download for Mac,” only with a verified installer and setup path.
- Demo: “See how it works,” linked to a real demonstration.

Never imply immediate availability, trial storage, or supported integrations that are not actually available.

## 11. Objections and answer direction

**“Isn't this just Google Drive or Dropbox?”**

Those are possible storage providers. ZeroDrive's intended role is how you access supported storage on your Mac, including its streaming and temporary-local-storage behavior. Demonstrate the difference rather than dismissing other products.

**“Do I still need internet?”**

Yes, for cloud-only files that are not available locally. Do not imply offline access unless a specific offline feature exists and is tested.

**“Will it use any space on my Mac?”**

Yes. The app and metadata have a footprint, and normal new/changed files temporarily stage locally while uploading. The intended benefit is avoiding permanent full local copies of the cloud library and unnecessary read caching.

**“Can I edit straight from it?”**

That depends on the application, file type, and connection. Publish a tested workflow list rather than a universal yes.

**“What if I close the app while something uploads?”**

The design calls for clear pending-upload warnings and recovery behavior. Describe only the behavior verified in the shipping version; never promise recovery from every failure.

**“Are my files locked inside ZeroDrive?”**

The intended supported-storage model preserves ordinary files that can be retrieved independently. Explain the exact access and export path for the user's chosen storage mode.

**“Is it a backup?”**

Cloud access is not automatically backup. Explain deletion, retention, and versioning separately. Do not suggest a single cloud copy protects against every loss scenario.

**“Why not use rclone?”**

Technical users can. ZeroDrive's proposed value is packaging the suitable engine into an easier daily Mac workflow with configuration, visibility, lifecycle handling, and support.

**“How much does it cost?”**

Pricing is not established here. Compare total software, storage, operation, and transfer costs for a realistic usage scenario before claiming savings.

## 12. Commercial direction

The specification proposes two paths serving the same core promise:

- **Managed storage:** For buyers who want installation, sign-in, and usable storage without provisioning cloud infrastructure.
- **Bring-your-own storage:** For buyers who already have compatible storage or want direct provider control.

Recommended packaging principle: Keep one product story. Present the storage choice during setup or purchase, not as two unrelated product identities.

Unsettled: software licensing, recurring versus one-time charges, storage tiers, minimum fees, provider economics, support scope, trial conditions, refunds, open-source commitments, and data-retention/exit policies. No pricing or entitlement is locked by this guide.

## 13. Claims and proof checklist

Before turning strategic copy into public claims, verify the exact shipping version:

- **“Doesn't download the whole file”:** Trace representative reads, application requests, network transfer, and local disk usage. Some applications may request an entire file.
- **“Frees space”:** Measure total local usage, including original source files and staging, after upload and cleanup. Moving into a write queue alone does not prove space has been reclaimed.
- **“Instant”:** Replace with measured cold/warm latency and conditions, or use “on demand.” No sub-millisecond or sub-second promise from the chat is approved evidence.
- **“Safe uploads”:** Test disconnect, quit, sleep/wake, restart, interrupted transfers, and low-disk scenarios. Distinguish warning behavior from actual persistence and recovery.
- **“Normal cloud files”:** Retrieve with an independent tool and confirm content integrity.
- **“No security downgrade”:** Verify the actual shipped mounting dependencies and installation flow on supported macOS versions.
- **“Works with [provider]”:** Test real authorization, read/write behavior, refresh, and recovery for each named provider.
- **“Cheaper”:** Dated total-cost comparison for a specified capacity and workload, including fees and product differences.
- **“Private” or “secure”:** Exact credential, encryption, isolation, access, and data-handling evidence. No generic security guarantee from using a known provider.

Performance numbers in earlier specifications are proposed targets, not observed results. The presence of source files or an installer does not establish production readiness.

## 14. Validation plan

### Customer understanding

Show the one-sentence explanation to prospective users before presenting features. Ask them to explain what they expect to happen when opening, saving, and accessing files offline.

Recommended first-pass criterion: At least 4 of 5 relevant participants can explain the basic benefit and do not infer zero local space during uploads or universal offline access. This is a screening signal, not market validation.

### Problem and persona fit

Interview at least five people matching the primary persona. Ask about their last storage problem, current workaround, actual file sizes, applications, connectivity, spending, and reasons not to change. Do not ask only whether they “like” the concept.

Look for repeated current pain, specific workflow suitability, and willingness to try a real setup. Do not promote a persona based on hypothetical enthusiasm alone.

### Angle selection

Test A and B first with the same audience and equivalent exposure. Measure qualified demo/early-access requests and correctly understood expectations, not clicks alone. Small organic samples provide qualitative direction, not reliable conversion rankings.

### Product proof

Run a controlled real-file demonstration covering browse, read/seek, write/upload, cleanup, disconnect, and recovery. Record version, provider, connection, application, file size, elapsed time, local usage, and failures. Turn only verified results into proof assets.

## 15. Decision register

### Established intent

- Name: ZeroDrive.
- Mac-first product centered on convenient Finder access to cloud-backed files.
- Core customer benefit: retain useful access without keeping the entire file library locally.
- Competitive discussion: evaluate the combination of streaming, simplicity, storage freedom, and upload handling rather than treating mounting or streaming alone as novel.
- Expanded specification: desktop app plus menu-bar companion; managed and bring-your-own storage; supported external-cloud connections.

### Recommended defaults awaiting approval

- Primary audience: independent Mac creators and professionals with large libraries and constrained local storage.
- Category: cloud-backed drive for Mac.
- Leading promise: more local room while files remain within reach.
- Headline: “More room on your Mac. Your files still within reach.”
- Tagline: “More room. Still within reach.”
- Brand character: calm, clear, capable, native, and transparent.
- Lead angles: space pressure and usable cloud access; ownership and safety as supporting differentiation.

### Not locked

Final visual identity, legal clearance, pricing, licensing, release availability, exact provider list, performance claims, tested application compatibility, and a proven durable moat.

**Next decision:** Approve or revise the primary audience and message system as one package. Then develop visual identity and customer-facing assets from this guide, with proof gates applied before publication.

## 16. Sources and current-work checkpoint

### Direct project sources

- Project: `/Users/Naegele/_LAB/zerodrive`
- Repository: https://github.com/Vibe-Marketer/zerodrive
- Product metadata: `metadata.json`. Its “0 bytes” and “<1ms” language is existing project language, not accepted performance proof.
- Native app source directory observed: `ZeroDriveProject/Sources/`. Not audited here for shipping behavior.

### Strategy sources

- Saved AI Studio conversation: **MacOS Cloud Drive Build Plan**: https://aistudio.google.com/prompts/1TSCbCql-a66F_GfGm3n5wQLtvgBvVwP_
- November 2, approximately 1:03–1:11 PM: comparison with enterprise streaming tools, Mountain Duck/ExpanDrive, raw rclone, and JuiceFS; Andrew's question about the market gap.
- Captured discussion references: `e:erbna7yKe0nvR70y`, `e:MSQY2FCAH4KWxeI3`, `e:EHytpmzsRSQB1X3Y`.
- Later v3.0 specification in the same saved conversation: desktop app, menu-bar companion, managed/BYOK storage, and combined cloud accounts.
- November 3 conversation with Andrew: correction to focus on actual competing-product differences; confirmation that the recovered comparison matched the discussion; request for a customer-friendly product explanation and this consolidated positioning/brand guide.

### Evidence boundary

The original competitor assessments were generated by an AI model and are not independent competitive research. This guide preserves the strategic thesis, removes unsupported absolutes from recommended messaging, and flags verification requirements. It does not claim live feature completion, market uniqueness, customer demand, or performance validation.

### Checkpoint

Completed: Consolidated product intent, positioning, five persona hypotheses, six message angles, brand voice and visual direction, copy system, objections, commercial questions, proof requirements, and validation plan in this file.

No application code, deployment, pricing, or external account was changed. No final visual identity was selected. Next action is Andrew's approval or revision of the recommended audience and message system, followed by targeted proof and customer validation.
