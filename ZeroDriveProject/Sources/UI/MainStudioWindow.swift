import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct MainStudioWindow: View {
    @EnvironmentObject var lifecycleController: AppLifecycleController
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor
    @EnvironmentObject var spoolManager: SpoolAndGuardManager
    @EnvironmentObject var indexer: RAMTreeIndexer
    @StateObject private var vaultStats = VaultStats.shared

    @State private var selectedTab: Int = 0
    @State private var isDropTargeted: Bool = false
    @State private var lastActionFeedback: String = ""
    @State private var connectedClouds: Set<ExternalCloudProvider> = MultiCloudCombineBuilder.shared.connectedExternalClouds()
    @State private var oauthBusyProvider: ExternalCloudProvider? = nil
    @State private var oauthStatusMessage: String = ""
    @State private var showFabricMigration: Bool = false
    @State private var providerPendingDisconnect: ExternalCloudProvider? = nil

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                NavigationLink(value: 0) {
                    Label("Overview", systemImage: "internaldrive")
                }

                NavigationLink(value: 1) {
                    HStack {
                        Label("Activity", systemImage: "arrow.up.circle")
                        Spacer()
                        if spoolManager.dirtyFileCount > 0 {
                            Text("\(spoolManager.dirtyFileCount)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                    }
                }

                NavigationLink(value: 2) {
                    Label("Cloud Drives & Accounts", systemImage: "cloud.fill")
                }

                NavigationLink(value: 3) {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 230)
        } detail: {
            Group {
                switch selectedTab {
                case 0:
                    overviewView
                case 1:
                    TransfersView()
                case 2:
                    accountsView
                default:
                    AutostartAndWorkflowsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        supervisor.openInFinder()
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .help("Show ZeroDrive in Finder")
                }
            }
        }
        .sheet(isPresented: $lifecycleController.showOnboardingSheet) {
            OnboardingView()
                .environmentObject(lifecycleController)
                .environmentObject(supervisor)
        }
        .alert(
            "Disconnect \(providerPendingDisconnect?.displayName ?? "Account")?",
            isPresented: Binding(
                get: { providerPendingDisconnect != nil },
                set: { if !$0 { providerPendingDisconnect = nil } }
            ),
            presenting: providerPendingDisconnect
        ) { provider in
            Button("Disconnect", role: .destructive) {
                Task {
                    try? MultiCloudCombineBuilder.shared.disconnectExternalCloud(provider)
                    connectedClouds = MultiCloudCombineBuilder.shared.connectedExternalClouds()
                    await supervisor.forceCleanAndRemount()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { provider in
            Text("Your files in \(provider.displayName) won't be deleted, and you can reconnect anytime.")
        }
        .onAppear {
            connectedClouds = MultiCloudCombineBuilder.shared.connectedExternalClouds()
            if let rclone = supervisor.resolveRcloneBinary() {
                Task { await vaultStats.refresh(rclone: rclone) }
            }
        }
    }

    // MARK: - Tab 0: Overview (Main Live Dashboard)

    private var overviewView: some View {
        Form {
            // 1. Live Migration / Turbo Transfer Dashboard (Front and Center)
            Section {
                FabricDriveMigrationCard()
            }

            // 2. Cloud Vault Status & Finder Shortcut
            Section {
                HStack(spacing: 12) {
                    Circle()
                        .fill(supervisor.isMounted ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(supervisor.isMounted ? "ZeroDrive Vault" : "Connecting to Vault…")
                            .font(.headline)
                        Text(formattedTotalStorage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if vaultStats.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button {
                            if let rclone = supervisor.resolveRcloneBinary() {
                                Task { await vaultStats.refresh(rclone: rclone) }
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Refresh Vault storage statistics")
                    }

                    Button("Open in Finder") {
                        let myDrive = supervisor.mountPoint.appendingPathComponent("My Drive")
                        supervisor.openInFinder(myDrive)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                .padding(.vertical, 4)
            }

            Section("Move to My Drive") {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.up.doc.fill")
                            .font(.title2)
                            .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Drop files or folders here to move them to My Drive")
                                .font(.body.weight(.medium))
                            Text("Moves items into My Drive and frees up space on your Mac.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Move Files…") {
                            openFilePickerToOffload()
                        }
                        .controlSize(.small)
                    }

                    if !lastActionFeedback.isEmpty {
                        HStack {
                            Text(lastActionFeedback)
                                .font(.caption)
                                .foregroundStyle(.green)
                            Spacer()
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
                )
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleDropProviders(providers)
                    return true
                }
            }

            Section("Folders") {
                folderRow(
                    title: "My Drive",
                    subtitle: formattedVaultShortSize,
                    icon: "externaldrive.fill",
                    targetURL: supervisor.mountPoint.appendingPathComponent("My Drive")
                )

                ForEach(vaultStats.folders.filter { $0 != "Google Drive" }, id: \.self) { folderName in
                    folderRow(
                        title: folderName,
                        subtitle: "My Drive",
                        icon: "folder",
                        targetURL: supervisor.mountPoint.appendingPathComponent("My Drive").appendingPathComponent(folderName)
                    )
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Overview")
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDropProviders(providers)
            return true
        }
    }

    private var formattedTotalStorage: String {
        if let bytes = vaultStats.liveTotalBytes {
            let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return "\(formatted) stored in My Drive • Zero local SSD space used"
        }
        return vaultStats.isLoading ? "Calculating storage used…" : "ZeroDrive Vault"
    }

    private var formattedVaultShortSize: String {
        if let bytes = vaultStats.liveTotalBytes {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        return "Cloud storage"
    }

    private func folderRow(title: String, subtitle: String, icon: String, targetURL: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Show in Finder") {
                supervisor.openInFinder(targetURL)
            }
            .controlSize(.small)
        }
    }

    // MARK: - Tab 2: Cloud Drives & Accounts

    private var accountsView: some View {
        Form {
            Section("Primary Storage Vault") {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.fill.badge.icloud")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("ZeroDrive Vault")
                            .font(.body.weight(.medium))
                        Text(formattedTotalStorage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Show in Finder") {
                        supervisor.openInFinder(supervisor.mountPoint.appendingPathComponent("My Drive"))
                    }
                    .controlSize(.small)
                }
            }

            Section("Connected Cloud Drives") {
                // Fabric Drive (Native macOS CloudStorage)
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill.badge.gearshape")
                        .font(.title2)
                        .foregroundStyle(Color.green)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Fabric Drive")
                                .font(.body.weight(.medium))
                            Text("Connected")
                                .font(.caption2.bold())
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        Text("Andrew Naegele's Workspace • 11 Spaces ready to migrate")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Migrate Spaces…") {
                        selectedTab = 0
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Reveal in Finder") {
                        let fabricDir = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent("Library/CloudStorage/FabricDrive/Andrew Naegeles Workspace/Spaces")
                        supervisor.openInFinder(fabricDir)
                    }
                    .controlSize(.small)
                }
            }

            Section("Connect Other Cloud Storage") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose any local or cloud folder to stage for transfer into your ZeroDrive Vault.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            let panel = NSOpenPanel()
                            panel.title = "Select Folder to Stage for Transfer"
                            panel.prompt = "Stage Folder"
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
                            if panel.runModal() == .OK, let url = panel.url {
                                TurboMigrationManager.shared.stageURLs([url])
                                selectedTab = 0
                            }
                        } label: {
                            Label("Stage Folder for Transfer…", systemImage: "plus.circle")
                        }
                        .controlSize(.small)

                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Cloud Drives & Accounts")
    }

    private var fabricSummarySubtitle: String {
        let cacheFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/rclone/fabric-spaces-cache.json")
        struct Rec: Decodable { let files: Int; let bytes: Int64 }
        if let data = try? Data(contentsOf: cacheFile),
           let map = try? JSONDecoder().decode([String: Rec].self, from: data),
           !map.isEmpty {
            let totalBytes = map.values.reduce(Int64(0)) { $0 + $1.bytes }
            let formatted = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return "\(map.count) Spaces • \(formatted)"
        }
        return "Move or copy Spaces into My Drive"
    }

    private func accountRow(provider: ExternalCloudProvider) -> some View {
        let isConnected = connectedClouds.contains(provider)
        let isBusy = (oauthBusyProvider == provider)
        let email = MultiCloudCombineBuilder.shared.getAccountEmail(for: provider)

        return HStack(spacing: 10) {
            Image(systemName: provider.systemIcon)
                .font(.title3)
                .foregroundStyle(isConnected ? Color.accentColor : Color.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.body.weight(.medium))
                if isConnected {
                    Text(email ?? "Connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isConnected {
                Button("Show in Finder") {
                    let folderURL = supervisor.mountPoint.appendingPathComponent(provider.folderName)
                    supervisor.openInFinder(folderURL)
                }
                .controlSize(.small)

                Button("Switch Account…") {
                    Task {
                        await connectExternalProvider(provider)
                    }
                }
                .controlSize(.small)
                .disabled(isBusy)

                Button("Disconnect…") {
                    providerPendingDisconnect = provider
                }
                .controlSize(.small)
            } else {
                Button(isBusy ? "Connecting…" : "Connect…") {
                    Task {
                        await connectExternalProvider(provider)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isBusy)
            }
        }
    }

    private func connectExternalProvider(_ provider: ExternalCloudProvider) async {
        guard let rcloneURL = await supervisor.resolveOrDownloadRcloneBinary() else {
            oauthStatusMessage = "Could not locate rclone engine."
            return
        }
        oauthBusyProvider = provider
        oauthStatusMessage = "Waiting for \(provider.displayName) sign-in in your browser…"

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

    // MARK: - Drag-and-Drop & File Picker (Always Moves to My Drive)

    private func openFilePickerToOffload() {
        let panel = NSOpenPanel()
        panel.title = "Move to My Drive"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Move to My Drive"

        if panel.runModal() == .OK, !panel.urls.isEmpty {
            let count = panel.urls.count
            TurboMigrationManager.shared.startDirectMove(urls: panel.urls)
            showFeedback("Moving \(count) item(s) to My Drive...")
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
                TurboMigrationManager.shared.startDirectMove(urls: droppedURLs)
                showFeedback("Moving \(count) item(s) to My Drive...")
            }
        }
    }

    private func showFeedback(_ text: String) {
        lastActionFeedback = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if lastActionFeedback == text {
                lastActionFeedback = ""
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
}
