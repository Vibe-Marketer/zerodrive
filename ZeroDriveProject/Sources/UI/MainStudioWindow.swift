import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

public struct MainStudioWindow: View {
    @EnvironmentObject var lifecycleController: AppLifecycleController
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor
    @EnvironmentObject var spoolManager: SpoolAndGuardManager
    @EnvironmentObject var indexer: RAMTreeIndexer

    @State private var selectedTab: Int = 0
    @State private var searchQuery: String = ""
    @State private var dropModeMove: Bool = true
    @State private var bypassSpool: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var connectedClouds: Set<ExternalCloudProvider> = MultiCloudCombineBuilder.shared.connectedExternalClouds()
    @State private var oauthBusyProvider: ExternalCloudProvider? = nil
    @State private var oauthStatusMessage: String = ""
    @State private var customGoogleClientId: String = ""

    public init() {}

    public var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                // Brand Header in Sidebar
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.blue.opacity(0.2))
                            .frame(width: 32, height: 32)
                        Image(systemName: "externaldrive.fill.badge.icloud")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.blue)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("ZeroDrive")
                            .font(.headline)
                        Text("5 TB Cloud Drive")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                List(selection: $selectedTab) {
                    Section("WORKSPACE") {
                        NavigationLink(value: 0) {
                            Label("Offload & Browse Files", systemImage: "arrow.up.doc.fill")
                        }
                        NavigationLink(value: 1) {
                            Label("Connect Clouds", systemImage: "cloud.fill")
                        }
                        NavigationLink(value: 2) {
                            Label("Uploads & Undo", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                                .badge(spoolManager.dirtyFileCount)
                        }
                        NavigationLink(value: 3) {
                            Label("Settings & Speed", systemImage: "slider.horizontal.3")
                        }
                    }
                }
                .listStyle(.sidebar)

                // Simple Plain-English Status Footer in Sidebar
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Circle()
                            .fill(supervisor.isMounted ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(supervisor.isMounted ? "Drive Active in Finder" : "Drive Unmounted")
                            .font(.caption)
                            .bold()
                    }
                    Text("Location: ~/ZeroDrive")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Button {
                        NSWorkspace.shared.open(supervisor.mountPoint)
                    } label: {
                        Label("Open in Finder", systemImage: "folder.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(12)
                .background(Color.white.opacity(0.04))
                .cornerRadius(10)
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 215, ideal: 230, max: 250)
        } detail: {
            VStack(spacing: 0) {
                topActionHeader
                Divider()
                Group {
                    switch selectedTab {
                    case 0:
                        offloadAndBrowseView
                    case 1:
                        connectCloudsView
                    case 2:
                        uploadsAndUndoView
                    default:
                        AutostartAndWorkflowsView()
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $lifecycleController.showOnboardingSheet) {
            OnboardingView()
                .environmentObject(lifecycleController)
                .environmentObject(supervisor)
        }
        .onAppear {
            connectedClouds = MultiCloudCombineBuilder.shared.connectedExternalClouds()
        }
    }

    // MARK: - Persistent Top Bar (Always Clear What's Happening)

    private var topActionHeader: some View {
        let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
        return HStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(supervisor.isMounted ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(supervisor.isMounted ? "Your ZeroDrive is Live in Finder (~/ZeroDrive)" : supervisor.statusMessage)
                        .font(.subheadline)
                        .bold()
                    Text("Cloud Capacity: \(String(format: "%.0f TB", meta.quotaTB)) • Reading files uses 0 bytes of your Mac SSD")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if supervisor.isMounted {
                Button {
                    NSWorkspace.shared.open(supervisor.mountPoint)
                } label: {
                    Label("Open ZeroDrive Folder", systemImage: "folder.fill")
                }
                .buttonStyle(.borderedProminent)

                Button("Eject / Unmount") {
                    lifecycleController.requestSafeUnmount()
                }
                .buttonStyle(.bordered)
            } else {
                Button("Mount ZeroDrive Now") {
                    Task { await supervisor.mountUnifiedDrive() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.03))
    }

    // MARK: - Tab 0: Offload Files & Browse Cloud

    private var offloadAndBrowseView: some View {
        let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
        return VStack(alignment: .leading, spacing: 16) {
            // 3 Plain-English Summary Cards
            HStack(spacing: 12) {
                summaryCard(
                    title: "MAC SSD SPACE FREED",
                    value: ByteCountFormatter.string(fromByteCount: spoolManager.telemetry.totalSpaceSavedBytes, countStyle: .file),
                    subtitle: "Available on Mac: \(ByteCountFormatter.string(fromByteCount: spoolManager.telemetry.freeAPFSBytes, countStyle: .file))",
                    accent: .green
                )
                summaryCard(
                    title: "CLOUD DRIVE CAPACITY",
                    value: String(format: "%.1f TB", meta.quotaTB),
                    subtitle: "\(indexer.indexedNodes.count) files ready to stream in Finder",
                    accent: .blue
                )
                summaryCard(
                    title: "CURRENTLY UPLOADING",
                    value: spoolManager.dirtyFileCount == 0 ? "All Synced" : "\(spoolManager.dirtyFileCount) file(s)",
                    subtitle: "Temp cache: \(ByteCountFormatter.string(fromByteCount: spoolManager.telemetry.spoolUsedBytes, countStyle: .file)) (clears after upload)",
                    accent: spoolManager.dirtyFileCount > 0 ? .orange : .secondary
                )
            }

            // Step-by-Step Offload Dropzone Card
            VStack(spacing: 12) {
                Image(systemName: "arrow.up.doc.on.clipboard")
                    .font(.system(size: 30))
                    .foregroundStyle(.blue)

                Text("Drop Files or Folders Here to Send to ZeroDrive")
                    .font(.title3)
                    .bold()

                Text(dropModeMove
                     ? "Moves files off your Mac into ~/ZeroDrive/Vault so you immediately get your Mac disk space back."
                     : "Copies files into ~/ZeroDrive/Vault while keeping the original file on your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Picker("", selection: $dropModeMove) {
                        Text("Move to Cloud & Free Mac Space").tag(true)
                        Text("Copy to Cloud (Keep on Mac)").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 380)

                    Button {
                        openFilePickerToOffload()
                    } label: {
                        Label("Choose Files or Folders…", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }

                Toggle("Low Mac Disk Space Mode: Stream straight to cloud without using temporary Mac cache", isOn: $bypassSpool)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(18)
            .background(isDropTargeted ? Color.blue.opacity(0.18) : Color.white.opacity(0.04))
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.blue.opacity(isDropTargeted ? 0.9 : 0.35), style: StrokeStyle(lineWidth: 2, dash: [6]))
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDropProviders(providers)
                return true
            }

            // Cloud Files Search & Quick Browser
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Files Inside Your ZeroDrive (~/ZeroDrive)")
                        .font(.subheadline)
                        .bold()
                    Spacer()
                    Button {
                        Task { await indexer.prewarmAll() }
                    } label: {
                        Label(indexer.isIndexing ? "Refreshing…" : "Refresh File List", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search your cloud files by name…", text: $searchQuery)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(Color.white.opacity(0.06))
                .cornerRadius(8)

                List(indexer.search(query: searchQuery).prefix(50)) { node in
                    HStack(spacing: 10) {
                        Image(systemName: node.isFolder ? "folder.fill" : "doc.text.fill")
                            .foregroundStyle(node.isFolder ? .blue : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.name).font(.body).bold()
                            Text("Folder: ~/ZeroDrive/\(node.relativePath)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !node.isFolder {
                            Text(node.formattedSize)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Button("Show in Finder") {
                            indexer.revealInFinder(node: node)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Open") {
                            indexer.openFile(node: node)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
                .cornerRadius(10)
            }
        }
    }

    private func summaryCard(title: String, value: String, subtitle: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .bold()
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2)
                .bold()
                .foregroundStyle(accent)
                .monospacedDigit()
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.04))
        .cornerRadius(10)
    }

    private func openFilePickerToOffload() {
        let panel = NSOpenPanel()
        panel.title = "Choose Files or Folders to Send to ZeroDrive"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = dropModeMove ? "Move to ZeroDrive" : "Copy to ZeroDrive"

        if panel.runModal() == .OK, !panel.urls.isEmpty {
            Task {
                await spoolManager.handleDroppedURLs(
                    panel.urls,
                    moveAndFreeSpace: dropModeMove,
                    bypassSpool: bypassSpool
                )
                await indexer.prewarmAll()
            }
        }
    }

    private func handleDropProviders(_ providers: [NSItemProvider]) {
        Task {
            var droppedURLs: [URL] = []
            for provider in providers {
                if let url = await loadFileURL(from: provider) {
                    droppedURLs.append(url)
                }
            }
            if !droppedURLs.isEmpty {
                await spoolManager.handleDroppedURLs(
                    droppedURLs,
                    moveAndFreeSpace: dropModeMove,
                    bypassSpool: bypassSpool
                )
                await indexer.prewarmAll()
            }
        }
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    // MARK: - Tab 1: Connect Clouds

    private var connectCloudsView: some View {
        let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your Connected Cloud Drives").font(.title2).bold()
                Text("Every cloud you connect here shows up as a folder inside ~/ZeroDrive so you can browse and open all your cloud files in one place without using Mac disk space.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            GroupBox("1. Primary Cloud Drive (Included)") {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.fill.badge.checkmark")
                        .font(.title)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meta.displayLabel).font(.headline)
                        Text("Mounted in Finder at ~/ZeroDrive/Vault • \(String(format: "%.0f TB", meta.quotaTB)) Cloud Storage • Zero Egress Fees")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Change Cloud Storage / Use Own Keys…") {
                        reconfigurePrimaryVault()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(10)
            }

            GroupBox("2. Optional: Link Your Google Drive, Dropbox, or OneDrive") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Click Connect to sign in with your browser. Your account will appear as a folder inside ~/ZeroDrive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(ExternalCloudProvider.allCases) { provider in
                        cloudRow(provider: provider)
                    }

                    if !oauthStatusMessage.isEmpty {
                        Text(oauthStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
                .padding(10)
            }

            Spacer()
        }
    }

    private func cloudRow(provider: ExternalCloudProvider) -> some View {
        let isConnected = connectedClouds.contains(provider)
        let isBusy = (oauthBusyProvider == provider)
        return HStack(spacing: 12) {
            Image(systemName: provider.systemIcon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName).bold()
                Text("Appears in Finder at ~/ZeroDrive/\(provider.folderName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isConnected {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Button("Disconnect") {
                    Task {
                        try? MultiCloudCombineBuilder.shared.disconnectExternalCloud(provider)
                        connectedClouds = MultiCloudCombineBuilder.shared.connectedExternalClouds()
                        await supervisor.forceCleanAndRemount()
                    }
                }
                .buttonStyle(.bordered)
            } else {
                Button(isBusy ? "Complete Sign-In in Browser…" : "Connect \(provider.displayName)") {
                    Task {
                        await connectExternalProvider(provider)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.03))
        .cornerRadius(8)
    }

    private func connectExternalProvider(_ provider: ExternalCloudProvider) async {
        guard let rcloneURL = await supervisor.resolveOrDownloadRcloneBinary() else {
            oauthStatusMessage = "Could not locate rclone engine."
            return
        }
        oauthBusyProvider = provider
        oauthStatusMessage = "Opened browser for \(provider.displayName) sign-in. Waiting for approval…"

        let (ok, message) = await MultiCloudCombineBuilder.shared.connectExternalCloudOAuth(
            provider: provider,
            rcloneURL: rcloneURL,
            customClientId: provider == .googleDrive ? customGoogleClientId : nil
        )
        oauthBusyProvider = nil
        oauthStatusMessage = message
        connectedClouds = MultiCloudCombineBuilder.shared.connectedExternalClouds()

        if ok {
            await supervisor.forceCleanAndRemount()
            await indexer.prewarmAll()
        }
    }

    private func reconfigurePrimaryVault() {
        guard spoolManager.dirtyFileCount == 0 else {
            let alert = NSAlert()
            alert.messageText = "Wait for Active Uploads to Finish"
            alert.informativeText = "You have \(spoolManager.dirtyFileCount) file(s) currently uploading. Wait for them to finish or cancel them in the Uploads & Undo tab before changing your storage setup."
            alert.runModal()
            return
        }
        lifecycleController.showOnboardingSheet = true
    }

    // MARK: - Tab 2: Uploads & Undo

    private var uploadsAndUndoView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Active Uploads & 15-Second Undo Queue").font(.title2).bold()
                    Text("When you save or drop a file into ZeroDrive, it waits 15 seconds before uploading so you can cancel mistakes or move bad takes to _Retakes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Upload All Immediately") {
                    Task { await spoolManager.flushQueueImmediately() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(spoolManager.dirtyFileCount == 0)
            }

            if spoolManager.spoolItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.green)
                    Text("All Files Are Synced to the Cloud")
                        .font(.headline)
                    Text("0 bytes of temporary upload cache are being used on your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(spoolManager.spoolItems) {
                    TableColumn("File") { item in
                        HStack(spacing: 6) {
                            Text(item.filename).bold()
                            if let duration = item.mediaDuration {
                                Text(duration)
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.15))
                                    .cornerRadius(4)
                            }
                        }
                    }
                    TableColumn("Size", value: \.formattedSize)
                    TableColumn("Status") { item in
                        HStack(spacing: 4) {
                            Text(friendlyStatusLabel(for: item))
                                .foregroundStyle(statusColor(for: item.status))
                        }
                    }
                    TableColumn("Actions") { item in
                        HStack(spacing: 6) {
                            Button("Upload Now") {
                                Task { await spoolManager.syncNow(item: item) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(item.status == .synced || item.status == .purged)

                            Button("Move to _Retakes") {
                                Task { await spoolManager.tagAsRetake(item: item) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(item.status == .purged || item.status == .retake)

                            Button("Cancel & Delete") {
                                Task { await spoolManager.purgeLocally(item: item) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .foregroundStyle(.red)
                            .disabled(item.status == .purged)
                        }
                    }
                }
            }
        }
    }

    private func friendlyStatusLabel(for item: SpoolItem) -> String {
        switch item.status {
        case .staging:
            return item.writeBackRemainingSec > 0 ? "Waiting \(item.writeBackRemainingSec)s (Undo Window)" : "Queued"
        case .uploading:
            return "Uploading to Cloud…"
        case .pausedOffline:
            return "Paused (Waiting for Internet)"
        case .synced:
            return "Uploaded & Space Freed"
        case .purged:
            return "Cancelled & Deleted"
        case .retake:
            return "Moved to _Retakes"
        }
    }

    private func statusColor(for status: SpoolStatus) -> Color {
        switch status {
        case .staging: return .orange
        case .uploading: return .blue
        case .pausedOffline: return .yellow
        case .synced: return .green
        case .purged: return .red
        case .retake: return .purple
        }
    }
}
