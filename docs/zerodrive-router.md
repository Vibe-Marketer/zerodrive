# ZeroDrive City Map & Collection Router (`ROUTER.md`)

**Location:** `~/ZeroDrive/My Drive/ROUTER.md`  
**Purpose:** Canonical routing system for human builders and AI agents (Claude Code, Cursor, Codex, Grok, Terminal agents).  
**Core Rule:** Do NOT scan or walk the entire drive. Check this table, jump directly to the target collection, and read that collection's `CONTEXT.md` or `STATUS.md`.

---

## 1. Top-Level Collection Routing Matrix

| If You Are Looking For... | Go To | Do NOT Go Here If... | Current Live Status |
| :--- | :--- | :--- | :--- |
| **Kallaway Course, Video Modules & Launch Transcripts** | [`Course/`](./Course) | You want general raw YouTube b-roll or personal recordings (use `_CONTENT/` or `_CAPTURES/`). | 10,311 files (32.85 GB) verified in R2 Vault. |
| **Primary System Operating Files, Obsidian Vault, Frameworks & Core Copy** | [`MAIN/`](./MAIN) | You are looking for client invoicing or legal contracts (use `_BUSINESS/`). | 33,960 files (74.38 GB) backed up via direct RAM stream. |
| **Active Businesses, Invoices, Clients, CRM, Financials (AISimple, Clickable, CallVault)** | [`_BUSINESS/`](./_BUSINESS) | You want public marketing videos or social content (use `_CONTENT/`). | Subfolders: `01-AISIMPLE`, `02-CLICKABLE`, `03-SUCCESS`, `04-CALLVAULT`, `05-PROMPT-COWBOY`. |
| **Video Production, Studio Recordings, Motion Library, B-Roll, Project Timelines** | [`_CONTENT/`](./_CONTENT) | You are looking for finished code repos or client deliverable tracking (use `_BUSINESS/` or local `_DEV/`). | Contains `creator-studio`, `motion-library`, `clickable-content-systems`. |
| **Raw Unedited Screen Recordings, Meeting Transcripts & Streams** | [`_CAPTURES/`](./_CAPTURES) | You want edited or published content assets (use `_CONTENT/`). | Raw intake folder (`00-INTAKE`). Files here stay unedited. |
| **Books, Marketing Swipe Files, Courses, Playbooks & Research Catalog** | [`_LIBRARY/`](./_LIBRARY) | You are searching for project-specific code or system automation scripts. | Contains master `CATALOG.csv` and research archives. |
| **Reusable AI Agent Skills, Prompt Toolkits, Branding & Naming Standards** | [`_SKILLS/`](./_SKILLS) | You want a one-off project script (use `_LAB` or the project repo). | Contains `_BRANDING`, `_NAMING`, `_PLUGINS`, `leadership`. |
| **Incoming Items Waiting to be Sorted, Classified, or Filtered** | [`_SORT/`](./_SORT) | You need stable, permanent production files. Never build on files in `_SORT`. | Staging buckets: `ALL-AUDITS`, `ALL-ENVS`, `ALL-HOOKS`, `ALL-LEADS`, `ALL-MCPS`. |
| **Old Read-Only Backups, Deprecated Snapshots, Historical Archives** | [`_ARCHIVE-VAULT/`](./_ARCHIVE-VAULT) | You are looking for current working documents. This is strictly read-only cold storage. | Contains archived `vault` and `vault-v2`. |
| **Video/Audio Retake Scraps & Disposable Render Proofs** | [`_Retakes/`](./_Retakes) | You need final deliverables. Items here can be purged at any time. | Scratch storage for video retakes. |
| **Legacy Evacuated Cloud Files from iCloud Drive Root** | [`CLOUD-MAIN/`](./CLOUD-MAIN) | You need current active desktop files (use `MAIN/`). | 14.34 GB cloud evacuation snapshot. |
| **RunItBack System Engine, Database, Session Logs & Model Weights** | [`.runitback/`](./.runitback) | You are doing regular human browsing or content editing. System daemon use only. | Houses `RunItBackDaemon.app`, `agent-sessions`, SQLite `db`. |

---

## 2. Agent Navigation Rules (Avoid Token Waste & Mount Stalls)

1. **NEVER run `du -sh` or recursive Unix file walks on the root:**
   - The vault holds 797,000+ files (>148 GB).
   - Running `du -sh` makes thousands of loopback network calls and stalls your context.
   - **Correct Agent Command:** Run `zd size [Folder]` (e.g. `zd size Course`) to get exact byte and file counts in <8 seconds via Cloudflare R2 metadata APIs.

2. **NEVER dump entire multi-thousand file directories into context:**
   - **Correct Agent Command:** Use `zd ls [Folder]` for level-1 inspection, or `zd tree [Folder] --depth 2` for hierarchy.
   - For file search, use `zd find "<pattern>" [Folder]`.

3. **NEVER read entire multi-megabyte files when you only need a snippet:**
   - **Correct Agent Command:** Use `zd cat <file> --lines 1-50` or `zd cat <file> --head 20`.
   - ZeroDrive streams the requested byte range directly from R2 without downloading the file to disk.

---

## 3. Quick Routing Lookup

- **Where do I find Andrew's headshots and bio?** $\rightarrow$ `MAIN/` (`Andrew Naegele Headshot B&W - Edited.png`).
- **Where are client invoices for AISimple?** $\rightarrow$ `_BUSINESS/01-AISIMPLE/WORK/invoice-systems/`.
- **Where is the Kallaway course transcript catalog?** $\rightarrow$ `Course/Kallaway-Short-Form-Launch/01-all-transcripts.md`.
- **Where do I drop incoming messy downloads?** $\rightarrow$ `_SORT/`.
- **Where do I save a reusable prompt skill?** $\rightarrow$ `_SKILLS/`.
