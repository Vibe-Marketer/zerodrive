import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct StorageAdvisorView: View {
    @ObservedObject private var advisor = ManageStorageAdvisor.shared
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor

    @State private var showConfirmMoveSheet: Bool = false
    @State private var showConfirmCloudMoveSheet: Bool = false
    @State private var showAgentOrganizeSheet: Bool = false
    @State private var inspectedBucket: StorageBucketKind = .movableUserFiles
    @State private var destinationFolder: String = "Cold Storage"
    @State private var cloudDestinationFolder: String = "Cloud Imports"
    @State private var preserveFolderStructure: Bool = true
    @State private var copiedPromptFeedback: String = ""

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            modeSwitcherHeader

            if advisor.mode == .localMac {
                localMacBody
            } else {
                cloudSourcesBody
            }
        }
        .confirmationDialog(
            "Move \(ByteCountFormatter.string(fromByteCount: advisor.selectedBytes, countStyle: .file)) to ZeroDrive & Free Mac SSD?",
            isPresented: $showConfirmMoveSheet,
            titleVisibility: .visible
        ) {
            Button("Move to ZeroDrive & Free Space", role: .destructive) {
                Task {
                    await advisor.transferSelected(
                        mode: .moveAndReclaim,
                        destinationSubfolder: destinationFolder,
                        preserveFolderStructure: preserveFolderStructure
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("ZeroDrive will upload \(advisor.selectedCount) files directly to your vault, verify each file's exact size in cloud storage, and only then delete the local SSD copies.")
        }
        .confirmationDialog(
            "Move \(ByteCountFormatter.string(fromByteCount: advisor.selectedCloudBytes, countStyle: .file)) from Cloud to ZeroDrive?",
            isPresented: $showConfirmCloudMoveSheet,
            titleVisibility: .visible
        ) {
            Button("Move to ZeroDrive", role: .destructive) {
                Task {
                    await advisor.transferCloudSelected(
                        isCopy: false,
                        destinationSubfolder: cloudDestinationFolder
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will transfer \(advisor.selectedCloudCount) selected cloud item(s) to My Drive/\(cloudDestinationFolder) and remove them from the source cloud after verification.")
        }
        .sheet(isPresented: $showAgentOrganizeSheet) {
            agentOrganizeSheet
        }
        .onAppear {
            if advisor.items.isEmpty && !advisor.isScanning {
                advisor.startScan()
            }
        }
    }

    // MARK: - Top Mode Switcher Header

    private var modeSwitcherHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: advisor.mode == .localMac ? "internaldrive.fill" : "icloud.and.arrow.down.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Storage Advisor & Cloud Importer")
                    .font(.headline)
                Text(advisor.mode == .localMac
                    ? "Shows real physical Mac SSD space vs. locked system storage — cloud-only ghosts are excluded."
                    : "Browse iCloud & connected cloud drives without downloading to SSD — copy, organize, or move to ZeroDrive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Mode", selection: $advisor.mode) {
                ForEach(AdvisorSourceMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            .onChange(of: advisor.mode) { newMode in
                if newMode == .cloudSources && advisor.cloudItems.isEmpty && !advisor.isCloudScanning {
                    advisor.startCloudScan()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    // MARK: - MODE 1: SEARCH YOUR MAC (LOCAL SSD)

    private var localMacBody: some View {
        Form {
            // 1. Mac SSD Storage Map + Scan Controls
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text("Mac SSD Breakdown")
                                    .font(.title3.bold())
                                if let custom = advisor.customScanRootURL {
                                    Text("Scope: ~/\(custom.lastPathComponent)")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.14))
                                        .foregroundStyle(Color.accentColor)
                                        .clipShape(Capsule())
                                }
                            }
                            Text(advisor.statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if advisor.customScanRootURL != nil {
                            Button("All Mac Folders") {
                                inspectedBucket = .movableUserFiles
                                advisor.setCustomScanRoot(nil)
                            }
                            .controlSize(.small)
                            .disabled(advisor.isScanning || advisor.isReclaiming)
                        }

                        Button {
                            pickCustomLocalFolder()
                        } label: {
                            Label("Scan Custom Folder…", systemImage: "folder.badge.questionmark")
                        }
                        .controlSize(.regular)
                        .disabled(advisor.isScanning || advisor.isReclaiming)

                        Button {
                            advisor.startScan()
                        } label: {
                            Label(advisor.isScanning ? "Scanning…" : "Scan Mac SSD", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(advisor.isScanning || advisor.isReclaiming)
                    }

                    if advisor.isScanning {
                        ProgressView(value: max(0.1, advisor.scanProgress))
                            .progressViewStyle(.linear)
                    } else if advisor.isReclaiming {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text(advisor.statusMessage)
                                .font(.caption.bold())
                                .foregroundStyle(Color.accentColor)
                            Spacer()
                            Button("Stop") {
                                advisor.cancelTransfer()
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                        }
                    }

                    // Full-width 5-segment proportional SSD bar
                    macSSDStorageBar

                    // 4 Interactive Storage Bucket Cards
                    let bd = advisor.diskBreakdown
                    HStack(spacing: 10) {
                        bucketCard(
                            title: "MOVABLE TO ZERODRIVE",
                            value: fmtBytes(advisor.totalReclaimableBytes),
                            subtitle: "\(advisor.items.count) files • \(fmtBytes(advisor.selectedBytes)) selected",
                            color: Color.accentColor,
                            isSelected: inspectedBucket == .movableUserFiles
                        ) {
                            inspectedBucket = .movableUserFiles
                        }

                        bucketCard(
                            title: "DEV CACHES & TEMP",
                            value: bd.isDeepAuditComplete ? fmtBytes(bd.devCachesAndTempBytes) : "Auditing…",
                            subtitle: "node_modules, builds, Caches & $TMPDIR",
                            color: .orange,
                            isSelected: inspectedBucket == .devCachesAndTemp
                        ) {
                            inspectedBucket = .devCachesAndTemp
                        }

                        bucketCard(
                            title: "APP DATABASES & RECORDERS",
                            value: bd.isDeepAuditComplete ? fmtBytes(bd.appDatabasesAndAgentsBytes) : "Auditing…",
                            subtitle: "~/.aside, Docker, ~/.gemini, ~/.runitback, Claude",
                            color: .purple,
                            isSelected: inspectedBucket == .appDatabasesAndAgents
                        ) {
                            inspectedBucket = .appDatabasesAndAgents
                        }

                        bucketCard(
                            title: "LOCKED MACOS & APPS",
                            value: bd.isDeepAuditComplete ? fmtBytes(bd.lockedSystemAndAppsBytes) : "Auditing…",
                            subtitle: "macOS OS, Swap, /Applications & Apple TCC",
                            color: .secondary,
                            isSelected: inspectedBucket == .lockedSystemAndApps
                        ) {
                            inspectedBucket = .lockedSystemAndApps
                        }
                    }

                    // Excluded Cloud Ghosts Banner
                    if advisor.diskBreakdown.cloudGhostCount > 0 {
                        HStack(spacing: 10) {
                            Image(systemName: "icloud.slash.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Excluded \(fmtBytes(advisor.diskBreakdown.cloudGhostLogicalBytes)) in \(advisor.diskBreakdown.cloudGhostCount) cloud-only ghost files (0 KB on Mac SSD)")
                                    .font(.caption.bold())
                                Text("Those files live in iCloud/CloudStorage and take zero disk space here. Use Search Your Cloud to copy or organize them without filling your SSD.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Browse in Search Cloud →") {
                                advisor.mode = .cloudSources
                                if advisor.cloudItems.isEmpty && !advisor.isCloudScanning {
                                    advisor.startCloudScan()
                                }
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.vertical, 4)
            }

            if inspectedBucket != .movableUserFiles {
                bucketInspectorSection(for: inspectedBucket)
            } else {
                // 2. "From Where" Folder Chips + "What It Is" Filters
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        if !advisor.folderSummaries.isEmpty {
                            HStack(spacing: 6) {
                                Text("FROM WHERE:")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.secondary)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        folderChip(
                                            title: "All Folders",
                                            sizeText: fmtBytes(advisor.totalReclaimableBytes),
                                            isActive: advisor.selectedFolderFilter == nil
                                        ) {
                                            advisor.selectedFolderFilter = nil
                                        }

                                        ForEach(advisor.folderSummaries) { summary in
                                            folderChip(
                                                title: summary.folderName,
                                                sizeText: summary.formattedSize,
                                                isActive: advisor.selectedFolderFilter == summary.folderName
                                            ) {
                                                advisor.selectedFolderFilter = (advisor.selectedFolderFilter == summary.folderName) ? nil : summary.folderName
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        HStack(spacing: 10) {
                            Picker("What It Is", selection: $advisor.selectedFilter) {
                                ForEach(StorageAdvisorCategory.allCases) { cat in
                                    Text(cat.rawValue).tag(cat)
                                }
                            }
                            .pickerStyle(.segmented)

                            TextField("Filter name or path…", text: $advisor.searchQuery)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 170)

                            Button("Select Shown") {
                                advisor.selectAll(filterOnly: true)
                            }
                            .controlSize(.small)

                            Button("Deselect All") {
                                advisor.deselectAll()
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }

                // 3. Movable Supported Files List
                Section {
                    let visibleItems = advisor.filteredItems
                    if advisor.items.isEmpty && !advisor.isScanning {
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.green)
                            Text("No Large Movable Files Found")
                                .font(.headline)
                            Text("All movable files >= 5 MB are already cleared, or click the category cards above to inspect Dev Caches, App Databases, or macOS System storage.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 440)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    } else if visibleItems.isEmpty {
                        Text("No movable files match the current folder/category filter.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    } else {
                        List {
                            ForEach(visibleItems) { item in
                                localItemRow(item: item)
                            }
                        }
                        .frame(minHeight: 260, maxHeight: 380)
                    }
                }

                // 4. Bottom Action Bar (Move vs Copy)
                if advisor.selectedBytes > 0 {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                Text("Destination in ZeroDrive:")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)

                                TextField("Cold Storage", text: $destinationFolder)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 180)

                                Menu("Presets") {
                                    Button("Cold Storage") { destinationFolder = "Cold Storage" }
                                    Button("Mac Offload") { destinationFolder = "Mac Offload" }
                                    Button("Media Vault") { destinationFolder = "Media Vault" }
                                    Button("Archives") { destinationFolder = "Archives" }
                                }
                                .controlSize(.small)

                                Toggle("Keep source folder structure", isOn: $preserveFolderStructure)
                                    .font(.caption)

                                Spacer()
                            }

                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Ready to Transfer \(fmtBytes(advisor.selectedBytes)) (\(advisor.selectedCount) files)")
                                        .font(.subheadline.bold())
                                    Text("Streams directly to My Drive/\(destinationFolder.isEmpty ? "Cold Storage" : destinationFolder) with 0 B local cache bloat and remote size verification.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button {
                                    Task {
                                        await advisor.transferSelected(
                                            mode: .copyKeepLocal,
                                            destinationSubfolder: destinationFolder,
                                            preserveFolderStructure: preserveFolderStructure
                                        )
                                    }
                                } label: {
                                    Label("Copy to ZeroDrive", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                                .disabled(advisor.isReclaiming || advisor.isScanning)

                                Button {
                                    showConfirmMoveSheet = true
                                } label: {
                                    Label("Move & Reclaim \(fmtBytes(advisor.selectedBytes))", systemImage: "arrow.up.circle.fill")
                                        .padding(.horizontal, 6)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .disabled(advisor.isReclaiming || advisor.isScanning)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var macSSDStorageBar: some View {
        let bd = advisor.diskBreakdown
        let total = max(Double(bd.volumeTotalBytes), 1.0)
        let lockedBytes = bd.isDeepAuditComplete ? bd.lockedSystemAndAppsBytes : bd.nonMovableProtectedBytes
        let lockedFrac = max(0.0, Double(lockedBytes) / total)
        let appFrac = max(0.0, Double(bd.appDatabasesAndAgentsBytes) / total)
        let devFrac = max(0.0, Double(bd.devCachesAndTempBytes) / total)
        let movableFrac = max(0.0, Double(bd.movableBytes) / total)
        let freeFrac = max(0.0, Double(bd.availableImportantBytes) / total)
        let projectedFree = bd.availableImportantBytes + advisor.selectedBytes

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Macintosh HD (\(fmtBytes(bd.volumeTotalBytes)))")
                    .font(.caption.bold())
                if advisor.isAnalyzingSystemStorage {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Auditing caches & apps…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if advisor.selectedBytes > 0 {
                    Text("Free Space After Move: \(fmtBytes(bd.availableImportantBytes)) → \(fmtBytes(projectedFree))")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.green)
                } else {
                    Text("\(fmtBytes(bd.availableImportantBytes)) Available (\(fmtBytes(bd.availableRawBytes)) raw + \(fmtBytes(bd.purgeableBytes)) macOS purgeable)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { geo in
                HStack(spacing: 1) {
                    if lockedFrac > 0 {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: max(4, geo.size.width * lockedFrac))
                    }
                    if appFrac > 0 {
                        Rectangle()
                            .fill(Color.purple.opacity(0.75))
                            .frame(width: max(3, geo.size.width * appFrac))
                    }
                    if devFrac > 0 {
                        Rectangle()
                            .fill(Color.orange.opacity(0.8))
                            .frame(width: max(3, geo.size.width * devFrac))
                    }
                    if movableFrac > 0 {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: max(4, geo.size.width * movableFrac))
                    }
                    if freeFrac > 0 {
                        Rectangle()
                            .fill(Color.green.opacity(0.28))
                            .frame(maxWidth: .infinity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            }
            .frame(height: 16)

            HStack(spacing: 12) {
                legendDot(color: Color.accentColor, label: "Movable: \(fmtBytes(bd.movableBytes))", locked: false)
                if bd.isDeepAuditComplete {
                    legendDot(color: .orange.opacity(0.85), label: "Dev Caches & Temp: \(fmtBytes(bd.devCachesAndTempBytes))", locked: false)
                    legendDot(color: .purple.opacity(0.8), label: "App DBs & Recorders: \(fmtBytes(bd.appDatabasesAndAgentsBytes))", locked: false)
                }
                legendDot(color: Color.secondary.opacity(0.55), label: "Locked macOS & Apps: \(fmtBytes(lockedBytes))", locked: true)
                legendDot(color: Color.green.opacity(0.55), label: "Available: \(fmtBytes(bd.availableImportantBytes))", locked: false)
            }
            .font(.caption2)

            Text("Click any card below to inspect exact folders. Only safe user files move to ZeroDrive; Dev Caches, App Databases & Apple OS stay intact unless you drill in manually.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func bucketInspectorSection(for bucket: StorageBucketKind) -> some View {
        let entries = advisor.diskBreakdown.bucketEntries.filter { $0.bucket == bucket }
        let bucketTotal: Int64 = {
            switch bucket {
            case .movableUserFiles: return advisor.totalReclaimableBytes
            case .devCachesAndTemp: return advisor.diskBreakdown.devCachesAndTempBytes
            case .appDatabasesAndAgents: return advisor.diskBreakdown.appDatabasesAndAgentsBytes
            case .lockedSystemAndApps: return advisor.diskBreakdown.lockedSystemAndAppsBytes
            }
        }()
        let bucketDescription: String = {
            switch bucket {
            case .movableUserFiles:
                return ""
            case .devCachesAndTemp:
                return "These are build artifacts, package stores, and temp caches (node_modules, .git objects, ~/Library/Caches, $TMPDIR). They should be pruned with dev tools or revealed in Finder rather than uploaded to your Cloud Vault."
            case .appDatabasesAndAgents:
                return "Active databases, Docker VM images, AI transcripts (~/.aside, ~/.gemini), and continuous screen recorders (~/.runitback). Moving live SQLite/DB files while apps run can corrupt them."
            case .lockedSystemAndApps:
                return "Cryptographically sealed macOS system volumes, VM swap, /Applications bundles, /opt Homebrew, and SIP/TCC-protected Apple containers (Messages, Mail, Photos)."
            }
        }()

        return Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        inspectedBucket = .movableUserFiles
                    } label: {
                        Label("Back to Movable Files", systemImage: "chevron.left")
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(bucket.rawValue) (\(fmtBytes(bucketTotal)))")
                            .font(.headline)
                        Text(bucketDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if bucket == .lockedSystemAndApps {
                        Button("Open macOS Storage Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }

                if advisor.isAnalyzingSystemStorage && entries.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Measuring directories in background…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 16)
                } else if entries.isEmpty {
                    Text("No entries recorded in this category yet. Run Scan Mac SSD to refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    List {
                        ForEach(entries) { entry in
                            HStack(spacing: 12) {
                                Image(systemName: entry.path.isEmpty ? "internaldrive.fill" : "folder.fill")
                                    .font(.title3)
                                    .foregroundStyle(bucket == .devCachesAndTemp ? Color.orange : (bucket == .appDatabasesAndAgents ? Color.purple : Color.secondary))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.label)
                                        .font(.body.weight(.medium))
                                        .lineLimit(1)
                                    Text(entry.note)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }

                                Spacer()

                                Text(entry.formattedSize)
                                    .font(.subheadline.bold().monospacedDigit())

                                if let scanTarget = entry.scanTargetFolderPath {
                                    Button("Scan Media Folder…") {
                                        inspectedBucket = .movableUserFiles
                                        advisor.setCustomScanRoot(URL(fileURLWithPath: scanTarget))
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)
                                    .help("Pause the recorder app before moving old video archives")
                                }

                                if !entry.path.isEmpty {
                                    Button {
                                        NSWorkspace.shared.selectFile(entry.path, inFileViewerRootedAtPath: "")
                                    } label: {
                                        Image(systemName: "magnifyingglass")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Reveal in Finder")
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .frame(minHeight: 240, maxHeight: 380)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - MODE 2: SEARCH YOUR CLOUD (CLOUD -> ZERODRIVE)

    private var cloudSourcesBody: some View {
        Form {
            // 1. Connect / Login & Direct Stream Bar
            Section("Connected Clouds & Login") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            advisor.launchDirectICloudStream()
                        } label: {
                            Label("Stream iCloud Direct (0 Disk)…", systemImage: "bolt.icloud.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button {
                            Task { await advisor.connectExternalCloud(.googleDrive) }
                        } label: {
                            Label(advisor.isConnectingProvider == ExternalCloudProvider.googleDrive.rawValue ? "Connecting…" : "Connect Google Drive", systemImage: "externaldrive.connected.to.line.below")
                        }
                        .controlSize(.small)
                        .disabled(advisor.isConnectingProvider != nil)

                        Button {
                            Task { await advisor.connectExternalCloud(.dropbox) }
                        } label: {
                            Label(advisor.isConnectingProvider == ExternalCloudProvider.dropbox.rawValue ? "Connecting…" : "Connect Dropbox", systemImage: "shippingbox.fill")
                        }
                        .controlSize(.small)
                        .disabled(advisor.isConnectingProvider != nil)

                        Button {
                            Task { await advisor.connectExternalCloud(.oneDrive) }
                        } label: {
                            Label(advisor.isConnectingProvider == ExternalCloudProvider.oneDrive.rawValue ? "Connecting…" : "Connect OneDrive", systemImage: "cloud.fill")
                        }
                        .controlSize(.small)
                        .disabled(advisor.isConnectingProvider != nil)

                        Spacer()

                        Button {
                            advisor.startCloudScan()
                        } label: {
                            Label(advisor.isCloudScanning ? "Scanning…" : "Rescan Clouds", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .disabled(advisor.isCloudScanning)
                    }

                    Text(advisor.cloudStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !advisor.cloudProviders.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                folderChip(
                                    title: "All Clouds",
                                    sizeText: fmtBytes(advisor.totalCloudLogicalBytes),
                                    isActive: advisor.selectedCloudProviderFilter == nil
                                ) {
                                    advisor.selectedCloudProviderFilter = nil
                                }

                                ForEach(advisor.cloudProviders) { p in
                                    folderChip(
                                        title: "\(p.label) (\(p.itemCount))",
                                        sizeText: p.formattedSize,
                                        isActive: advisor.selectedCloudProviderFilter == p.id
                                    ) {
                                        advisor.selectedCloudProviderFilter = (advisor.selectedCloudProviderFilter == p.id) ? nil : p.id
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // 2. Cloud Search & Duplicate Controls
            Section {
                HStack(spacing: 10) {
                    TextField("Search cloud files or folders…", text: $advisor.cloudSearchQuery)
                        .textFieldStyle(.roundedBorder)

                    Toggle("Hide exact-size duplicates (\(advisor.duplicateCloudCount))", isOn: $advisor.hideDuplicateCloudItems)
                        .font(.caption)

                    Spacer()

                    Button("Select Shown") {
                        advisor.selectAllCloud(excludeDuplicates: true)
                    }
                    .controlSize(.small)

                    Button("Deselect All") {
                        advisor.deselectAllCloud()
                    }
                    .controlSize(.small)
                }
            }

            // 3. Cloud Items List
            Section {
                let visible = advisor.filteredCloudItems
                if advisor.isCloudScanning {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Reading cloud metadata only (0 bytes downloaded)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 16)
                } else if visible.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.accentColor)
                        Text("No Cloud Files Matched")
                            .font(.headline)
                        Text("Click Rescan Clouds or connect Google Drive / Dropbox / OneDrive above to browse files stored in external clouds.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    List {
                        ForEach(visible) { item in
                            cloudItemRow(item: item)
                        }
                    }
                    .frame(minHeight: 260, maxHeight: 380)
                }
            }

            // 4. Bottom Cloud Actions (Straight Copy / Copy & Organize Skill / Move to ZeroDrive)
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Text("ZeroDrive Target Folder:")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)

                        TextField("Cloud Imports", text: $cloudDestinationFolder)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)

                        Menu("Presets") {
                            Button("Cloud Imports") { cloudDestinationFolder = "Cloud Imports" }
                            Button("MAIN") { cloudDestinationFolder = "MAIN" }
                            Button("Cold Storage") { cloudDestinationFolder = "Cold Storage" }
                        }
                        .controlSize(.small)

                        Spacer()

                        Text(advisor.selectedCloudCount > 0
                            ? "Selected: \(advisor.selectedCloudCount) items (\(fmtBytes(advisor.selectedCloudBytes)))"
                            : "Select items above or hand off to an AI Agent")
                            .font(.caption.bold())
                            .foregroundStyle(advisor.selectedCloudCount > 0 ? Color.accentColor : .secondary)
                    }

                    HStack(spacing: 10) {
                        Button {
                            Task {
                                await advisor.transferCloudSelected(
                                    isCopy: true,
                                    destinationSubfolder: cloudDestinationFolder
                                )
                            }
                        } label: {
                            Label("Straight Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(advisor.selectedCloudCount == 0 || advisor.isCloudTransferring)

                        Button {
                            showAgentOrganizeSheet = true
                        } label: {
                            Label("Copy & Organize (AI Skill)…", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)

                        Spacer()

                        Button {
                            showConfirmCloudMoveSheet = true
                        } label: {
                            Label("Move to ZeroDrive", systemImage: "arrow.right.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(advisor.selectedCloudCount == 0 || advisor.isCloudTransferring)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - AI Agent Skill Sheet

    private var agentOrganizeSheet: some View {
        let promptText = advisor.generateAgentOrganizePrompt(destinationSubfolder: cloudDestinationFolder)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Copy & Organize with Connected AI Agent")
                        .font(.headline)
                    Text("Uses the portable `organize-cloud-files` skill so Claude Code, Codex, or Antigravity deduplicates and sorts files as they stream into ZeroDrive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Button {
                    _ = advisor.installOrganizeSkillToAgents()
                } label: {
                    Label("Install Skill to Claude / Codex / Agents", systemImage: "link.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if !advisor.skillInstallFeedback.isEmpty {
                    Text(advisor.skillInstallFeedback)
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Ready-to-Run Agent Prompt")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                ScrollView {
                    Text(promptText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 170)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button("Copy Prompt for Claude / Codex") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(promptText, forType: .string)
                    copiedPromptFeedback = "Copied prompt!"
                }
                .buttonStyle(.borderedProminent)

                if !copiedPromptFeedback.isEmpty {
                    Text(copiedPromptFeedback)
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                }

                Spacer()

                Button("Done") {
                    showAgentOrganizeSheet = false
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    // MARK: - Row Builders & Helpers

    private func localItemRow(item: StorageAdvisorItem) -> some View {
        HStack(spacing: 12) {
            Button {
                advisor.toggleItemSelection(id: item.id)
            } label: {
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)

            Image(nsImage: iconForExtension(item.url.pathExtension))
                .resizable()
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text(item.displayLocationPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)

                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("Opened \(item.formattedLastOpened)")
                        .font(.caption2)
                        .foregroundStyle(item.category == .cold ? Color.orange : Color.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(item.formattedSize) on SSD")
                    .font(.subheadline.bold().monospacedDigit())

                HStack(spacing: 4) {
                    if item.isSmartPick {
                        Text("Smart Pick")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.14))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }

                    Text(item.fileKind.rawValue)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(kindColor(for: item.fileKind).opacity(0.14))
                        .foregroundStyle(kindColor(for: item.fileKind))
                        .clipShape(Capsule())
                }
            }

            Button {
                NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
        }
        .padding(.vertical, 4)
    }

    private func cloudItemRow(item: CloudAdvisorItem) -> some View {
        HStack(spacing: 12) {
            Button {
                advisor.toggleCloudItemSelection(id: item.id)
            } label: {
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)

            Image(nsImage: iconForExtension((item.name as NSString).pathExtension))
                .resizable()
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if item.isPossibleDuplicate {
                        Text("Possible Duplicate")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 6) {
                    Text(item.providerLabel)
                        .font(.caption2.bold())
                        .foregroundStyle(Color.accentColor)
                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(item.displayPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(item.formattedSize)
                    .font(.subheadline.bold().monospacedDigit())

                Text(item.allocatedLocalBytes == 0 ? "0 KB on Mac SSD" : "\(fmtBytes(item.allocatedLocalBytes)) cached locally")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func folderChip(title: String, sizeText: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.caption.weight(isActive ? .bold : .medium))
                Text(sizeText)
                    .font(.caption2.monospacedDigit())
                    .opacity(0.8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isActive ? Color.accentColor : Color.secondary.opacity(0.1))
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func legendDot(color: Color, label: String, locked: Bool) -> some View {
        HStack(spacing: 4) {
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(color)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            }
            Text(label)
                .foregroundStyle(.secondary)
        }
    }

    private func bucketCard(
        title: String,
        value: String,
        subtitle: String,
        color: Color,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(isSelected ? color : .secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(color)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
            .padding(9)
            .background(isSelected ? color.opacity(0.11) : Color.secondary.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? color : Color.clear, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func pickCustomLocalFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Local Folder to Scan"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan Folder"
        if panel.runModal() == .OK, let url = panel.url {
            inspectedBucket = .movableUserFiles
            advisor.setCustomScanRoot(url)
        }
    }

    private func iconForExtension(_ ext: String) -> NSImage {
        if !ext.isEmpty, let ut = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: ut)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    private func kindColor(for kind: MovableFileKind) -> Color {
        switch kind {
        case .videoAudio: return .pink
        case .installerArchive: return .purple
        case .designPhoto: return .blue
        case .documentData: return .teal
        }
    }

    private func fmtBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
