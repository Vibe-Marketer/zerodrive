import SwiftUI
import AppKit

public struct AccountLicensingView: View {
    @ObservedObject private var licensing = ManageLicensing.shared
    @ObservedObject private var manageDrives = ManageDrives.shared
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor
    @ObservedObject private var vaultStats = VaultStats.shared

    @State private var inputKey: String = ""
    @State private var inputEmail: String = ""
    @State private var isShowingKeyInput: Bool = false
    @State private var isShowingSwitchAccountSheet: Bool = false
    @State private var isShowingAddDriveSheet: Bool = false
    @State private var isShowingUpgradePrompt: Bool = false
    @State private var upgradePromptReason: String = ""
    @State private var newDriveName: String = ""
    @State private var newDriveQuotaGB: Double = 100.0
    @State private var feedbackMessage: String = ""
    @State private var driveActionFeedback: String = ""
    @State private var isShowingBYOKSheet: Bool = false
    @State private var showKeyManager: Bool = false
    @State private var issueClientEmail: String = ""
    @State private var issuePlanTier: String = "pro"
    @State private var issuedLicenseKey: String = ""
    @State private var managedKeys: [ManagedLicenseInfo] = []
    @State private var isManagingKeys: Bool = false

    public init() {}

    private var isFreeTier: Bool {
        let t = licensing.license.tier.lowercased()
        return t.contains("free") || t.contains("starter")
    }

    public var body: some View {
        Form {
            // MARK: - 1. License & Subscription Status
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 34))
                            .foregroundStyle(Color.accentColor)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(licensing.license.email.isEmpty ? "ZeroDrive Account" : licensing.license.email)
                                    .font(.title3.bold())
                                Text(licensing.license.tier)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(isFreeTier ? Color.secondary.opacity(0.18) : Color.accentColor.opacity(0.15))
                                    .foregroundStyle(isFreeTier ? Color.primary : Color.accentColor)
                                    .clipShape(Capsule())
                            }

                            Text("Status: \(licensing.license.status) • Machine Activated")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if isFreeTier {
                            Button {
                                upgradePromptReason = "Upgrade to ZeroDrive Pro (1 TB) or Agency (10 TB) to unlock managed storage, free drive partitioning, and 24/7 Agent MCP access."
                                isShowingUpgradePrompt = true
                            } label: {
                                Label("Upgrade to Pro / Agency", systemImage: "sparkles")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        Button("Sign Out") {
                            licensing.signOut()
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }

                    // Quota and Device Slots
                    HStack(spacing: 12) {
                        statPill(
                            title: "CLOUD STORAGE QUOTA",
                            value: licensing.license.quotaTB < 0.1
                                ? String(format: "%.0f GB", licensing.license.quotaTB * 1024)
                                : String(format: "%.1f TB", licensing.license.quotaTB),
                            subtitle: isFreeTier ? "Cloudflare R2 Free Tier" : "Unlimited throughput",
                            color: .primary
                        )

                        statPill(
                            title: "ACTIVATED MACHINES",
                            value: isFreeTier ? "1 of 2 Slots" : "Unlimited Slots",
                            subtitle: licensing.license.machineName,
                            color: .green
                        )

                        statPill(
                            title: "PROVISIONING",
                            value: licensing.license.isProvisioned ? "Operational" : "Pending",
                            subtitle: isFreeTier ? "BYOK Cloudflare" : "ZeroDrive Cloud Vault",
                            color: licensing.license.isProvisioned ? .green : .orange
                        )
                    }
                }
                .padding(.vertical, 4)
            }

            // MARK: - 2. Multi-Drive & Sub-Vaults
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Vault Drives & Sub-Drives (\(manageDrives.drives.count))")
                                .font(.body.weight(.semibold))
                            Text("Provision and mount multiple independent drives into Finder (e.g. Work, Clients, Archives).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            let check = manageDrives.canAddDrive()
                            if check.allowed {
                                newDriveName = ""
                                isShowingAddDriveSheet = true
                            } else {
                                upgradePromptReason = check.reason
                                isShowingUpgradePrompt = true
                            }
                        } label: {
                            Label("Add Drive", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    Divider()

                    ForEach(manageDrives.drives) { drive in
                        HStack(spacing: 12) {
                            Image(systemName: drive.isDefault ? "externaldrive.fill.badge.checkmark" : "folder.badge.gearshape")
                                .font(.title3)
                                .foregroundStyle(drive.isDefault ? Color.accentColor : Color.blue)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(drive.name)
                                        .font(.body.weight(.medium))
                                    if drive.isDefault {
                                        Text("PRIMARY")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background(Color.accentColor.opacity(0.14))
                                            .foregroundStyle(Color.accentColor)
                                            .clipShape(Capsule())
                                    }
                                }

                                Text(drive.isDefault
                                     ? "Root Finder Mount • Shared Cloud Storage"
                                     : "Isolated Sub-Vault • \(Int(drive.quotaGB)) GB Quota • drives/\(drive.id)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button("Open in Finder") {
                                let folderName = drive.isDefault ? "My Drive" : drive.name
                                let url = supervisor.mountPoint.appendingPathComponent(folderName)
                                supervisor.openInFinder(url)
                            }
                            .controlSize(.small)

                            if !drive.isDefault {
                                Button("Remove") {
                                    Task {
                                        do {
                                            try await manageDrives.removeDrive(id: drive.id)
                                            driveActionFeedback = "Drive '\(drive.name)' removed."
                                        } catch {
                                            driveActionFeedback = error.localizedDescription
                                        }
                                    }
                                }
                                .controlSize(.small)
                                .foregroundStyle(.red)
                            }
                        }
                        .padding(.vertical, 3)
                    }

                    if !driveActionFeedback.isEmpty {
                        Text(driveActionFeedback)
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("ZeroDrive Multi-Drive Isolation")
            }

            // MARK: - 3. Secure License Keys & Management
            Section("Secure License Key & Key Management") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Active License Key")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(maskedLicenseKey(licensing.license.licenseKey))
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        }

                        Spacer()

                        Button("Copy Key") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(licensing.license.licenseKey, forType: .string)
                        }
                        .controlSize(.small)

                        Button("Activate Key…") {
                            isShowingKeyInput.toggle()
                        }
                        .controlSize(.small)

                        Button(showKeyManager ? "Hide Manager" : "Manage Keys") {
                            showKeyManager.toggle()
                            if showKeyManager {
                                Task {
                                    managedKeys = (try? await DFYProvisioningClient.shared.listManagedLicenseKeys()) ?? []
                                }
                            }
                        }
                        .controlSize(.small)
                    }

                    if isShowingKeyInput {
                        HStack {
                            TextField("Enter license key (ZD-PRO-... or ZD-AGY-...)", text: $inputKey)
                                .textFieldStyle(.roundedBorder)

                            Button("Activate") {
                                Task {
                                    do {
                                        try await licensing.activateLicenseKey(inputKey, email: licensing.license.email)
                                        isShowingKeyInput = false
                                        inputKey = ""
                                        feedbackMessage = "License key verified and activated!"
                                    } catch {
                                        feedbackMessage = error.localizedDescription
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(inputKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    if showKeyManager {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Issue New Client License Key")
                                .font(.caption.bold())

                            HStack(spacing: 8) {
                                TextField("Client email (optional)", text: $issueClientEmail)
                                    .textFieldStyle(.roundedBorder)

                                Picker("Plan", selection: $issuePlanTier) {
                                    Text("Pro (1 TB)").tag("pro")
                                    Text("Agency (10 TB)").tag("agency")
                                }
                                .labelsHidden()
                                .frame(width: 130)

                                Button {
                                    Task {
                                        isManagingKeys = true
                                        do {
                                            let res = try await DFYProvisioningClient.shared.generateManagedLicenseKey(
                                                tier: issuePlanTier,
                                                clientEmail: issueClientEmail
                                            )
                                            if let key = res.license_key {
                                                issuedLicenseKey = key
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(key, forType: .string)
                                                feedbackMessage = "Generated & copied key: \(key)"
                                                managedKeys = (try? await DFYProvisioningClient.shared.listManagedLicenseKeys()) ?? managedKeys
                                            }
                                        } catch {
                                            feedbackMessage = error.localizedDescription
                                        }
                                        isManagingKeys = false
                                    }
                                } label: {
                                    Text(isManagingKeys ? "Issuing…" : "Generate Key")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(isManagingKeys)
                            }

                            if !issuedLicenseKey.isEmpty {
                                HStack {
                                    Text(issuedLicenseKey)
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.green)
                                    Spacer()
                                    Button("Copy") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(issuedLicenseKey, forType: .string)
                                    }
                                    .controlSize(.mini)
                                }
                                .padding(6)
                                .background(Color.green.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }

                            if !managedKeys.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Issued Keys (\(managedKeys.count))")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.secondary)
                                    ForEach(managedKeys.prefix(6)) { item in
                                        HStack(spacing: 8) {
                                            Text(item.license_key)
                                                .font(.system(size: 10, design: .monospaced))
                                            Text(item.tier.uppercased())
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(.secondary)
                                            if let email = item.customer_email, !email.isEmpty {
                                                Text(email)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            Spacer()
                                            Text(item.status)
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(item.status == "active" ? .green : .red)
                                            if item.status == "active" {
                                                Button("Revoke") {
                                                    Task {
                                                        _ = try? await DFYProvisioningClient.shared.revokeManagedLicenseKey(licenseKey: item.license_key)
                                                        managedKeys = (try? await DFYProvisioningClient.shared.listManagedLicenseKeys()) ?? []
                                                    }
                                                }
                                                .controlSize(.mini)
                                                .foregroundStyle(.red)
                                            }
                                        }
                                        .padding(.vertical, 2)
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    if !feedbackMessage.isEmpty {
                        Text(feedbackMessage)
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.vertical, 2)
            }

            // MARK: - 4. Machine Hardware Binding
            Section("Device Provisioning & Hardware UUID") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Device Hardware UUID")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(licensing.license.hardwareUUID)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                    }

                    HStack {
                        Text("Provisioned Mount Point")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(supervisor.mountPoint.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Finder Integration")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("ZeroDrive Unified (NFS + Apple FileProvider)")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                .padding(.vertical, 2)
            }

            // MARK: - 5. Account Management & Upgrade
            Section("Account Management & Upgrade") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Upgrade to Pro or Agency")
                                .font(.body.weight(.medium))
                            Text("Choose Pro ($29/mo • 1 TB) or Agency ($497/mo • 10 TB), or activate a license key.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            upgradePromptReason = "Choose ZeroDrive Pro ($29/mo, 1 TB) or Agency ($497/mo, 10 TB) for zero-config managed storage and 24/7 hosted MCP."
                            isShowingUpgradePrompt = true
                        } label: {
                            Label("View Plans & Upgrade…", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Switch Account")
                                .font(.body.weight(.medium))
                            Text("Sign in with Google to switch accounts or provision a new segregated drive.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Switch Account…") {
                            isShowingSwitchAccountSheet = true
                        }
                        .controlSize(.regular)
                    }

                    Divider()

                    Button {
                        isShowingBYOKSheet = true
                    } label: {
                        Text("Using your own Cloudflare R2 bucket? Configure Free BYOK API keys →")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Account & Licensing")
        .sheet(isPresented: $isShowingSwitchAccountSheet) {
            switchAccountModal
        }
        .sheet(isPresented: $isShowingBYOKSheet) {
            UpgradePromptSheet(initialBYOKMode: true)
        }
        .sheet(isPresented: $isShowingAddDriveSheet) {
            AddNewDriveSheet(isPresented: $isShowingAddDriveSheet) { createdName in
                driveActionFeedback = "Drive '\(createdName)' provisioned and mounted!"
            }
        }
        .sheet(isPresented: $isShowingUpgradePrompt) {
            UpgradePromptSheet(triggerReason: upgradePromptReason, requiredTier: "Pro")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenUpgradeAccountModal"))) { _ in
            upgradePromptReason = "Choose ZeroDrive Pro ($29/mo, 1 TB) or Agency ($497/mo, 10 TB) for zero-config managed storage and 24/7 hosted MCP."
            isShowingUpgradePrompt = true
        }
    }

    private var addDriveModal: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 32))
                .foregroundStyle(Color.accentColor)

            Text("Add New Drive")
                .font(.title3.bold())

            Text("Creates an isolated secondary drive in your Cloud Vault with its own dedicated folder in Finder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Drive Name")
                        .font(.caption.bold())
                    TextField("e.g. Work, Clients, Archive", text: $newDriveName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Storage Quota")
                            .font(.caption.bold())
                        Spacer()
                        Text("\(Int(newDriveQuotaGB)) GB")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $newDriveQuotaGB, in: 10...1000, step: 10)
                }
            }
            .frame(maxWidth: 320)

            HStack {
                Button("Cancel") {
                    isShowingAddDriveSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Create & Mount Drive") {
                    Task {
                        do {
                            try await manageDrives.addDrive(name: newDriveName, quotaGB: newDriveQuotaGB)
                            isShowingAddDriveSheet = false
                            driveActionFeedback = "Drive '\(newDriveName)' created and mounted!"
                        } catch {
                            driveActionFeedback = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newDriveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manageDrives.isWorking)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private var switchAccountModal: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 32))
                .foregroundStyle(Color.accentColor)

            Text("Sign In or Switch Account")
                .font(.title3.bold())

            Text("Sign in with Google to restore an existing account or create a brand-new segregated Cloud Vault.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Button {
                isShowingSwitchAccountSheet = false
                licensing.startGoogleSignIn()
                AppLifecycleController.shared.onboardingRequestedStep = 0
                AppLifecycleController.shared.showOnboardingSheet = true
            } label: {
                HStack(spacing: 8) {
                    Text("G")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .frame(width: 20, height: 20)
                        .background(Color.white)
                        .foregroundStyle(Color.black)
                        .clipShape(Circle())
                    Text("Sign in with Google")
                        .font(.subheadline.bold())
                }
                .frame(maxWidth: 320)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Divider().frame(maxWidth: 320)

            TextField("Or enter email address manually", text: $inputEmail)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)

            HStack {
                Button("Cancel") {
                    isShowingSwitchAccountSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Login & Provision") {
                    Task {
                        try? await licensing.loginAndProvision(email: inputEmail)
                        isShowingSwitchAccountSheet = false
                        inputEmail = ""
                    }
                }
                .buttonStyle(.bordered)
                .disabled(inputEmail.isEmpty || !inputEmail.contains("@"))
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func maskedLicenseKey(_ key: String) -> String {
        guard key.count > 12 else { return key.isEmpty ? "No Key Active" : key }
        let prefix = key.prefix(10)
        let suffix = key.suffix(4)
        return "\(prefix)••••••••\(suffix)"
    }

    private func statPill(title: String, value: String, subtitle: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.bold())
                .foregroundStyle(color)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
