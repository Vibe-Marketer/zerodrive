import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct MainStudioWindow: View {
    @EnvironmentObject var lifecycleController: AppLifecycleController
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor
    @EnvironmentObject var spoolManager: SpoolAndGuardManager
    @EnvironmentObject var indexer: RAMTreeIndexer
    @StateObject private var vaultStats = VaultStats.shared
    @ObservedObject private var turbo = TurboMigrationManager.shared

    @State private var selectedTab: Int = 0
    @State private var isDropTargeted: Bool = false
    @State private var lastActionFeedback: String = ""
    @State private var pairDeviceFeedback: String = ""
    @State private var connectedClouds: Set<ExternalCloudProvider> = MultiCloudCombineBuilder.shared.connectedExternalClouds()
    @State private var oauthBusyProvider: ExternalCloudProvider? = nil
    @State private var oauthStatusMessage: String = ""
    @State private var providerPendingDisconnect: ExternalCloudProvider? = nil
    @State private var pendingTransfer: PendingTransferItem? = nil

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                NavigationLink(value: 0) {
                    Label("Overview", systemImage: "internaldrive")
                }

                NavigationLink(value: 1) {
                    HStack {
                        Label("Activity & Shortcuts", systemImage: "clock.arrow.circlepath")
                        Spacer()
                        if turbo.telemetry.isRunning || spoolManager.dirtyFileCount > 0 {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 8, height: 8)
                        }
                    }
                }

                NavigationLink(value: 2) {
                    Label("Devices & Clouds", systemImage: "laptopcomputer.and.iphone")
                }

                NavigationLink(value: 3) {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 185, ideal: 205, max: 235)
        } detail: {
            Group {
                switch selectedTab {
                case 0:
                    overviewView
                case 1:
                    TransfersView()
                case 2:
                    devicesAndCloudsView
                default:
                    AutostartAndWorkflowsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        supervisor.openInFinder(supervisor.mountPoint.appendingPathComponent("My Drive"))
                    } label: {
                        Label("Open My Drive in Finder", systemImage: "folder")
                    }
                    .help("Open ~/ZeroDrive/My Drive in Finder")
                }
            }
        }
        .sheet(isPresented: $lifecycleController.showOnboardingSheet) {
            OnboardingView()
                .environmentObject(lifecycleController)
                .environmentObject(supervisor)
        }
        .sheet(item: $pendingTransfer) { pending in
            TransferConfirmationSheet(pendingItem: pending) { confirmed in
                pendingTransfer = nil
                TurboMigrationManager.shared.startTransfer(
                    urls: confirmed.urls,
                    destinationSubfolder: confirmed.destinationFolder,
                    isCopy: confirmed.isCopy,
                    leaveSymlink: confirmed.leaveSymlink
                )
                selectedTab = 0
            } onCancel: {
                pendingTransfer = nil
            }
        }
        .onAppear {
            connectedClouds = MultiCloudCombineBuilder.shared.connectedExternalClouds()
            if let rclone = supervisor.resolveRcloneBinary() {
                Task { await vaultStats.refresh(rclone: rclone) }
            }
        }
    }

    // MARK: - Tab 0: Overview (Single Unified Transfer Card + Cloud Folders)

    private var overviewView: some View {
        Form {
            // 1. Unified Transfer Card (No Duplicate Drop Zones!)
            Section {
                FabricDriveMigrationCard()
            }

            // 2. Cloud Vault Status & Finder Shortcut
            Section("Your Cloud Vault") {
                HStack(spacing: 12) {
                    Circle()
                        .fill(supervisor.isMounted ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(supervisor.isMounted ? "My Drive (Connected in Finder)" : "Connecting to Cloud Vault…")
                            .font(.headline)
                        Text(formattedTotalStorage)
                            .font(.subheadline.monospacedDigit())
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
                        .help("Refresh Cloud Vault size")
                    }

                    Button("Open My Drive") {
                        let myDrive = supervisor.mountPoint.appendingPathComponent("My Drive")
                        supervisor.openInFinder(myDrive)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                .padding(.vertical, 4)
            }

            // 3. Folders inside My Drive
            Section("Folders in My Drive") {
                ForEach(vaultStats.folders.filter { $0 != "Google Drive" }, id: \.self) { folderName in
                    folderRow(
                        title: folderName,
                        subtitle: "Stored in Cloud • 0 KB used on Mac",
                        icon: "folder.fill",
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
        if let bytes = vaultStats.liveTotalBytes, bytes > 0 {
            let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return "\(formatted) stored in Cloud • 0 KB used on this Mac"
        }
        return vaultStats.isLoading ? "Checking Cloud Vault size…" : "Connected • 0 KB used on this Mac"
    }

    private func folderRow(title: String, subtitle: String, icon: String, targetURL: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Open in Finder") {
                supervisor.openInFinder(targetURL)
            }
            .controlSize(.small)
        }
    }

    // MARK: - Tab 2: Devices & Cloud Sources

    private var devicesAndCloudsView: some View {
        Form {
            Section("My Macs & Devices (Instant Access Everywhere)") {
                deviceRow(
                    name: Host.current().localizedName ?? "MacBook Pro (This Mac)",
                    detail: "Mounted at ~/ZeroDrive/My Drive • Live Sync Active",
                    icon: "laptopcomputer",
                    isCurrent: true
                )

                deviceRow(
                    name: "naegele-mm (Mac mini)",
                    detail: "Connected to same Cloud Vault • Instant HTTPS Access",
                    icon: "macmini.fill",
                    isCurrent: false
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("Want My Drive on another Mac or server? Every device connected to your Vault sees your folders immediately—no Tailscale or VPN needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            copyPairingCommandToClipboard()
                        } label: {
                            Label("Copy 1-Click Setup Command for Another Mac", systemImage: "doc.on.doc")
                        }
                        .controlSize(.small)

                        if !pairDeviceFeedback.isEmpty {
                            Text(pairDeviceFeedback)
                                .font(.caption.bold())
                                .foregroundStyle(.green)
                        }
                        Spacer()
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Move Files from iCloud, Fabric, or External Drives") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pick any folder from iCloud Drive, Fabric Drive, or your Mac to move into ZeroDrive and free up local space.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            openFilePickerToOffload()
                        } label: {
                            Label("Choose Folder or Files to Move…", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Spacer()
                    }
                    .padding(.top, 2)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Devices & Clouds")
    }

    private func deviceRow(name: String, detail: String, icon: String, isCurrent: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.body.weight(.medium))
                    Text(isCurrent ? "This Mac" : "Connected")
                        .font(.caption2.bold())
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Capsule())
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isCurrent {
                Button("Open My Drive") {
                    supervisor.openInFinder(supervisor.mountPoint.appendingPathComponent("My Drive"))
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func copyPairingCommandToClipboard() {
        let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
        let cmd = "mkdir -p ~/.config/rclone && echo '{\"bucketAndPrefix\":\"\(meta.bucketAndPrefix)\",\"endpoint\":\"https://zerodrive.aisimple.co/s3\"}' > ~/.config/rclone/zerodrive-vault.json && open -a ZeroDrive"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        pairDeviceFeedback = "✓ Copied setup command!"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            pairDeviceFeedback = ""
        }
    }

    private func openFilePickerToOffload() {
        let panel = NSOpenPanel()
        panel.title = "Choose Folder or Files to Move to ZeroDrive"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Review Move"

        if panel.runModal() == .OK, !panel.urls.isEmpty {
            pendingTransfer = PendingTransferItem(urls: panel.urls)
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
                await MainActor.run {
                    pendingTransfer = PendingTransferItem(urls: droppedURLs)
                }
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
