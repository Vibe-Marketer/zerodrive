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
    @State private var currentFolderFilter: String = ""
    @State private var dropModeMove: Bool = true
    @State private var bypassSpool: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var lastActionFeedback: String = ""
    @State private var connectedClouds: Set<ExternalCloudProvider> = MultiCloudCombineBuilder.shared.connectedExternalClouds()
    @State private var oauthBusyProvider: ExternalCloudProvider? = nil
    @State private var oauthStatusMessage: String = ""

    public init() {}

    public var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                // App Identity Header
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                LinearGradient(
                                    colors: [Color.blue, Color.cyan.opacity(0.8)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 36, height: 36)
                        Image(systemName: "externaldrive.fill.badge.icloud")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ZeroDrive")
                            .font(.headline)
                        Text("5 TB Mac Cloud Drive")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)

                List(selection: $selectedTab) {
                    Section("MAIN MENU") {
                        NavigationLink(value: 0) {
                            Label("1. Free Up Mac Space", systemImage: "arrow.up.doc.fill")
                        }
                        NavigationLink(value: 1) {
                            Label("2. Browse Cloud Files", systemImage: "folder.fill")
                        }
                        NavigationLink(value: 2) {
                            Label("3. Connect Clouds", systemImage: "cloud.fill")
                        }
                        NavigationLink(value: 3) {
                            Label("4. Uploads & Settings", systemImage: "slider.horizontal.3")
                                .badge(spoolManager.dirtyFileCount)
                        }
                    }
                }
                .listStyle(.sidebar)

                // Clean Status Footer (No Duplicate Button)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(supervisor.isMounted ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(supervisor.isMounted ? "Mounted in Finder" : "Drive Offline")
                            .font(.caption)
                            .bold()
                    }
                    Text("Finder Path: ~/ZeroDrive/Vault")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.white.opacity(0.04))
                .cornerRadius(10)
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 235, max: 250)
        } detail: {
            VStack(spacing: 0) {
                topActionHeader
                Divider()
                Group {
                    switch selectedTab {
                    case 0:
                        freeUpSpaceHomeView
                    case 1:
                        browseCloudFilesView
                    case 2:
                        connectCloudsView
                    default:
                        uploadsAndSettingsView
                    }
                }
                .padding(24)
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

    // MARK: - Persistent Top Bar

    private var topActionHeader: some View {
        let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
        return HStack(spacing: 16) {
            HStack(spacing: 10) {
                Circle()
                    .fill(supervisor.isMounted ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(supervisor.isMounted ? "5 TB Cloud Drive Ready in Finder" : supervisor.statusMessage)
                        .font(.headline)
                    Text("Location: ~/ZeroDrive/Vault • Opening cloud files uses 0 GB of your Mac hard drive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if supervisor.isMounted {
                Button {
                    supervisor.openInFinder()
                } label: {
                    Label("Open ZeroDrive in Finder", systemImage: "arrow.up.forward.app.fill")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Eject") {
                    lifecycleController.requestSafeUnmount()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                Button("Mount Cloud Drive") {
                    Task { await supervisor.mountUnifiedDrive() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.03))
    }

    // MARK: - Tab 0: Free Up Mac Space (Spacious 1-2-3 Guided Home)

    private var freeUpSpaceHomeView: some View {
        let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
        return VStack(alignment: .leading, spacing: 20) {
            // 1-2-3 "How It Works" Step Strip
            HStack(spacing: 14) {
                stepBadge(
                    number: "1",
                    title: "Add Heavy Files Below",
                    subtitle: "Drag folders or click Select Files"
                )
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
                stepBadge(
                    number: "2",
                    title: "Free Up Mac Storage",
                    subtitle: "Moved into your 5 TB Cloud Vault"
                )
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
                stepBadge(
                    number: "3",
                    title: "Use Anytime in Finder",
                    subtitle: "Streams instantly with 0 GB on Mac"
                )
            }
            .padding(14)
            .background(Color.white.opacity(0.04))
            .cornerRadius(12)

            // Main Hero Dropzone (Vertical layout — ZERO button collisions or truncation)
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 64, height: 64)
                    Image(systemName: "arrow.up.doc.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.blue)
                }

                VStack(spacing: 6) {
                    Text("Drag & Drop Files or Folders Here")
                        .font(.title2)
                        .bold()

                    Text(dropModeMove
                         ? "ZeroDrive will move your files into ~/ZeroDrive/Vault and immediately free up the space on your Mac."
                         : "ZeroDrive will copy your files into ~/ZeroDrive/Vault and keep the original files on your Mac.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }

                // Big Primary Action Button (On its own row — never truncated!)
                Button {
                    openFilePickerToOffload()
                } label: {
                    Label("Select Files or Folders from My Mac…", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                // Separate Row for Move vs Copy Mode
                VStack(spacing: 8) {
                    Picker("Action when adding files:", selection: $dropModeMove) {
                        Text("Move to Cloud & Free Mac Space (Recommended)").tag(true)
                        Text("Copy to Cloud (Keep Original on Mac)").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 520)

                    Toggle("Low Disk Space Mode: Stream directly to cloud without temporary Mac cache", isOn: $bypassSpool)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)

                if !lastActionFeedback.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(lastActionFeedback)
                            .font(.subheadline)
                            .bold()
                            .foregroundStyle(.green)
                        Button("View in Cloud Files →") {
                            selectedTab = 1
                        }
                        .buttonStyle(.link)
                        .font(.subheadline)
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .background(isDropTargeted ? Color.blue.opacity(0.16) : Color.white.opacity(0.03))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.blue.opacity(isDropTargeted ? 0.9 : 0.35), style: StrokeStyle(lineWidth: 2, dash: [8]))
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDropProviders(providers)
                return true
            }

            // Bottom 3 Summary Cards
            HStack(spacing: 14) {
                summaryCard(
                    title: "MAC SPACE FREED",
                    value: ByteCountFormatter.string(fromByteCount: spoolManager.telemetry.totalSpaceSavedBytes, countStyle: .file),
                    subtitle: "\(ByteCountFormatter.string(fromByteCount: spoolManager.telemetry.freeAPFSBytes, countStyle: .file)) available on your Mac",
                    accent: .green
                )
                summaryCard(
                    title: "CLOUD DRIVE SIZE",
                    value: String(format: "%.1f TB", meta.quotaTB),
                    subtitle: "Mounted at ~/ZeroDrive/Vault",
                    accent: .blue
                )
                summaryCard(
                    title: "UPLOAD STATUS",
                    value: spoolManager.dirtyFileCount == 0 ? "All Synced" : "Uploading \(spoolManager.dirtyFileCount) file(s)",
                    subtitle: spoolManager.dirtyFileCount == 0 ? "0 KB temporary cache in use" : "Click Uploads & Settings to view",
                    accent: spoolManager.dirtyFileCount == 0 ? .secondary : .orange
                )
            }
        }
    }

    private func stepBadge(number: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 26, height: 26)
                Text(number)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).bold()
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Tab 1: Browse Cloud Files (Full-Window File Explorer)

    private var browseCloudFilesView: some View {
        let filteredNodes = indexer.search(query: searchQuery).filter { node in
            guard !currentFolderFilter.isEmpty else { return true }
            return node.relativePath.hasPrefix(currentFolderFilter + "/")
        }

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Files in Your ZeroDrive")
                            .font(.title2)
                            .bold()
                        if !currentFolderFilter.isEmpty {
                            Text("/ \(currentFolderFilter)")
                                .font(.title3)
                                .foregroundStyle(.blue)
                            Button("Back to All Files") {
                                currentFolderFilter = ""
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    Text("Click Open to stream any file immediately (0 GB used on Mac), or Show in Finder to view it in macOS Finder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    openFilePickerToOffload()
                } label: {
                    Label("Add Files…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    supervisor.openInFinder()
                } label: {
                    Label("Open Folder in Finder", systemImage: "folder.fill")
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await indexer.prewarmAll() }
                } label: {
                    Label(indexer.isIndexing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search files across your 5 TB Vault and connected clouds…", text: $searchQuery)
                    .textFieldStyle(.plain)
                if !searchQuery.isEmpty {
                    Button("Clear") { searchQuery = "" }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.06))
            .cornerRadius(10)

            List(filteredNodes) { node in
                HStack(spacing: 12) {
                    Image(systemName: node.isFolder ? "folder.fill" : "doc.text.fill")
                        .font(.title3)
                        .foregroundStyle(node.isFolder ? .blue : .secondary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.name)
                            .font(.body)
                            .bold()
                        Text("~/ZeroDrive/\(node.relativePath)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !node.isFolder {
                        Text(node.formattedSize)
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Button("Show in Finder") {
                        indexer.revealInFinder(node: node)
                    }
                    .buttonStyle(.bordered)

                    Button(node.isFolder ? "Open Folder" : "Open File") {
                        if node.isFolder {
                            currentFolderFilter = node.relativePath
                        } else {
                            indexer.openFile(node: node)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            }
            .cornerRadius(12)
        }
    }

    private func summaryCard(title: String, value: String, subtitle: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .bold()
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3)
                .bold()
                .foregroundStyle(accent)
                .monospacedDigit()
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.04))
        .cornerRadius(12)
    }

    private func openFilePickerToOffload() {
        let panel = NSOpenPanel()
        panel.title = "Select Files or Folders to Send to ZeroDrive"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = dropModeMove ? "Move to ZeroDrive" : "Copy to ZeroDrive"

        if panel.runModal() == .OK, !panel.urls.isEmpty {
            let count = panel.urls.count
            Task {
                await spoolManager.handleDroppedURLs(
                    panel.urls,
                    moveAndFreeSpace: dropModeMove,
                    bypassSpool: bypassSpool
                )
                lastActionFeedback = "Added \(count) item(s) to ~/ZeroDrive/Vault!"
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
                let count = droppedURLs.count
                await spoolManager.handleDroppedURLs(
                    droppedURLs,
                    moveAndFreeSpace: dropModeMove,
                    bypassSpool: bypassSpool
                )
                lastActionFeedback = "Added \(count) item(s) to ~/ZeroDrive/Vault!"
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

    // MARK: - Tab 2: Connect Clouds

    private var connectCloudsView: some View {
        let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connected Cloud Storage").font(.title2).bold()
                Text("All clouds connected here appear as folders inside ~/ZeroDrive so you can browse everything in one place.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            GroupBox("Included Primary Storage") {
                HStack(spacing: 14) {
                    Image(systemName: "externaldrive.fill.badge.checkmark")
                        .font(.largeTitle)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meta.displayLabel).font(.headline)
                        Text("Active at ~/ZeroDrive/Vault • \(String(format: "%.0f TB", meta.quotaTB)) Cloud Capacity")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Vault in Finder") {
                        supervisor.openInFinder()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Change Storage / Use Own Keys…") {
                        reconfigurePrimaryVault()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(12)
            }

            GroupBox("Add Your Other Cloud Accounts (Optional)") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(ExternalCloudProvider.allCases) { provider in
                        cloudRow(provider: provider)
                    }

                    if !oauthStatusMessage.isEmpty {
                        Text(oauthStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
                .padding(12)
            }

            Spacer()
        }
    }

    private func cloudRow(provider: ExternalCloudProvider) -> some View {
        let isConnected = connectedClouds.contains(provider)
        let isBusy = (oauthBusyProvider == provider)
        return HStack(spacing: 12) {
            Image(systemName: provider.systemIcon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName).font(.headline)
                Text("Shows up in Finder at ~/ZeroDrive/\(provider.folderName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isConnected {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
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
        .padding(10)
        .background(Color.white.opacity(0.03))
        .cornerRadius(10)
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
            rcloneURL: rcloneURL
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
            alert.informativeText = "You have \(spoolManager.dirtyFileCount) file(s) currently uploading. Wait for them to finish before changing your storage setup."
            alert.runModal()
            return
        }
        lifecycleController.showOnboardingSheet = true
    }

    // MARK: - Tab 3: Uploads & Settings

    private var uploadsAndSettingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Active Uploads & 15-Second Undo Queue") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(spoolManager.spoolItems.isEmpty
                                 ? "All files are synced to your 5 TB Cloud Vault."
                                 : "New files wait 15 seconds before uploading so you can cancel mistakes.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if spoolManager.dirtyFileCount > 0 {
                                Button("Upload All Now") {
                                    Task { await spoolManager.flushQueueImmediately() }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }

                        ForEach(spoolManager.spoolItems) { item in
                            HStack {
                                Text(item.filename).bold()
                                Text(item.formattedSize).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(item.status.rawValue.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                Button("Upload Now") {
                                    Task { await spoolManager.syncNow(item: item) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                Button("Cancel & Delete") {
                                    Task { await spoolManager.purgeLocally(item: item) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .foregroundStyle(.red)
                            }
                            .padding(8)
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(8)
                        }
                    }
                    .padding(10)
                }

                AutostartAndWorkflowsView()
            }
        }
    }
}
