import SwiftUI
import AppKit

public struct UpgradePromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    public var triggerReason: String
    public var requiredTier: String
    public var initialBYOKMode: Bool

    @State private var showKeyInput: Bool = false
    @State private var licenseKeyInput: String = ""
    @State private var keyError: String = ""
    @State private var isActivatingKey: Bool = false

    @State private var showBYOKSetup: Bool = false
    @State private var cfAccountId: String = ""
    @State private var cfAccessKeyId: String = ""
    @State private var cfSecretAccessKey: String = ""
    @State private var cfBucketName: String = "zerodrive-byok"
    @State private var byokError: String = ""
    @State private var isConnectingBYOK: Bool = false

    public init(
        triggerReason: String = "Choose ZeroDrive Pro ($29/mo, 1 TB) or Agency ($497/mo, 10 TB) for zero-config managed storage and 24/7 hosted MCP.",
        requiredTier: String = "Pro",
        initialBYOKMode: Bool = false
    ) {
        self.triggerReason = triggerReason
        self.requiredTier = requiredTier
        self.initialBYOKMode = initialBYOKMode
        self._showBYOKSetup = State(initialValue: initialBYOKMode)
    }

    public var body: some View {
        Group {
            if showBYOKSetup {
                byokSetupContent
            } else {
                planSelectionContent
            }
        }
        .padding(24)
        .frame(width: 580)
    }

    private var planSelectionContent: some View {
        VStack(spacing: 18) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.accentColor)

                Text(requiredTier.isEmpty ? "Upgrade to ZeroDrive Pro or Agency" : "Upgrade to ZeroDrive \(requiredTier) or Agency")
                    .font(.title2.bold())

                Text(triggerReason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            .padding(.top, 4)

            // Tier Cards: Two Primary Plans (Pro & Agency)
            HStack(spacing: 14) {
                UpgradeTierCard(
                    title: "Pro",
                    price: "$29/mo",
                    subprice: "or $197/year (Save 43%)",
                    badge: "MOST POPULAR",
                    isFeatured: true,
                    features: [
                        "1 TB DFY Cloud Storage (Zero config)",
                        "Free Drive Partitioning (Work, Clients, Personal)",
                        "Unlimited Computers (Mac, Windows, Cloud Servers)",
                        "24/7 Hosted Agent MCP + API Access",
                        "High-speed cloud-to-cloud streaming"
                    ],
                    onSelect: {
                        openStripeCheckout(tier: "pro")
                        dismiss()
                    }
                )

                UpgradeTierCard(
                    title: "Agency",
                    price: "$497/mo",
                    subprice: "or $4,970/year",
                    badge: "WHITE-LABEL",
                    isFeatured: false,
                    features: [
                        "10 TB DFY Cloud Storage (+$25/TB add-on)",
                        "Unlimited Segregated Client Vaults",
                        "White-Label Custom Domains & Team MCP",
                        "Unlimited Machines & 5 Team Seats",
                        "Client License Key Issuance & Controls"
                    ],
                    onSelect: {
                        openStripeCheckout(tier: "agency")
                        dismiss()
                    }
                )
            }
            .frame(maxWidth: .infinity)

            // Inline License Key Activation
            VStack(spacing: 8) {
                Button(showKeyInput ? "Hide License Key Entry" : "Already have a license key? Enter Key…") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showKeyInput.toggle()
                        keyError = ""
                    }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                if showKeyInput {
                    HStack(spacing: 8) {
                        TextField("ZD-PRO-XXXX-XXXX-XXXXXXXX or ZD-AGY-...", text: $licenseKeyInput)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            Task { await activateInlineLicenseKey() }
                        } label: {
                            Text(isActivatingKey ? "Activating…" : "Activate Key")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isActivatingKey || licenseKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .frame(maxWidth: 460)

                    if !keyError.isEmpty {
                        Text(keyError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            // Primary Actions
            HStack(spacing: 12) {
                Button("Not Now") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.regular)

                Button {
                    openStripeCheckout(tier: "pro")
                    dismiss()
                } label: {
                    Label("Upgrade to Pro ($29/mo)", systemImage: "bolt.fill")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }

            Divider()

            // Subtle Free BYOK Subline
            Button {
                byokError = ""
                withAnimation(.easeInOut(duration: 0.15)) {
                    showBYOKSetup = true
                }
            } label: {
                Text("Want to use your own Cloudflare R2 bucket for free (10 GB)? Connect Cloudflare R2 API keys →")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var byokSetupContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button {
                    byokError = ""
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showBYOKSetup = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back to Pro & Agency Plans")
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)

                Spacer()

                Button {
                    if let url = URL(string: "https://dash.cloudflare.com/?to=/:account/r2/api-tokens") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("Open Cloudflare R2 API Tokens Dashboard ↗")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 6) {
                Image(systemName: "key.icloud.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)

                Text("Free Tier — Connect Your Own Cloudflare R2 (BYOK)")
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)

                Text("Use your own Cloudflare account's 10 GB free R2 tier with local MCP access. Enter your Cloudflare R2 S3 API credentials below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cloudflare Account ID")
                        .font(.caption.bold())
                    TextField("32-character Account ID", text: $cfAccountId)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("R2 Access Key ID")
                        .font(.caption.bold())
                    TextField("Cloudflare R2 Access Key ID", text: $cfAccessKeyId)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("R2 Secret Access Key")
                        .font(.caption.bold())
                    SecureField("Cloudflare R2 Secret Access Key", text: $cfSecretAccessKey)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("R2 Bucket Name")
                        .font(.caption.bold())
                    TextField("zerodrive-byok", text: $cfBucketName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if !byokError.isEmpty {
                Text(byokError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    Task { await connectBYOKCloudflare() }
                } label: {
                    HStack(spacing: 6) {
                        if isConnectingBYOK {
                            ProgressView().controlSize(.small)
                            Text("Connecting R2…")
                        } else {
                            Text("Connect Cloudflare R2 & Mount Drive")
                                .bold()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isConnectingBYOK ||
                    cfAccountId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    cfAccessKeyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    cfSecretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
    }

    private func activateInlineLicenseKey() async {
        let trimmed = licenseKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isActivatingKey = true
        keyError = ""
        do {
            try await ManageLicensing.shared.activateLicenseKey(trimmed, email: ManageLicensing.shared.license.email)
            isActivatingKey = false
            dismiss()
        } catch {
            isActivatingKey = false
            keyError = error.localizedDescription
        }
    }

    private func connectBYOKCloudflare() async {
        let cleanAccount = cfAccountId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAccess = cfAccessKeyId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSecret = cfSecretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBucket = cfBucketName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBucket = rawBucket.isEmpty ? "zerodrive-byok" : rawBucket

        guard !cleanAccount.isEmpty, !cleanAccess.isEmpty, !cleanSecret.isEmpty else {
            byokError = "Cloudflare Account ID, R2 Access Key ID, and R2 Secret Access Key are required."
            return
        }

        isConnectingBYOK = true
        byokError = ""

        do {
            try MultiCloudCombineBuilder.shared.configureBYOKPrimaryVault(
                preset: .cloudflareR2,
                bucket: cleanBucket,
                accessKey: cleanAccess,
                secretKey: cleanSecret,
                endpoint: "https://\(cleanAccount).r2.cloudflarestorage.com",
                region: "auto",
                spoolCapGB: 10
            )

            let existingEmail = ManageLicensing.shared.license.email
            let resolvedEmail = existingEmail.isEmpty ? "byok@local.zerodrive" : existingEmail
            let record = LicenseRecord(
                email: resolvedEmail,
                licenseKey: "zd_byok_free_\(UUID().uuidString.prefix(8).lowercased())",
                tier: "Free Starter (BYOK)",
                quotaTB: 0.01,
                status: "Active (BYOK Cloudflare R2)",
                hardwareUUID: ManageLicensing.getHardwareUUID(),
                machineName: Host.current().localizedName ?? "Mac",
                activatedAt: Date(),
                isProvisioned: true
            )
            ManageLicensing.shared.applyProvisionedRecord(record)

            Task { @MainActor in
                await RcloneDaemonSupervisor.shared.forceCleanAndRemount()
                RcloneDaemonSupervisor.shared.pinToFinderSidebarIfNeeded()
                await ManageFileProvider.shared.registerDomainIfNeeded()
            }

            isConnectingBYOK = false
            dismiss()
        } catch {
            isConnectingBYOK = false
            byokError = "Failed to connect Cloudflare R2: \(error.localizedDescription)"
        }
    }

    private func openStripeCheckout(tier: String) {
        let emailParam = ManageLicensing.shared.license.email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var checkoutURL = "https://api.zerodrive.dev/v1/billing/checkout?tier=\(tier)"
        if !emailParam.isEmpty {
            checkoutURL += "&email=\(emailParam)"
        }
        if let url = URL(string: checkoutURL) {
            NSWorkspace.shared.open(url)
        }
    }
}

public struct UpgradeTierCard: View {
    public let title: String
    public let price: String
    public let subprice: String
    public let badge: String
    public let isFeatured: Bool
    public let features: [String]
    public let onSelect: () -> Void

    public var body: some View {
        cardContent
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(cardBorder)
    }

    private var cardBackground: some View {
        isFeatured ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(isFeatured ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: isFeatured ? 2 : 1)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            priceSection
            Divider()
            featureList
            Spacer()
            actionButton
        }
    }

    private var headerRow: some View {
        HStack {
            Text(title).font(.headline.bold())
            Spacer()
            Text(badge)
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isFeatured ? Color.accentColor : Color.secondary.opacity(0.2))
                .foregroundStyle(isFeatured ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
    }

    private var priceSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(price).font(.title.bold())
            Text(subprice).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(features, id: \.self) { feat in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(isFeatured ? Color.accentColor : Color.green)
                    Text(feat)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        let label = "Select " + title
        if isFeatured {
            Button(action: onSelect) {
                Text(label)
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        } else {
            Button(action: onSelect) {
                Text(label)
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
