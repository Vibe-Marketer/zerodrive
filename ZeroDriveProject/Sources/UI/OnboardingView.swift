import SwiftUI
import AppKit

public struct OnboardingView: View {
    @EnvironmentObject var lifecycleController: AppLifecycleController
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor

    private enum Step {
        case planSelection
        case cloudflareSetup
        case licenseActivation
        case permissionsSetup
    }

    @State private var currentStep: Step = .planSelection

    // Cloudflare Free 10GB Fields
    @State private var cfEmail: String = ""
    @State private var cfAccountId: String = ""
    @State private var cfAccessKeyId: String = ""
    @State private var cfSecretAccessKey: String = ""
    @State private var cfBucketName: String = "zerodrive-vault-free"

    // Paid / License Key Fields
    @State private var paidEmail: String = ""
    @State private var paidLicenseKey: String = ""

    @State private var isWorking: Bool = false
    @State private var errorMessage: String = ""

    public init() {}

    public var body: some View {
        Group {
            switch currentStep {
            case .planSelection:
                planSelectionView
            case .cloudflareSetup:
                cloudflareSetupView
            case .licenseActivation:
                licenseActivationView
            case .permissionsSetup:
                permissionsSetupView
            }
        }
        .frame(width: 580)
        .padding(24)
    }

    // MARK: - Step 1: Payment & Plan Selection Screen

    private var planSelectionView: some View {
        VStack(spacing: 18) {
            // Header
            VStack(spacing: 6) {
                Image(systemName: "externaldrive.fill.badge.icloud")
                    .font(.system(size: 38))
                    .foregroundStyle(Color.accentColor)

                Text("Welcome to ZeroDrive")
                    .font(.title2.bold())

                Text("Your 24/7 cloud drive directly in Finder, terminal, and AI agents.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 4)

            // Paid Tier Pricing Cards
            HStack(spacing: 14) {
                OnboardingPlanCard(
                    title: "Creator",
                    price: "$29/mo",
                    subprice: "$197/year (Save 43%)",
                    badge: "RECOMMENDED",
                    isFeatured: true,
                    features: [
                        "512 GB DFY Cloud Storage",
                        "Multi-Drive Finder Isolation (Work + Personal)",
                        "4 Machine Slots (Macs + Cloud Agents)",
                        "24/7 Agent MCP Token for Claude & Cursor",
                        "Zero-config setup (no API keys required)"
                    ],
                    onSelect: {
                        openStripeCheckout(tier: "creator")
                        currentStep = .licenseActivation
                    }
                )

                OnboardingPlanCard(
                    title: "Studio",
                    price: "$49/mo",
                    subprice: "$397/year",
                    badge: "UNLIMITED",
                    isFeatured: false,
                    features: [
                        "1 TB DFY Cloud Storage",
                        "Unlimited Independent Vault Drives",
                        "Unlimited Connected Machines",
                        "Multi-Node Fleet Rendering",
                        "Priority bandwidth & Agent Skill Registry"
                    ],
                    onSelect: {
                        openStripeCheckout(tier: "studio")
                        currentStep = .licenseActivation
                    }
                )
            }

            // License key shortcut
            Button("Already have a license key? Enter key…") {
                currentStep = .licenseActivation
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            // Divider to Free Tier
            HStack {
                Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1)
                Text("OR START FREE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1)
            }
            .padding(.vertical, 2)

            // Install Free with 10GB Cloudflare Button
            Button {
                currentStep = .cloudflareSetup
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "cloud.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Deploy Free with Cloudflare (10 GB)")
                                .font(.body.bold())
                                .foregroundStyle(.primary)
                            Text("FREE FOREVER")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.18))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        }
                        Text("Sign In with Cloudflare to mount 10 GB free cloud storage directly in Finder.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            HStack {
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
            }
        }
    }

public struct OnboardingPlanCard: View {
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
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            priceRow
            Divider()
            featureRows
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

    private var priceRow: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(price).font(.title2.bold())
            Text(subprice).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var featureRows: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(features, id: \.self) { feat in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
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

    // MARK: - Step 2: Automatic / Guided Cloudflare Connection (Free 10GB)

    @State private var showCustomR2Keys: Bool = false

    private var cloudflareSetupView: some View {
        VStack(spacing: 16) {
            HStack {
                Button {
                    currentStep = .planSelection
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back to Plans")
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)

                Spacer()
            }

            VStack(spacing: 6) {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)

                Text("Deploy Free Cloudflare Vault (10 GB)")
                    .font(.title3.bold())

                Text("ZeroDrive provisions an isolated 10 GB partition on Cloudflare R2 with zero egress fees and mounts it directly into macOS Finder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your Account Email")
                        .font(.caption.bold())
                    TextField("you@example.com", text: $cfEmail)
                        .textFieldStyle(.roundedBorder)
                }

                // Trusted Cloudflare Sign In / Deploy Action
                Button {
                    Task { await connect1ClickCloudflare() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "cloud.fill")
                            .foregroundStyle(.orange)
                        Text(isWorking ? "Deploying Vault…" : "Sign In with Cloudflare")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isWorking || cfEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                // Advanced manual R2 keys disclosure
                DisclosureGroup("Advanced: Use Custom Cloudflare Keys", isExpanded: $showCustomR2Keys) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Cloudflare Account ID", text: $cfAccountId)
                            .textFieldStyle(.roundedBorder)
                        TextField("R2 Access Key ID", text: $cfAccessKeyId)
                            .textFieldStyle(.roundedBorder)
                        SecureField("R2 Secret Access Key", text: $cfSecretAccessKey)
                            .textFieldStyle(.roundedBorder)
                        TextField("R2 Bucket Name", text: $cfBucketName)
                            .textFieldStyle(.roundedBorder)

                        Button("Connect with Custom Keys") {
                            Task { await connectFreeCloudflare() }
                        }
                        .controlSize(.small)
                        .disabled(isWorking || cfAccessKeyId.isEmpty || cfSecretAccessKey.isEmpty)
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 420)

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            HStack {
                Button("Cancel") {
                    currentStep = .planSelection
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
            }
            .frame(maxWidth: 420)
        }
    }

    // MARK: - Step 3: Paid License Key Activation

    private var licenseActivationView: some View {
        VStack(spacing: 16) {
            HStack {
                Button {
                    currentStep = .planSelection
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back to Plans")
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)

                Spacer()
            }

            VStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)

                Text("Activate ZeroDrive Paid Subscription")
                    .font(.title3.bold())

                Text("Enter the email address and license key you received after checkout.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Account Email")
                        .font(.caption.bold())
                    TextField("you@example.com", text: $paidEmail)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Master License Key")
                        .font(.caption.bold())
                    TextField("zd_live_creator_...", text: $paidLicenseKey)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .frame(maxWidth: 380)

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            HStack {
                Button("Cancel") {
                    currentStep = .planSelection
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    Task { await activatePaidVault() }
                } label: {
                    Text(isWorking ? "Provisioning…" : "Activate & Mount Drive")
                        .bold()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || paidEmail.isEmpty)
            }
            .frame(maxWidth: 380)
        }
    }

    // MARK: - Actions

    private func connect1ClickCloudflare() async {
        let cleanEmail = cfEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleanEmail.contains("@") && cleanEmail.contains(".") else {
            errorMessage = "Please enter a valid email address."
            return
        }

        isWorking = true
        errorMessage = ""

        do {
            try await ManageLicensing.shared.provisionFreeCloudflare(email: cleanEmail)
            isWorking = false
            currentStep = .permissionsSetup
        } catch {
            isWorking = false
            errorMessage = "Cloudflare deployment failed: \(error.localizedDescription)"
        }
    }

    private func connectFreeCloudflare() async {
        let cleanEmail = cfEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleanEmail.contains("@") && cleanEmail.contains(".") else {
            errorMessage = "Please enter a valid email address."
            return
        }

        isWorking = true
        errorMessage = ""

        let accountId = cfAccountId.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = accountId.isEmpty
            ? "https://auto.r2.cloudflarestorage.com"
            : "https://\(accountId).r2.cloudflarestorage.com"
        let bucket = cfBucketName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "zerodrive-vault-free"
            : cfBucketName.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try MultiCloudCombineBuilder.shared.configureBYOKPrimaryVault(
                preset: .cloudflareR2,
                bucket: bucket,
                accessKey: cfAccessKeyId.trimmingCharacters(in: .whitespacesAndNewlines),
                secretKey: cfSecretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines),
                endpoint: endpoint,
                region: "auto",
                spoolCapGB: 10
            )

            // Save license record as Free Starter with 10GB quota
            let record = LicenseRecord(
                email: cleanEmail,
                licenseKey: "zd_free_10gb_\(UUID().uuidString.prefix(8).lowercased())",
                tier: "Free Starter",
                quotaTB: 0.01, // 10 GB
                status: "Active (Free Tier)",
                hardwareUUID: ManageLicensing.getHardwareUUID(),
                machineName: Host.current().localizedName ?? "Mac",
                activatedAt: Date(),
                isProvisioned: true
            )
            ManageLicensing.shared.saveLicenseRecord(record)

            await supervisor.forceCleanAndRemount()
            isWorking = false
            currentStep = .permissionsSetup
        } catch {
            isWorking = false
            errorMessage = "Failed to connect Cloudflare R2: \(error.localizedDescription)"
        }
    }

    private func activatePaidVault() async {
        let cleanEmail = paidEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleanEmail.contains("@") && cleanEmail.contains(".") else {
            errorMessage = "Please enter a valid email address."
            return
        }

        isWorking = true
        errorMessage = ""

        do {
            try await ManageLicensing.shared.loginAndProvision(
                email: cleanEmail,
                licenseKey: paidLicenseKey.isEmpty ? nil : paidLicenseKey,
                spoolCapGB: 50
            )
            isWorking = false
            currentStep = .permissionsSetup
        } catch {
            isWorking = false
            errorMessage = "Activation failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Step 4: One-Time Permissions Setup

    private var permissionsSetupView: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)

                Text("One-Time Finder Setup")
                    .font(.title2.bold())

                Text("macOS will ask for one-time permission to allow ZeroDrive to display your cloud files as a native drive in Finder.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .padding(.top, 6)

            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: "externaldrive.badge.icloud")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Virtual Drive Access")
                            .font(.subheadline.bold())
                        Text("Streams files instantly without taking up your Mac's internal storage.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .padding(12)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 14) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local Streaming Engine")
                            .font(.subheadline.bold())
                        Text("High-speed background caching directly on your Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .padding(12)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 6)

            VStack(spacing: 10) {
                Button {
                    finishPermissionsAndOpen()
                } label: {
                    HStack {
                        Text("Complete Setup & Open Finder")
                            .bold()
                        Image(systemName: "arrow.right")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("macOS only asks once. Click **Allow** or **OK** on the system prompt.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
    }

    private func finishPermissionsAndOpen() {
        let userSymlink = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("ZeroDrive")
        _ = FileManager.default.fileExists(atPath: userSymlink.path)
        lifecycleController.showOnboardingSheet = false
        supervisor.openInFinder()
    }

    private func openStripeCheckout(tier: String) {
        let checkoutURL = "https://api.zerodrive.dev/v1/billing/checkout?tier=\(tier)"
        if let url = URL(string: checkoutURL) {
            NSWorkspace.shared.open(url)
        }
    }
}
