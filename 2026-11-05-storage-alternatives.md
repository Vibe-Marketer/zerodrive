# ZeroDrive storage alternatives

Research checkpoint dated 2026-11-05. Read only investigation. No app configuration, deployment, account, credentials, provider or data was changed. This report is the task record because the current ZeroDrive project has no Context or Status file. Recommendations remain proposals.

## Decision

Keep ZeroDrive's macOS app, Finder integration, rclone, local NFS mount, write staging and read streaming. Replace the bytes provider behind primary_vault, not the drive system itself. The earlier e2 first recommendation is withdrawn following the requirements review below. B2 has documented core primitives but has not passed a live ZeroDrive test. IDrive e2 has unresolved naming and consistency questions. MEGA S4 has documented multipart deviations and requires its own rclone provider settings. None is approved as an equal speed replacement. R2 remains the straightforward option for unlimited direct download bandwidth.

At the current measured stored volume, do not switch to a capacity minimum plan merely to save money. B2 can reduce the storage component at this size but the absolute saving is small. At terabyte scale the alternatives become meaningful.

## What I inspected

Current working files in /Users/Naegele/_LAB/zerodrive, including Swift app Core and UI, Finder extension, build scripts, R2 Worker, deployment configuration and both migration scripts. Git HEAD was 9247824 with substantial uncommitted changes. The older /Users/Naegele/_LAB/everdrive is a separate specification, not the running implementation. The installed executable timestamp was November 5 at 15.21. That timestamp does not prove it matches every current source file.

The running app and bundled rclone were present. The bundled rclone reported v1.75.2 on arm64. A live mount existed at ~/.zerodrive-mount using local NFS. The active configuration used an S3 remote called primary_vault through https://zerodrive.aisimple.co/s3. ZeroDriveUnified was type combine with only My Drive mapped to primary_vault. This confirms a functioning storage path through the current endpoint, not that the local Worker source is the exact deployed revision.

A read only rclone size call against the configured personal vault namespace returned 30,859 objects and 54,262,409,621 bytes, approximately 54.26 decimal GB. This is not an account wide R2 bucket total. The stored metadata recorded a 5 TB allowance and 250 GB staging cap. Neither is actual storage consumption or demonstrated capacity enforcement.

Live VFS statistics showed zero cached write bytes, zero queued or active VFS uploads and zero errored cached files at observation. Live mount process statistics separately reported three retryable errors, with the last error a cancelled multipart initialization, and fatalError false. These are session counters, not a controlled throughput or reliability benchmark. No transfer daemon responded on port 55731 at the check. The Mac reported approximately 14 GiB available through df. No new data uploads or tests were started.

## How the current drive works

1. The native Swift app starts the bundled rclone against ZeroDriveUnified.
2. Rclone presents its remote through a loopback NFS server. macOS mounts that server locally. ~/ZeroDrive is a symlink into the hidden mount.
3. The combine remote exposes a My Drive folder whose content comes from primary_vault and its configured bucket and prefix.
4. Read only opens fetch cloud data in chunks rather than requiring the entire library locally. The current settings start at 8 MiB and grow to 128 MiB, with a 32 MiB per open file buffer. Boost mode requests larger chunks and buffers.
5. Writes through the mount are staged locally under ~/.zerodrive-cache. The write back delay is 15 seconds after last use and closure. The configuration uses writes mode, not full read caching. The configured read ahead flag should not be confused with persistent offline caching of every read.
6. Directory listings are cached for 9999 hours and the app preloads an in memory tree. This helps browsing but is not a cross device change notification system.
7. Finder services and app drop handlers also invoke direct rclone copy or move operations. Those are distinct from NFS write back. Direct transfers can avoid a second full staging copy but are not literally free of memory or local source requirements.
8. The supervisor has stale mount cleanup, sleep unmount and wake recovery logic. The UI polls local rclone remote control endpoints for progress. These implemented features are not a complete tested recovery guarantee.

Live storage means files remain cloud resident, can be listed, opened, read in ranges and written back through the mount without restoring an archive. It does not mean unlimited offline access, no local disk usage, simultaneous editing locks, instantaneous changes from other machines or that an unfinished upload can already be read from another machine. B2 Live Read is a separate optional provider capability and is not implemented merely by selecting B2 here.

Rclone documents that writes mode stages writes, while read only files are read directly. Repeated reopening and video seeking can therefore cause repeated downloads. Directory cache changes from another client may remain invisible until refreshed when the backend lacks polling support. Cache size is not a hard disk reservation or a hard limit for open dirty files. The local disk situation matters regardless of provider.

## Existing compatibility and gaps

MultiCloudCombineBuilder.swift already has R2, native B2 and AWS or generic S3 configuration paths. Generic S3 is the likely path for e2 and MEGA S4, with dedicated presets preferred for reliable provider defaults. B2 currently sets hard_delete false, so old versions can continue consuming billable storage. Version and lifecycle policy must be chosen deliberately.

The active combined namespace contains only My Drive. OAuth setup code exists for Google Drive, Dropbox and OneDrive, but current rebuild functions remove those named provider sections and generate a primary vault only namespace. Do not promise that switching the primary provider also preserves an active multi cloud mount that is not present now. Unrelated existing rclone remotes are not proof of inclusion.

No application level content encryption or Keychain credential lifecycle was found in the examined primary vault implementation. Local rclone config uses restrictive file permissions. Provider encryption at rest is a separate layer from client controlled encryption. Mac resource forks, extended attributes, timestamps, Unicode, case collisions and symlink representation all require explicit preservation tests. Current exclusion rules omit AppleDouble files.

## Prices and suitability

Prices were checked against official pages on November 5, 2026. Examples use a steady 5,000 decimal GB where possible, exclude taxes, control service costs and operation fees unless stated, and are estimates rather than actual billed balances. Provider unit conventions can differ.

### R2 Standard

Storage is USD 0.015 per GB month. Five decimal TB is about USD 75 monthly before the first 10 GB allowance. Standard has no minimum retention duration and direct egress is free. Class A and B request pricing and free allowances still apply. At the observed 54.26 GB, steady storage alone would be about USD 0.66 monthly after the storage allowance, assuming that allowance is available and the volume remains constant. Actual billing uses average daily peaks and may include other stored data.

### IDrive e2

Standard monthly pricing is USD 6 per TB with a USD 6 minimum. Five TB is USD 30 monthly. The standard five TB annual renewal is USD 297.50, equivalent to USD 24.79 monthly, prepaid. Twenty TB is USD 120 monthly or USD 1,190 yearly. Promotional first year and separate reseller offers are not the ongoing baseline.

No minimum retention duration. Ordinary API operations and ingress are free. Monthly download allowance is three times storage under its policy, then USD 0.01 per GB. Public pages use slightly different denominator wording, so the precise averaging and treatment of unused annual plan capacity needs written clarification before relying on it.

It documents S3 multipart operations, object copy, metadata, byte range capability and rclone support. Virginia is an available region. Use the actual account supplied endpoint rather than assuming one. Recommended first cost candidate, conditional on speed and recovery tests.

### Backblaze B2

Current standard storage is USD 6.95 per TB per 30 days, not the older USD 6 figure. Five TB is about USD 34.75 before its first 10 GB allowance. Twenty TB is USD 139 at the gross rate. No minimum storage volume, file size or retention duration fee. Ordinary Class A, B and C calls are free under the current pricing. Outbound event notifications are a separate class.

Free direct downloads are three times average monthly storage, measured in byte hours. Beyond this, USD 0.01 per GB. Approved partner routes can have different free egress treatment, but direct Mac downloads do not automatically qualify. US East is available and account region choice is not freely changeable afterward.

Native rclone B2 configuration already exists in ZeroDrive. S3 compatibility also exists. Neither native nor S3 has been tested as a replacement in this investigation. Use deliberate lifecycle rules because hard_delete false and retained versions can materially increase cost. Recommended comparison candidate with clearly documented average storage bandwidth accounting.

### MEGA S4

Pro Flexi starts at EUR 15 per month including three TB, then EUR 3.50 per additional TB. Five TB is EUR 22 monthly and twenty TB is EUR 74.50 monthly before tax. These are euros, not dollars. Smaller plans exist but are not priced in this report.

No API request charges or minimum storage duration. Included download traffic is five times stored data. Terms permit limits or extra charges after notification for excess usage. Thus this is not an unlimited bandwidth substitute for R2.

It documents S3 and rclone support, multipart, copy, metadata and range operations. Montreal endpoints provide a North American candidate. Regional endpoints use dynamic caches backed by global storage, so cold regional reads must be tested. Do not confuse ordinary MEGA cloud drive encryption claims with S4. S4 is not zero knowledge encrypted. For a managed product, check end user and takedown obligations, including the optional Service Provider Exception, separately from API compatibility.

### Wasabi

USD 7.99 per provider billed TB monthly, one TB minimum, 90 day minimum storage duration. Five billed TB is USD 39.95 before any timed deleted storage charges. Unit conventions must be normalized for exact comparisons. Overwriting or deleting early can keep the replaced bytes billable. Free egress is intended for downloads no greater than active stored volume monthly. Repeated excess can lead to limits or suspension. Poor first choice for an active, frequently overwritten drive. More appropriate for stable content when the traffic and retention conditions fit.

### Hetzner

Object Storage has a EUR 6.49 monthly base excluding VAT, with one TB storage and one TB egress included. Extra storage is EUR 0.0087 per TB hour and extra egress EUR 1 per TB. Objects below 64 KB are billed at 64 KB. Locations are Germany and Finland. Its own documentation warns against constantly modified real time processing workloads. Technically plausible through S3, but Europe only network distance and small object billing require testing. Not my first choice for this Mac workload.

Storage Box is a different product. It offers SFTP, WebDAV and other protocols, but files are not mirrored across servers. Using it would require a new backend path and changes to S3 specific transfer options and managed provisioning. A NAS or self hosted object server similarly changes uptime, network, backup and operational responsibility. These are not demonstrated equivalent substitutes merely because their disk space is cheap.

Storj Standard is USD 7 per TB storage plus USD 7 per TB downloaded, a USD 5 minimum, 50 KB minimum billable object size and generally 30 day minimum retention. Its special Object Mount exemption cannot simply be assumed for ZeroDrive's rclone mount. It may be attractive for some workloads, but its download costs and retention make it less compelling here than the leading candidates. Cold archive tiers fail the always accessible requirement. Existing consumer drive plans may reduce incremental spend but do not establish equivalent quotas, metadata, write or managed SaaS behavior.

## What can erase the savings

For a simplified steady five decimal TB library, ignoring free storage allowances and API differences, R2 costs USD 75 monthly. If downloads are twenty decimal TB monthly, B2 costs about USD 84.75 because five TB of downloads exceed its fifteen TB allowance. e2 monthly would cost about USD 80 under the same assumed allowance. e2 annual equivalent would be about USD 74.79, but needs prepayment and denominator confirmation. These are illustrations, not observed user traffic.

B2's approximate break even with R2 is 3.805 times stored volume downloaded per month. e2 monthly is approximately 3.9 times under the assumed steady storage allowance. Repeated previews, reopening files and video seeking count as network bytes, not just distinct files. Current session counters do not provide a reliable monthly read volume, and there is no controlled baseline for first byte latency or sustained read speed.

## Exact work required

### Personal drive

1. Freeze the reviewed source revision and record the installed version separately. Audit active import jobs and pending writes before touching primary_vault. Keep the present drive untouched while testing.
2. Add a separate candidate remote and test namespace with scoped credentials, correct provider, region, endpoint, path style and multipart defaults. Do not overwrite the live primary_vault during evaluation. Do not share VFS cache directories between two active mounts over overlapping remotes.
3. Remove fixed destination assumptions from both import scripts and audit provider specific flags. Obtain destination from validated metadata. Fix migration completion reporting and preserve durable per file failures and resume state.
4. Test LIST pagination, HEAD, ranged GET and seeking, PUT, multipart create/upload/complete/abort, copy, rename semantics, delete, Unicode, special characters, timestamps and symlink markers. S3 object copy plus deletion is not an atomic directory rename. Do not compare multipart ETags as if they were universally whole file MD5 hashes.
5. Run identical cold and warm Finder listings, Quick Look, video start, random seek, sustained reads, small file writes and large file writes on R2 and each candidate from the same Mac and network. Include concurrent reads and uploads, high object counts and provider throttling. Record median and tail latency, throughput, errors, RAM, cache bytes and downloaded bytes.
6. Test offline interruption, mid upload crash, sleep and wake, machine restart, disk pressure, quota failure, expired credentials and external changes. Use dedicated disposable data. Current lack of a complete durable app transfer queue must not be mistaken for guaranteed recovery.
7. Copy the current namespace through its configured remote into the target. The Worker prepends a hidden tenant root, so raw R2 object keys and mounted logical paths differ. Inventory and map them explicitly. Preserve any actual metadata and historical versions that exist. Do not delete source objects.
8. Compare object counts, sizes, logical paths and content hashes or readback verification. A full download verification also consumes target egress. Pause writers for a final incremental reconciliation. Safely drain pending writes, switch primary_vault and its bucket prefix, rebuild the combined remote, refresh caches and remount at the same user facing path.
9. Verify Finder and app behavior after cutover. Keep R2 for rollback. Once target writes begin, rollback must copy those new changes back or preserve them separately before repointing. Keep a single authoritative writer during the transition. Retire old data only under separate explicit approval.

### Managed ZeroDrive product

The current Worker directly calls an R2 binding. It cannot change to e2 or B2 by replacing a URL. Keep Cloudflare for DNS, installer hosting and lightweight control services if useful, while the desktop transfers bytes directly to the chosen provider using scoped credentials. Cloudflare infrastructure does not have to be abandoned to stop paying R2 storage rates.

Generalize provisioning response and stored metadata to identify provider, endpoint, region, bucket, prefix, credential expiry and actual allowance. Provision genuinely isolated buckets or enforced prefixes. Do not distribute unrestricted master keys to customers. Make quota, billing, credential rotation and abuse controls real server side checks rather than UI labels. Confirm resale and managed end user terms for the actual provider contract.

If retaining a byte proxy is required, implement a provider specific authenticated adapter that preserves range requests, multipart streaming, metadata, status codes and cancellation. Measure added latency, bandwidth and request costs. Do not buffer large files in Worker memory or assume partner free egress eligibility.

Source security issue needing review before expanding the managed service exists in deploy/worker.js. extractTenantFromAuth parses the caller supplied Credential field without verifying AWS Signature V4 and falls back to default_tenant. Provisioning lacks visible license verification and can return shared provider credentials when configured. These are source findings, not a claim of tested public exploitation or exact live deployment. No anonymous reads, cross tenant access or exploit tests were attempted. Correct authentication and isolation regardless of the eventual storage provider.

## Proof and remaining boundaries

Verified live items are the app process, rclone version, local NFS mount, safe active backend configuration, VFS counters and a read only namespace size. Source review establishes implementation, not complete live behavior. Public pricing and API documentation establish published terms, not provider performance from this Mac. No new provider account was connected or purchased, no synthetic upload benchmark was run, and no data was moved or removed.

The exact managed product engineering duration cannot be responsibly estimated from endpoint compatibility alone. Personal backend configuration is a small integration change, verified migration is separate work, and managed multi customer provisioning and security is a larger change. Migration time depends on measured throughput and object count. Five decimal TB at a sustained 100 Mbps takes about 111 hours one way before verification and overhead. That is an illustration, not measured available bandwidth.

Next useful action is a disposable side by side trial of e2 Virginia and B2 US East, with MEGA S4 Montreal as a third candidate if larger library pricing is the priority. Use an existing approved account if available. A new paid account or data movement is not authorized by this research request. Final choice depends on measured speed, monthly bytes downloaded, desired personal versus managed product scope and a safe cutover test.

## Implementation evidence

[Backend configuration](ZeroDriveProject/Sources/Core/MultiCloudCombineBuilder.swift) at lines 6 to 22, 55 to 150 and 340 to 374.

[Mount and caching](ZeroDriveProject/Sources/Core/RcloneDaemonSupervisor.swift) at lines 109 to 243 and 282 to 328.

[Direct upload and transfer state](ZeroDriveProject/Sources/Core/SpoolAndGuardManager.swift) at lines 119 to 180 and 232 to 290.

[Remote control client](ZeroDriveProject/Sources/Core/RcloneRCClient.swift) and [vault statistics](ZeroDriveProject/Sources/Core/VaultStats.swift).

[Managed Worker](deploy/worker.js) at lines 31 to 39, 60 to 320 and 387 to 418.

[Provisioning client](ZeroDriveProject/Sources/Core/DFYProvisioningClient.swift) at lines 16 to 49 and 69 to 81.

[Migration manager](ZeroDriveProject/Sources/Core/TurboMigrationManager.swift) at lines 138 to 159 and [import script](turbo-migrate-dashboard.py) at lines 140 to 210 and 253 to 305.

Reviewed SHA256 values are 9dd85788e227ba0e81b8e42782593f6a7bda97d87530d61dfdac41016c05aa0d for MultiCloudCombineBuilder.swift, bed267927c2f4b593f36ec79f45d8f7c43904b68cfc3086affe830e915bd172a for RcloneDaemonSupervisor.swift, 2fd57713b469e12d758b1a5b67f1d2f43a80e057f504f256ff02fe4591eba740 for TurboMigrationManager.swift and 9405703a246234bd2c7d850e9e69c9453995df85f2b532a08024c5a0c4911e49 for worker.js. Later edits require renewed review.

## Official sources

[R2 pricing](https://developers.cloudflare.com/r2/pricing/)

[IDrive e2 pricing](https://www.idrive.com/s3-storage-e2/pricing) and [pricing policy](https://www.idrive.com/s3-storage-e2/faq-pricing)

[IDrive e2 rclone](https://www.idrive.com/s3-storage-e2/rclone) and [API](https://www.idrive.com/s3-storage-e2/s3-compatible-api)

[B2 pricing](https://www.backblaze.com/cloud-storage/pricing) and [2026 price change](https://backblaze.com/blog/backblaze-pricing-and-product-updates)

[B2 API](https://www.backblaze.com/docs/cloud-storage-s3-compatible-api) and [regions](https://www.backblaze.com/docs/cloud-storage-data-regions)

[MEGA S4 pricing](https://mega.io/objectstorage), [terms](https://mega.io/terms#S4), [API](https://github.com/meganz/s4-specs) and [regional cache behavior](https://help.mega.io/megas4/setup-guides/mega-s4-endpoint-urls)

[Wasabi policy](https://wasabi.com/pricing/faq)

[Hetzner Object Storage](https://www.hetzner.com/storage/object-storage/) and [limitations](https://docs.hetzner.com/storage/object-storage/faq/general/)

[Hetzner Storage Box](https://www.hetzner.com/storage/storage-box/)

[Storj pricing](https://www.storj.io/pricing)

[rclone NFS and VFS semantics](https://rclone.org/commands/rclone_serve_nfs/)


## Requirements review after Andrew rejected compatibility guesses

Updated November 5 following Andrew's request to establish what the system needs and whether providers can deliver. This section supersedes the earlier candidate ordering. Price does not decide capability. A documented API is evidence of support, not proof of correct behavior through the installed app. An uptime commitment is not a file opening speed guarantee.

### Actual demand measured

At 15.37 ET the configured vault returned 30,876 objects and 58,367,452,446 bytes. The largest object was exactly 2 GiB. There were 23,781 objects below 64 KiB, approximately 77 percent of the object count. Median object size was 14,266 bytes. There were 625 symlink marker objects and 89 non ASCII logical paths. This is a small object heavy workload by count, not merely video storage.

At 15.39 ET a separate name compatibility listing returned 30,881 objects. It found 36 logical paths over 254 characters, a longest logical path of 339 characters, and a longest basename of 157 characters. No observed path contained Unicode codepoints above U+FFFF. These are separate observations while data was changing, not an immutable migration inventory. No filenames or credential values are reproduced here. Counts are for the logical configured namespace, not the entire provider account.

Twenty GB files come from the earlier product scope. They are a future size requirement, not a measured current maximum. Test current largest files first and any proposed larger product maximum separately.

### What the provider must actually do

1. List every object and nested folder prefix across pages. Return consistent sizes, names and stat information. Current object count exceeds a single 1000 item S3 listing page.
2. Read the beginning, middle and end of a file without fetching all of it. The mount asks for 8 MiB chunks growing to 128 MiB and buffers 32 MiB per open file. The provider must deliver correct ranges and support repeated seeking under simultaneous uploads.
3. Accept small writes and multipart large writes, preserving verified bytes. Mount managed S3 configuration uses 25 MiB parts with eight parts in parallel. Direct import uses 16 MiB parts with four parts per file and up to eight separate file processes. These are concurrency settings, not requests per second. Their peak demand must be measured rather than equated to a provider rate cap.
4. Allow interrupted part requests and retries without reporting uncommitted content as safely uploaded. VFS restart recovery and in process HTTP retries are separate from crash restart reuse of multipart parts.
5. Copy, overwrite, rename and remove files with a known failure boundary. S3 rename normally means copy then delete. Neither it nor a folder rename is atomic. Large file copy may need ranged multipart copy. Symlink markers, original modification time and character encoding must round trip.
6. Keep the same app facing mount path, active root and workflow controls. The bytes provider changes behind primary_vault. Correct provider options are part of compatibility, not optional speed tuning.
7. For managed service only, enforce customer permissions and quota, rotate credentials and meet the applicable resale and end user terms. Displaying five TB in metadata is not quota enforcement.

A provider cannot repair client side staleness caused by 9999 hour directory caching. A storage save becomes remotely durable only after closure, the write back delay and successful upload. These are existing boundaries that must be preserved honestly or separately improved.

### Backblaze B2 findings

Documented core capability is supported. Its native API explicitly supports single byte ranges with 206 for partial content. A full object range can return 200. Rclone operates above this raw response behavior, but a custom client requiring 206 for `bytes=0-` is directed by Backblaze to the S3 API.

Native multipart objects support the current two GiB object and the separately proposed twenty GB size. Parts are documented from five MB to five GB with up to 10,000 parts, and large files up to ten TB. Native copy beyond five GB uses b2_copy_part. Rclone's B2 backend documents multipart server copy, with a four GiB default copy cutoff. Copy within an account is supported, not arbitrary cross account native copy.

B2 file names are UTF8 with a 1024 byte limit and exclusions for control characters. Current logical names fit the length limit. Native modification time is stored in milliseconds in `X-Bz-Info-src_last_modified_millis`. Exact original nanosecond timestamp equality with S3 metadata should not be promised. Hard delete false retains versions and hides removed files. Provider versioning cannot be disabled, and lifecycle cleanup changes billable historical storage.

The current rate limit page says all new accounts start at 500 requests per second for upload and download operations. It does not establish a universal cap for every API or every existing account. Native responses may return 429, S3 may return 503 SlowDown and `Retry-After`. Higher limits need review. Older marketing saying no throttling does not supersede this explicit rate limit.

B2 documents immediate availability after confirmed upload, but the inspected evidence is not an exhaustive formal specification of current concurrent GET, LIST, overwrite and delete semantics. In process retries exist in current upstream rclone B2 source. That source was not established as byte identical to the installed executable, and restart reuse of uploaded multipart parts is not established.

The standard B2 networking documentation explicitly makes performance depend on network path, selected region, object mix and client concurrency. The 100 Gbps to one Tbps designated resource tiers belong to B2 Overdrive, not ordinary standard pricing. Do not borrow those promises for this comparison.

The current SLA is a 99.9 percent monthly uptime objective with five or ten percent credits at its stated bands, not a guaranteed playback bitrate, first frame time or seek latency. Current AUP requires written permission for resale. Its broad wording about archives and active user devices also needs product scope clarification because B2 separately advertises application hosting. Do not assume a reseller agreement or reinterpret that clause without confirmation. Performance evaluation for a competitor or publication also has authorization language that must be considered for a commercial ZeroDrive evaluation.

Verdict is documented support for the core access mechanism with identified configuration and contract work. Equal performance and full installed app compatibility remain untested. This is not an approved replacement.

### IDrive e2 findings

Published limits cover the current object size and count. The API lists multipart operations, pagination, metadata and object copy. It advertises `Accept-Ranges` bytes, but the inspected API reference does not explicitly specify the required 206 and `Content-Range` response behavior. Ranged multipart copy is listed but its crucial copy source range header is not specified. Those omissions are unknowns, not evidence of failure.

One official FAQ says object names cannot exceed 254 characters. Another specifies a 1024 maximum. The 254 statement appears in console upload instructions. Whether it applies only to console names, basenames or full API keys is not resolved. Thirty six current logical paths exceed 254, while every observed basename is shorter. Therefore neither a failure nor full compatibility can be inferred. The provider must clarify the exact API rule and the actual paths must pass a scoped round trip.

The bucket FAQ documents an imprecisely named Unicode UTF32 restriction and mentions emoji. Current paths include non ASCII characters but no codepoints above U+FFFF. This inventory does not prove the existing names are rejected. It also does not authorize changing names to fit a provider. Future allowed Mac names remain a product requirement.

The correct rclone provider is IDrive, not generic Other. Scoped bucket keys require no_check_bucket according to its integration guide. Default encrypted buckets can need the documented server side encryption option to avoid MD5 errors. Configuration and checksum validation must be tested together rather than disabling integrity checks to make a trial pass.

The access key FAQ permits up to 1000 concurrent HTTP connections. The API documents 429 rate limiting but no numeric requests per second commitment was found. Connections are not a throughput guarantee. No explicit read after write, overwrite, delete and LIST consistency contract was found in the inspected official references.

The SLA explicitly governs availability only, at 99.9 percent, and excludes certain performance delays. The published performance benchmark warns that it is synthetic and from one client path. It is not evidence of this Mac's Finder or editing performance. Ordinary terms prohibit platform resale while a reseller program permits it under its own arrangement.

Verdict is hold. Capacity appears sufficient on paper, but naming contradictions, range copy details, consistency and permission scope remain unresolved. The previous e2 first recommendation was premature and is withdrawn.

### MEGA S4 findings

Official rclone guidance and installed rclone help both identify a dedicated Mega provider. The exact rclone v1.75.2 provider source sets path style, URL encoded listings, different multipart ETag handling and a near unlimited copy cutoff. ZeroDrive's generic Other branch does not select those Mega defaults. An endpoint swap is not the documented integration.

The official S4 API documents ranged GET and 206. It also documents departures from AWS multipart behavior. Reuploading an already uploaded part is not allowed and can abort an upload. Nonfinal parts must have equal size. UploadPartCopy is described as full object copies only, although its table also marks a copy source range header supported. The dedicated rclone copy setting is further evidence that ordinary multipart copy assumptions must not be reused. Actual interrupted request recovery must be demonstrated with the installed client, not assumed from the S3 label.

MEGA publishes 40 to 50 upload requests per second per account, a practical small object rate around 42 to 45 objects per second in its rclone guide, and approximate support for twenty million objects per account. This current vault's count is below that published guidance. It is not proof that small object import speed matches R2. Do not convert upload request limits into download throughput guarantees.

Regional endpoint documentation describes dynamic local caches and potentially higher first access latency in a new region. No formal object consistency model or fixed per client seek latency commitment was established in the inspected sources. A promotional page claims 99.9 percent uptime SLA, but full service credit terms were not located, so that claim is not treated as an inspected contractual remedy.

Verdict is adaptation and recovery proof required. It is not cleared as a drop in endpoint replacement. No provider trial was run.

### Exact implementation changes before a trial or switch

The candidate trial uses an independent test remote and namespace without touching primary_vault. Preserve the same rclone binary, mount options and test files when comparing backends. Isolate cache directories and ports for candidate mounts. Do not remount the live drive merely to test a vendor.

MultiCloudCombineBuilder needs explicit provider presets for IDrive and Mega with their documented settings. Native B2 needs deliberate version lifecycle and metadata precision choices. Credentials must be scoped to disposable test storage. Direct upload options must be chosen by backend, since S3 flags do not tune native B2 in the same way.

Both import scripts must obtain their destination from validated configuration rather than fixed personal bucket paths. Keep the present source removing behavior out of provider migration. For migration use copy, content verification, a recorded delta, a single writer cutover and rollback that preserves any writes made after switching.

For managed service, DFYProvisioningClient and the provisioner must return and persist actual provider, region and credential scope. The current R2 binding cannot be redirected by a URL change. A direct desktop to provider data path avoids introducing another byte proxy, but it must use proper customer isolation rather than distributing master keys. Quota and credentials need real enforcement. The current Worker signature verification gap remains a separate required correction.

### Acceptance and remaining blocked proof

Use the current file mix, including at least one listing beyond 1000 objects, tiny files, observed long and non ASCII paths, symlink markers and the current largest object. Add the separately intended larger file ceiling only as an explicit product scope test. Verify complete content, original metadata representation, overwrite visibility, ranged seeks, copy and deletion ordering.

Exercise current mount reads while uploads run, and current import concurrency separately. Record first byte and first frame time, seek completion, small object completion rate, sustained bandwidth, request rate, retries, CPU, RAM and local staging. Compare distributions against R2 on the same Mac and network. Do not invent a success threshold or claim byte identical timings from fluctuating networks. The user asks to retain current speed, so a controlled measured baseline and agreed acceptable variation are needed before acceptance.

Inject interruption of a request, multipart completion, local client process and network path using disposable data within authorized normal integration tests, not provider vulnerability testing. Confirm there is no silent success, content corruption or source loss. Verify wake, restart and low disk recovery without risking the active vault.

[blocked] No alternative has passed this authenticated end to end test. Candidate scoped credentials and any necessary trial or commercial evaluation authorization are needed. Provider clarification is also needed for the specific unresolved contract and API questions above. No provider was contacted, no account was created or purchased, and no candidate data writes or deletions occurred. Public research and current workload inspection are complete. Actual delivery remains unproven where marked unknown.

### Primary sources added in this review

[B2 rate limits](https://www.backblaze.com/docs/cloud-storage-rate-limits)

[B2 range behavior](https://www.backblaze.com/apidocs/b2-download-file-by-id)

[B2 large files](https://www.backblaze.com/docs/cloud-storage-large-files) and [native copy](https://www.backblaze.com/apidocs/b2-copy-file)

[rclone native B2](https://rclone.org/b2/)

[B2 standard versus Overdrive](https://www.backblaze.com/docs/cloud-storage-design-a-network-for-high-throughput-access-to-backblaze-b2)

[B2 current SLA](https://www.backblaze.com/company/policy/sla) and [AUP](https://www.backblaze.com/company/policy/acceptable-use-policy)

[IDrive object naming](https://www.idrive.com/s3-storage-e2/faq-objects), [API limits](https://www.idrive.com/s3-storage-e2/faq-account-management) and [Unicode note](https://www.idrive.com/s3-storage-e2/faq-buckets#unicode)

[IDrive exact rclone settings](https://www.idrive.com/s3-storage-e2/rclone), [API](https://www.idrive.com/s3-storage-e2/s3-compatible-api) and [connection limit](https://www.idrive.com/s3-storage-e2/faq-access-keys)

[IDrive SLA](https://www.idrive.com/s3-storage-e2/service-level-agreement), [terms](https://www.idrive.com/s3-storage-e2/terms), [reseller](https://www.idrive.com/s3-storage-e2/faq-reseller) and [benchmark limitations](https://www.idrive.com/s3-storage-e2/e2-performance-stats)

[MEGA official integration guide](https://help.mega.io/megas4/setup-guides/rclone-setup-guide-for-mega-s4), [rate guidance](https://help.mega.io/megas4/setup-guides/mega-s4-rate-limits-and-performance-guidance) and [API deviations](https://github.com/meganz/s4-specs)

[Exact rclone v1.75.2 Mega defaults](https://github.com/rclone/rclone/blob/v1.75.2/backend/s3/provider/Mega.yaml)

[R2 explicit consistency baseline](https://developers.cloudflare.com/r2/reference/consistency/) and [size limits](https://developers.cloudflare.com/r2/platform/limits/)


## Amazon S3 and additional alternatives

Follow up on November 5. This expands the shortlist rather than treating the earlier three companies as exhaustive. No provider account was opened and no storage was switched.

### Amazon S3 Standard

S3 is Amazon's actual object storage service. S3 compatible means another company's implementation of its interface, not storage hosted by Amazon. ZeroDrive already has an AWS S3 configuration branch. A personal direct S3 trial can use this branch with a real region and scoped credentials. Existing Finder and rclone infrastructure can remain. Managed provisioning and migration safety still require the changes described above.

AWS explicitly documents strong read after write, overwrite, delete and listing consistency. It documents ranged GET and multipart copy for objects beyond five GB. The performance guide states at least 3500 PUT/COPY/POST/DELETE and 5500 GET/HEAD requests per second per partitioned prefix with gradual scaling and possible 503 SlowDown responses during ramp up. This is stronger and more detailed evidence for the access mechanism than a generic compatibility claim, but not a promise of latency on this Mac.

S3 Standard is not a lower cost R2 replacement at public list rates. AWS's calculator assumptions state USD 0.023 per billed GB for the initial storage tier. AWS defines that billed GB as 2^30 bytes. Internet downloads are charged after the shared first 100 GB monthly allowance. The commonly published US East first paid tier is USD 0.09 per GB. Request charges are additional.

For an illustrative identical five trillion byte library, stored steadily, AWS Standard storage is approximately USD 107.10 per month while R2 gross storage is USD 75. One additional trillion bytes downloaded monthly would add approximately USD 74.82 at the initial AWS internet transfer tier, assuming the shared free allowance is entirely available. Thus the illustrative AWS total becomes approximately USD 181.92 before request charges. These are calculated examples, not invoices, measured monthly usage or price quotes.

The earlier loose five TB examples did not consistently normalize provider units. This section normalizes actual byte count. Taxes, credits, request charges, version history and other services remain excluded. R2's available storage allowance reduces its gross number slightly.

Cheaper AWS classes are not interchangeable with Standard. Infrequent Access and Glacier Instant Retrieval can serve data promptly but add retrieval costs, minimum billable object sizes and retention obligations. Flexible Retrieval and Deep Archive require restore steps and do not retain direct always accessible behavior. Express One Zone uses directory buckets, has different endpoints and availability zone scope, and is not a cheaper simple endpoint substitute. Intelligent Tiering needs its actual small object and archive tier rules checked rather than assuming every file gets cheaper.

### OVHcloud Standard US

This is a material new cheaper candidate. The US price list states USD 0.00001111 per GiB hour, approximately USD 0.0081103 per GiB month at 730 hours. It lists free API calls and incoming and outgoing traffic. The US product page explicitly says no egress fees from January 1, 2026. At the same five trillion byte library, the illustrative 730 hour storage cost is USD 37.77 monthly, compared with R2 gross USD 75.

US documentation identifies Vint Hill in Virginia and Hillsboro in Oregon as regular regions. The io endpoint defaults to Standard. The older perf endpoint defaults to High Performance, so selecting the wrong endpoint can put uploads into the more expensive class. High Performance on the US list is approximately USD 0.0202794 per GiB month, roughly USD 94.43 for this same library, no longer a storage saving versus R2.

The official US performance guide explicitly supports byte range reads with typical eight or sixteen MB chunks and independent retransmission of failed multipart parts. It provides rclone multipart configuration examples. These match real ZeroDrive requirements, unlike merely recognizing the S3 label. The US compatibility matrix lists regular region CopyObject, HEAD, LIST v2 and multipart lifecycle support. Local Zones do not support CopyObject in that matrix. Therefore a nearby Local Zone must not be substituted for a regular region and called equivalent without addressing its copy behavior.

OVH documents one Gbps maximum per connection, not a reserved minimum. Its FAQ says bandwidth is shared and not guaranteed. The optimization guide warns about 503 SlowDown while internal object metadata shards rebalance. Small object performance, first byte latency, full consistency rules, large ranged multipart copy details, customer isolation and commercial terms remain validation items. The low Standard tier is HDD based according to product descriptions, whereas High Performance uses NVMe. Do not assume Standard will match R2 speed or that paying for High Performance preserves savings.

Verdict is serious candidate for the same requirements test, not approved replacement. Published pricing and core operation evidence are sufficient to warrant evaluation. They are not measured equivalence.

### Other screened options

Tigris Standard has free egress and USD 0.02 per GiB month, plus request charges. Its measured unit is binary GB. The same five trillion byte library would be about USD 93.13 gross monthly before its free allowance. Thus it is not a cheaper Standard storage option than R2, although its free egress and global access design could suit other priorities. Cheaper Tigris tiers add retrieval and retention charges, and its Archive tier needs restoration. No full ZeroDrive capability review was performed because Standard fails the basic lower storage price screen.

DigitalOcean Spaces Standard includes 250 GiB storage and 1024 GiB outbound traffic for USD 5 monthly. Additional storage is USD 0.02 per GiB and outbound transfer USD 0.01 per GiB. The same library would be about USD 93.13 storage monthly before extra bandwidth. It is not a cheaper Standard storage choice at this scale. Cold tier savings come with minimum size, retention and retrieval conditions and require a different workload calculation.

Vultr Standard advertises USD 18 monthly for one TB storage and one TB transfer, then USD 18 per additional TB stored and USD 10 per additional TB transferred. Its advertised storage rate is not below R2's approximately USD 15 per decimal TB and it adds transfer charges beyond allowance. Exact unit normalization and a full capability audit were not pursued because it is not an apparent cost winner for the requested use case.

### Decision and remaining proof

Amazon S3 belongs on the technically documented list but not the lower cost Standard list. OVHcloud regular region Standard belongs on the cheaper candidate list alongside previously researched B2 and other conditional candidates. Tigris, DigitalOcean and Vultr Standard do not beat R2's storage price at the examined five TB scale. No additional provider has passed the authenticated ZeroDrive behavior, recovery and speed tests. Pricing alone does not establish delivery.

For an OVH trial use the exact US regular region io endpoint, Standard class, correct region signing, a disposable scoped bucket and the same installed rclone and mount settings. Verify range reads, interruption recovery, metadata, names, symlinks, copy and rename, paging and external change visibility. Keep local zone and high performance configurations separate so neither silently substitutes for the cheap tier under evaluation. The existing migration and managed service changes remain necessary.

### Sources for this expansion

[AWS S3 consistency](https://aws.amazon.com/s3/consistency)

[AWS S3 request scaling](https://docs.aws.amazon.com/AmazonS3/latest/userguide/optimizing-performance.html)

[AWS GetObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_GetObject.html) and [CopyObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_CopyObject.html)

[AWS pricing and unit definitions](https://aws.amazon.com/s3/pricing/), [calculator assumptions](https://aws.amazon.com/calculator/calculator-assumptions/) and [independent current rate crosscheck](https://upstash.com/blog/aws-s3-pricing-explained-2026)

[OVH US prices](https://us.ovhcloud.com/public-cloud/prices/), [US product terms displayed](https://us.ovhcloud.com/public-cloud/object-storage/), [US endpoints](https://support.us.ovhcloud.com/hc/en-us/articles/10667991081107-Object-Storage-Endpoints-and-geoavailability), [US ranged reads and multipart retries](https://support.us.ovhcloud.com/hc/en-us/articles/27885987068179-Object-Storage-Optimizing-performance), [US supported operations](https://support.us.ovhcloud.com/hc/en-us/articles/4603831309715) and [shared bandwidth FAQ](https://docs.ovhcloud.com/en/guides/storage-and-backup/object-storage/s3-faq)

[Tigris pricing](https://www.tigrisdata.com/pricing/), [DigitalOcean Spaces pricing](https://docs.digitalocean.com/products/spaces/details/pricing/) and [Vultr pricing](https://www.vultr.com/products/object-storage)
