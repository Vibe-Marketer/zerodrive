import SwiftUI
import AppKit

public enum DriveProvisioningMode: String, CaseIterable, Identifiable {
    case partition = "partition"
    case dedicated = "dedicated"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .partition:
            return "Partition Current Drive"
        case .dedicated:
            return "Add Another Drive"
        }
    }

    public var badge: String {
        switch self {
        case .partition:
            return "FREE"
        case .dedicated:
            return "DISCOUNTED RATE"
        }
    }

    public var priceSubtitle: String {
        switch self {
        case .partition:
            return "Free • Included in your active plan"
        case .dedicated:
            return "$25/mo per 1 TB • Or upgrade to Pro Max (3 TB)"
        }
    }

    public var description: String {
        switch self {
        case .partition:
            return "Carves out an isolated drive folder from your existing 5.0 TB plan quota without adding any extra charges."
        case .dedicated:
            return "Adds fresh, independent cloud storage capacity that does not consume your current plan's vault quota."
        }
    }
}

public enum DriveProvisioningTarget: String, CaseIterable, Identifiable {
    case allFleet = "all_fleet"
    case thisMac = "this_mac"
    case windowsPC = "naegele-pc"
    case macMinis = "mac_minis"
    case teamMCP = "team_mcp"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .allFleet:
            return "🌐 All Fleet Devices (MacBook Pro, PC, Minis)"
        case .thisMac:
            return "💻 This Mac Only (naegele-pro)"
        case .windowsPC:
            return "🖥️ Windows PC (naegele-pc • C:\\Users\\andre\\ZeroDrive)"
        case .macMinis:
            return "⚡ Rendering Minis (naegele-mm, mike-mm)"
        case .teamMCP:
            return "🤖 Team AI Agent MCP (OAuth2 Provisioned API)"
        }
    }

    public var destinationNotes: String {
        switch self {
        case .allFleet:
            return "Mounts into Finder and File Explorer across all connected computers in your fleet."
        case .thisMac:
            return "Mounts exclusively on this MacBook Pro as an isolated local FileProvider container."
        case .windowsPC:
            return "Provisions directly to Windows 11 and WSL2 (/zerodrive) for GPU rendering jobs."
        case .macMinis:
            return "Mounts to M4 Mac minis for automated background pipelines."
        case .teamMCP:
            return "Exposes an isolated oauth2-gated MCP endpoint (api.zerodrive.dev/mcp/...) for team AI agents."
        }
    }
}

public struct AddNewDriveSheet: View {
    @Binding public var isPresented: Bool
    public var onDriveCreated: ((String) -> Void)? = nil

    @ObservedObject private var manageDrives = ManageDrives.shared
    @ObservedObject private var vaultStats = VaultStats.shared

    @State private var mode: DriveProvisioningMode = .partition
    @State private var driveName: String = ""
    @State private var targetLocation: DriveProvisioningTarget = .allFleet
    @State private var partitionQuotaGB: Double = 250.0
    @State private var dedicatedQuotaTB: Int = 1
    @State private var errorMessage: String = ""

    private let nameSuggestions = ["Clients", "Video Projects", "Raw Footage", "Team Shared", "Archive", "AI Datasets"]

    public init(isPresented: Binding<Bool>, onDriveCreated: ((String) -> Void)? = nil) {
        self._isPresented = isPresented
        self.onDriveCreated = onDriveCreated
    }

    private var metaQuotaTB: Double {
        let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
        return meta.quotaTB > 0 ? meta.quotaTB : 5.0
    }

    private var availableFreeBytes: Int64 {
        let totalQuotaBytes = Int64(metaQuotaTB * 1024 * 1024 * 1024 * 1024)
        let usedBytes = vaultStats.liveTotalBytes ?? vaultStats.totalBytes ?? 0
        return max(0, totalQuotaBytes - usedBytes)
    }

    private var availableFreeStr: String {
        ByteCountFormatter.string(fromByteCount: availableFreeBytes, countStyle: .file)
    }

    private var dedicatedPriceString: String {
        switch dedicatedQuotaTB {
        case 1: return "$25/mo"
        case 2: return "$40/mo"
        case 3: return "$97/mo"
        default: return "$\(dedicatedQuotaTB * 25)/mo"
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Add New Drive")
                        .font(.title3.bold())
                    Text("Create an isolated drive partition or add dedicated capacity for your fleet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {

                    // 1. Mode Selection: Partition vs Add Another Drive
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SELECT PROVISIONING OPTION")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            modeCard(
                                targetMode: .partition,
                                title: "Partition Current Drive",
                                badgeText: "FREE",
                                badgeColor: .green,
                                priceText: "Free (0 Extra Cost)",
                                subtitle: "Uses existing \(String(format: "%.1f TB", metaQuotaTB)) quota • \(availableFreeStr) available"
                            )

                            modeCard(
                                targetMode: .dedicated,
                                title: "Add Another Drive",
                                badgeText: "DEDICATED",
                                badgeColor: Color.accentColor,
                                priceText: "$25/mo per 1 TB",
                                subtitle: "Adds dedicated cloud capacity or upgrade to Pro Max (3 TB)"
                            )
                        }
                    }

                    // 2. Drive Name
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("DRIVE NAME")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Will appear as a top-level drive folder")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        TextField("e.g. Clients, Video Projects, Team Vault", text: $driveName)
                            .textFieldStyle(.roundedBorder)

                        // Quick suggestion pills
                        HStack(spacing: 6) {
                            Text("Suggestions:")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            ForEach(nameSuggestions, id: \.self) { suggestion in
                                Button(suggestion) {
                                    driveName = suggestion
                                }
                                .buttonStyle(.plain)
                                .font(.caption2)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(Capsule())
                            }
                        }
                        .padding(.top, 2)
                    }

                    // 3. Select Where to Provision
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("PROVISIONING DESTINATION")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Where this drive will be mounted")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Picker("", selection: $targetLocation) {
                            ForEach(DriveProvisioningTarget.allCases) { target in
                                Text(target.label).tag(target)
                            }
                        }
                        .labelsHidden()

                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                            Text(targetLocation.destinationNotes)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }

                    // 4. Storage Quota Allocation
                    if mode == .partition {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("PARTITION QUOTA SIZE")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(partitionQuotaGB)) GB")
                                    .font(.subheadline.bold().monospacedDigit())
                                    .foregroundStyle(.primary)
                            }

                            Slider(value: $partitionQuotaGB, in: 25...2000, step: 25)

                            HStack {
                                Text("25 GB")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("Allocated from \(availableFreeStr) free pool • FREE")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.green)
                                Spacer()
                                Text("2 TB")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            // Quota preset pills
                            HStack(spacing: 6) {
                                ForEach([50.0, 100.0, 250.0, 500.0, 1000.0], id: \.self) { size in
                                    Button(size >= 1000 ? "1 TB" : "\(Int(size)) GB") {
                                        partitionQuotaGB = size
                                    }
                                    .buttonStyle(.plain)
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(partitionQuotaGB == size ? Color.accentColor : Color.secondary.opacity(0.12))
                                    .foregroundStyle(partitionQuotaGB == size ? Color.white : Color.primary)
                                    .clipShape(Capsule())
                                }
                            }
                            .padding(.top, 2)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("DEDICATED CAPACITY")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)

                            HStack(spacing: 10) {
                                dedicatedOptionCard(tb: 1, price: "$25/mo", badge: nil)
                                dedicatedOptionCard(tb: 2, price: "$40/mo", badge: nil)
                                dedicatedOptionCard(tb: 3, price: "$97/mo", badge: "PRO MAX")
                            }

                            Text(dedicatedQuotaTB == 3 ? "Pro Max includes 3 TB dedicated cloud storage, unlimited independent drives, and full fleet access." : "Dedicated capacity adds an independent cloud vault container with unthrottled bandwidth.")
                                .font(.caption2)
                                .foregroundStyle(dedicatedQuotaTB == 3 ? Color.accentColor : Color.secondary)
                                .padding(.top, 2)
                        }
                    }

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer / Action Bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(mode == .partition ? "FREE OF CHARGE" : (dedicatedQuotaTB == 3 ? "PRO MAX TIER" : "DEDICATED CAPACITY"))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(mode == .partition ? Color.green : Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background((mode == .partition ? Color.green : Color.accentColor).opacity(0.14))
                            .clipShape(Capsule())

                        Text(mode == .partition ? "Included in your current plan" : (dedicatedQuotaTB == 3 ? "Complete fleet vault + 3 TB" : "Unthrottled cloud vault"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .controlSize(.regular)
                .keyboardShortcut(.cancelAction)

                Button {
                    createDrive()
                } label: {
                    if manageDrives.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(
                            mode == .partition ? "Partition & Mount Drive (FREE)" : (dedicatedQuotaTB == 3 ? "Upgrade to Pro Max ($97/mo)" : "Provision Dedicated Drive (\(dedicatedPriceString))"),
                            systemImage: mode == .partition ? "checkmark.circle.fill" : (dedicatedQuotaTB == 3 ? "bolt.fill" : "creditcard.fill")
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(driveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manageDrives.isWorking)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 540, height: 530)
    }

    private func modeCard(
        targetMode: DriveProvisioningMode,
        title: String,
        badgeText: String,
        badgeColor: Color,
        priceText: String,
        subtitle: String
    ) -> some View {
        let isSelected = (mode == targetMode)

        return Button {
            mode = targetMode
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.subheadline.bold())
                    Spacer()
                    Text(badgeText)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badgeColor.opacity(0.15))
                        .clipShape(Capsule())
                }

                Text(priceText)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(badgeColor)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func dedicatedOptionCard(tb: Int, price: String, badge: String? = nil) -> some View {
        let isSelected = (dedicatedQuotaTB == tb)

        return Button {
            dedicatedQuotaTB = tb
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    Text("\(tb) TB")
                        .font(.subheadline.bold())
                    if let badge = badge {
                        Text(badge)
                            .font(.system(size: 8, weight: .black))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                }
                Text(price)
                    .font(.caption.bold())
                    .foregroundStyle(Color.accentColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func createDrive() {
        let finalQuotaGB = (mode == .partition) ? partitionQuotaGB : Double(dedicatedQuotaTB * 1024)
        let priceTag = (mode == .partition) ? "Free (Included)" : "\(dedicatedPriceString) (Dedicated)"

        if mode == .dedicated && dedicatedQuotaTB == 3 {
            let checkoutURL = "https://api.zerodrive.dev/v1/billing/checkout?tier=promax"
            if let url = URL(string: checkoutURL) {
                NSWorkspace.shared.open(url)
            }
        }

        Task {
            do {
                try await manageDrives.addDrive(
                    name: driveName,
                    quotaGB: finalQuotaGB,
                    provisioningMode: mode.rawValue,
                    targetLocation: targetLocation.rawValue,
                    priceLabel: priceTag
                )
                onDriveCreated?(driveName)
                isPresented = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
