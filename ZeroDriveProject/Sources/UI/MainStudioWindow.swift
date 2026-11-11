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
    @State private var pairDeviceFeedback: String = ""
    @State private var connectedClouds: Set<ExternalCloudProvider> = MultiCloudCombineBuilder.shared.connectedExternalClouds()
    @State private var pendingTransfer: PendingTransferItem? = nil
    @State private var renamingNode: ConnectedNodeStatus? = nil
    @State private var editingDeviceName: String = ""
    @State private var isShowingAddDriveSheet: Bool = false
    @State private var showVersionUpdatePopup: Bool = false

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                NavigationLink(value: 0) {
                    Label("Dashboard", systemImage: "speedometer")
                }

                NavigationLink(value: 1) {
                    HStack {
                        Label("Global Search", systemImage: "magnifyingglass")
                        Spacer()
                        if ManageGlobalSearch.shared.totalIndexedCount > 0 {
                            Text("\(ManageGlobalSearch.shared.totalIndexedCount)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                NavigationLink(value: 2) {
                    HStack {
                        Label("Activity", systemImage: "clock.arrow.circlepath")
                        Spacer()
                        if turbo.telemetry.isRunning || spoolManager.dirtyFileCount > 0 {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 8, height: 8)
                        }
                    }
                }

                NavigationLink(value: 3) {
                    HStack {
                        Label("Duplicate Protection", systemImage: "shield.checkerboard")
                        Spacer()
                        if ManageDuplicateProtection.shared.totalDuplicateFiles > 0 {
                            Text("\(ManageDuplicateProtection.shared.totalDuplicateFiles)")
                                .font(.caption2.bold().monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.red.opacity(0.18))
                                .foregroundStyle(.red)
                                .clipShape(Capsule())
                        } else {
                            Image(systemName: "checkmark")
                                .font(.caption2.bold())
                                .foregroundStyle(.green)
                        }
                    }
                }

                NavigationLink(value: 4) {
                    HStack {
                        Label("Devices & Clouds", systemImage: "laptopcomputer.and.iphone")
                        Spacer()
                        Text("\(turbo.connectedDevices.filter { $0.isOnline }.count)")
                            .font(.caption2.bold().monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.16))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }

                NavigationLink(value: 5) {
                    HStack {
                        Label("Account & Licensing", systemImage: "person.badge.shield.checkmark")
                        Spacer()
                        if ManageLicensing.shared.isLicensed {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }
                }

                NavigationLink(value: 6) {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 250)
        } detail: {
            Group {
                switch selectedTab {
                case 0:
                    DashboardView()
                case 1:
                    GlobalSearchView()
                case 2:
                    TransfersView()
                case 3:
                    DuplicateProtectionView()
                case 4:
                    devicesAndCloudsView
                case 5:
                    AccountLicensingView()
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
                    leaveSymlink: confirmed.leaveSymlink,
                    symlinkPaths: confirmed.symlinkPaths
                )
                selectedTab = 0
            } onCancel: {
                pendingTransfer = nil
            }
        }
        .sheet(isPresented: $showVersionUpdatePopup) {
            UpgradePromptSheet(
                triggerReason: "What's New in ZeroDrive v3.0 — Paid Feature Release for AI Agents & Multi-Drive.",
                requiredTier: "Creator"
            )
        }
        .onAppear {
            connectedClouds = MultiCloudCombineBuilder.shared.connectedExternalClouds()
            if let rclone = supervisor.resolveRcloneBinary() {
                Task { await vaultStats.refresh(rclone: rclone) }
            }
            let tier = ManageLicensing.shared.license.tier.lowercased()
            let isFree = tier.contains("free") || tier.contains("starter")
            if isFree && !UserDefaults.standard.bool(forKey: "hasSeenV3UpgradePopup") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    showVersionUpdatePopup = true
                    UserDefaults.standard.set(true, forKey: "hasSeenV3UpgradePopup")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenUpgradeAccountModal"))) { _ in
            selectedTab = 5
        }
    }

    // MARK: - Tab 0: Overview (Live Transfer Card + Active Connections + Cloud Folders)

    private var overviewView: some View {
        Form {
            // 1. Live Transfer Card (Streams Local Moves AND Remote/Cloud Moves Live)
            Section {
                FabricDriveMigrationCard()
            }

            // 2. Active Connections & Devices (Live Presence)
            Section("Active Connections & Devices (\(turbo.connectedNodes.filter { $0.isOnline }.count) Online)") {
                ForEach(turbo.connectedNodes) { node in
                    connectedNodeRow(node)
                }
            }

            // 3. Cloud Vault Status & Finder Shortcut
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

            // 4. Folders inside My Drive
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

    private func connectedNodeRow(_ node: ConnectedNodeStatus) -> some View {
        deviceRow(node)
    }

    private func deviceRow(_ node: ConnectedNodeStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: node.icon)
                    .font(.title2)
                    .foregroundStyle(node.isOnline ? Color.accentColor : Color.secondary)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(node.displayName)
                            .font(.body.weight(.semibold))

                        Button {
                            editingDeviceName = node.displayName
                            renamingNode = node
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Rename device")

                        Text(node.id)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(Capsule())

                        Text(node.statusBadge)
                            .font(.caption2.bold())
                            .foregroundStyle(node.statusBadge.contains("Streaming") ? Color.accentColor : (node.isOnline ? Color.green : Color.secondary))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background((node.statusBadge.contains("Streaming") ? Color.accentColor : (node.isOnline ? Color.green : Color.secondary)).opacity(0.14))
                            .clipShape(Capsule())
                    }

                    HStack(spacing: 10) {
                        Label(node.mountPath, systemImage: "folder")
                            .font(.caption)
                            .foregroundStyle(.primary)

                        Text("•")
                            .foregroundStyle(.secondary)

                        Label(node.formattedFreeSpace + (node.totalBytes > 0 ? " SSD" : ""), systemImage: "internaldrive")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    if let chip = node.chip, !chip.isEmpty {
                        HStack(spacing: 6) {
                            Text(chip)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            if let gpu = node.gpu {
                                Text("• " + gpu)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                            }
                            if let os = node.os, !os.isEmpty {
                                Text("• " + os)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !node.activeActivity.isEmpty {
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.mini)
                            Text(node.activeActivity)
                                .font(.caption.bold().monospacedDigit())
                                .foregroundStyle(Color.accentColor)
                                .lineLimit(1)
                        }
                        .padding(.top, 2)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        editingDeviceName = node.displayName
                        renamingNode = node
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .controlSize(.small)

                    if node.id == "naegele-pro" || node.id == "primary-cloud-vault" {
                        Button("Open in Finder") {
                            supervisor.openInFinder(supervisor.mountPoint.appendingPathComponent("My Drive"))
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            // Disk storage progress bar
            if node.totalBytes > 0 {
                let usedBytes = max(0, node.totalBytes - node.freeBytes)
                let usedRatio = min(1.0, max(0.0, Double(usedBytes) / Double(node.totalBytes)))
                VStack(alignment: .leading, spacing: 3) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.secondary.opacity(0.15))
                                .frame(height: 6)

                            RoundedRectangle(cornerRadius: 3)
                                .fill(usedRatio > 0.9 ? Color.red : (usedRatio > 0.75 ? Color.orange : Color.accentColor))
                                .frame(width: max(4, geo.size.width * CGFloat(usedRatio)), height: 6)
                        }
                    }
                    .frame(height: 6)

                    HStack {
                        let usedStr = ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)
                        let totalStr = ByteCountFormatter.string(fromByteCount: node.totalBytes, countStyle: .file)
                        Text("\(usedStr) used of \(totalStr)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let pct = node.freePercentage {
                            Text(String(format: "%.1f%% free", pct))
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(pct < 10 ? Color.red : Color.green)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
    }

    private var cloudVaultSection: some View {
        Section("ZeroDrive Cloud Storage & Drives") {
            let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
            let quotaTB = meta.quotaTB > 0 ? meta.quotaTB : 5.0
            let totalQuotaBytes = Int64(quotaTB * 1024 * 1024 * 1024 * 1024)
            let usedBytes = vaultStats.liveTotalBytes ?? vaultStats.totalBytes ?? (turbo.ledger?.totalMovedToVaultBytes ?? 0)
            let freeBytes = max(0, totalQuotaBytes - usedBytes)
            let usedRatio = min(1.0, max(0.0, Double(usedBytes) / Double(totalQuotaBytes)))
            let freeRatio = max(0.0, 1.0 - usedRatio)

            VStack(alignment: .leading, spacing: 14) {
                // Top stats row
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: "cloud.fill")
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                            Text("ZeroDrive Cloud Vault")
                                .font(.title3.weight(.bold))
                        }
                        Text("Bucket: \(meta.bucketAndPrefix.isEmpty ? "zerodrive-vault-prod" : meta.bucketAndPrefix) • 0 KB Local SSD Used")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file))
                                .font(.title3.bold().monospacedDigit())
                                .foregroundStyle(.green)
                            Text("Free")
                                .font(.subheadline.bold())
                                .foregroundStyle(.green)
                        }
                        Text("of \(String(format: "%.1f TB", quotaTB)) Total Quota (\(String(format: "%.1f%%", freeRatio * 100)) Available)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Cloud Storage Usage Progress Bar
                VStack(alignment: .leading, spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.secondary.opacity(0.15))
                                .frame(height: 10)

                            RoundedRectangle(cornerRadius: 5)
                                .fill(LinearGradient(colors: [Color.accentColor, Color.purple], startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(6, geo.size.width * CGFloat(usedRatio)), height: 10)
                        }
                    }
                    .frame(height: 10)

                    HStack {
                        Text("\(ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)) Used in Cloud")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Infinite On-Demand Streaming")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Text("\(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)) Free Remaining")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(.green)
                    }
                }

                Divider()

                // Drives Breakdown List
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Configured Drives & Partitions (\(ManageDrives.shared.drives.count))")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            isShowingAddDriveSheet = true
                        } label: {
                            Label("Add New Drive…", systemImage: "folder.badge.plus")
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }

                    ForEach(ManageDrives.shared.drives) { drive in
                        HStack(spacing: 12) {
                            Image(systemName: drive.isDefault ? "externaldrive.fill.badge.icloud" : "folder.badge.gearshape")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(drive.name + (drive.isDefault ? " (Primary Vault)" : ""))
                                        .font(.body.weight(.medium))

                                    Text(drive.isDefault ? "Primary" : (drive.provisioningMode == "partition" ? "Free Partition" : "Dedicated"))
                                        .font(.caption2.bold())
                                        .foregroundStyle(drive.isDefault ? Color.green : Color.accentColor)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background((drive.isDefault ? Color.green : Color.accentColor).opacity(0.14))
                                        .clipShape(Capsule())

                                    if !drive.isDefault {
                                        Text(drive.priceLabel)
                                            .font(.caption2.bold())
                                            .foregroundStyle(.green)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.green.opacity(0.12))
                                            .clipShape(Capsule())
                                    }
                                }

                                HStack(spacing: 8) {
                                    Text("Mounted at ~/.zerodrive-mount/\(drive.name)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    if !drive.isDefault && !drive.targetLocation.isEmpty {
                                        Text("• Target: \(drive.targetLocation)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            Spacer()

                            Button("Open in Finder") {
                                supervisor.openInFinder(supervisor.mountPoint.appendingPathComponent(drive.name))
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(.vertical, 4)
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

    // MARK: - Tab 2: Devices & Cloud Connections

    private var devicesAndCloudsView: some View {
        Form {
            cloudVaultSection

            Section("Connected Devices & Machines (\(turbo.connectedDevices.filter { $0.isOnline }.count) Online)") {
                ForEach(turbo.connectedDevices) { node in
                    deviceRow(node)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Every device connected to your Vault sees your folders and active cloud moves immediately—no Tailscale or VPN required.")
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

            Section("Direct iCloud-to-Cloud Stream (Zero Mac Disk Used)") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "icloud.and.arrow.up.fill")
                            .foregroundStyle(Color.accentColor)
                        Text("Stream directly from Apple's iCloud servers into your ZeroDrive Vault")
                            .font(.subheadline.weight(.medium))
                    }

                    Text("Connected to naegele412@gmail.com via rclone's native iCloud API—bypasses Finder/bird completely and uses 0 bytes of local SSD space.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            launchDirectICloudStream(runOnMini: false)
                        } label: {
                            Label("Stream iCloud MAIN in RAM (This Mac)…", systemImage: "bolt.icloud.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button {
                            launchDirectICloudStream(runOnMini: true)
                        } label: {
                            Label("Run Stream on naegele-mm (Mac mini)…", systemImage: "macmini.fill")
                        }
                        .controlSize(.small)

                        Spacer()
                    }
                    .padding(.top, 2)
                }
                .padding(.vertical, 4)
            }

            Section("Move Files from Local Folders, iCloud, or Fabric") {
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
        .sheet(item: $renamingNode) { node in
            renameSheet(for: node)
        }
        .sheet(isPresented: $isShowingAddDriveSheet) {
            AddNewDriveSheet(isPresented: $isShowingAddDriveSheet)
        }
    }

    private func renameSheet(for node: ConnectedNodeStatus) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: node.icon)
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Rename Device")
                        .font(.headline)
                    Text("Set a custom friendly name for \(node.id). This will sync across your entire fleet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Device Display Name")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                TextField("Display Name", text: $editingDeviceName)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Reset to Default") {
                    turbo.renameDevice(id: node.id, newName: "")
                    renamingNode = nil
                }
                .controlSize(.small)

                Spacer()

                Button("Cancel") {
                    renamingNode = nil
                }
                .controlSize(.small)

                Button("Save Name") {
                    turbo.renameDevice(id: node.id, newName: editingDeviceName)
                    renamingNode = nil
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(20)
        .frame(width: 440)
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

    private func launchDirectICloudStream(runOnMini: Bool) {
        Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            var args = ["/Users/Naegele/_LAB/zerodrive/stream-icloud-to-vault.py", "Desktop/MAIN", "MAIN"]
            if runOnMini {
                args.append("--run-on-mini")
            }
            proc.arguments = args
            try? proc.run()
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
