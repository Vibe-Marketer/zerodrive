import SwiftUI
import AppKit

public struct OnboardingView: View {
    @EnvironmentObject var lifecycleController: AppLifecycleController
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor
    @ObservedObject private var setup = ManageOnboardingSetup.shared
    @ObservedObject private var advisor = ManageStorageAdvisor.shared
    @ObservedObject private var licensing = ManageLicensing.shared

    private enum Step: Int {
        case loginOrSignup = 0
        case planSelection = 10
        case freeTierSetup = 11
        case licenseActivation = 12
        case installAndPermissions = 1
        case cloudDiscovery = 2
        case scanAndReady = 3

        var wizardIndex: Int {
            switch self {
            case .loginOrSignup, .planSelection, .freeTierSetup, .licenseActivation:
                return 0
            case .installAndPermissions:
                return 1
            case .cloudDiscovery:
                return 2
            case .scanAndReady:
                return 3
            }
        }
    }

    @State private var currentStep: Step = .loginOrSignup
    @State private var loginEmail: String = ""
    @FocusState private var isLoginEmailFocused: Bool

    // Cloudflare Free 10GB Fields
    @State private var cfEmail: String = ""
    @State private var cfAccountId: String = ""
    @State private var cfAccessKeyId: String = ""
    @State private var cfSecretAccessKey: String = ""
    @State private var cfBucketName: String = "zerodrive-vault-free"
    @State private var showAdvancedBYOK: Bool = false

    // Paid / License Key Fields
    @State private var paidEmail: String = ""
    @State private var paidLicenseKey: String = ""
    @State private var showFallbackEmailSignIn: Bool = false
    @State private var selectedNewAccountPlan: String = "pro"
    @State private var newAccountLicenseKey: String = ""

    // Track if user toggled local clouds on Step 3 so Step 4 rescans cleanly
    @State private var cloudSelectionDirty: Bool = false

    @State private var isWorking: Bool = false
    @State private var errorMessage: String = ""

    public init() {}

    private var activeWizardSteps: [(index: Int, title: String, step: Step)] {
        [
            (0, "1. Sign In", .loginOrSignup),
            (1, "2. Install & Access", .installAndPermissions),
            (2, "3. Your Clouds", .cloudDiscovery),
            (3, "4. Scan & Ready", .scanAndReady)
        ]
    }

    private var formattedReclaimable: String {
        ByteCountFormatter.string(fromByteCount: advisor.totalReclaimableBytes, countStyle: .file)
    }

    private var formattedCloudTotal: String {
        ByteCountFormatter.string(fromByteCount: advisor.totalCloudLogicalBytes, countStyle: .file)
    }

    public var body: some View {
        VStack(spacing: 0) {
            persistentStepperHeader
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 14)

            Divider()

            Group {
                switch currentStep {
                case .loginOrSignup:
                    loginOrSignupView
                case .planSelection:
                    planSelectionView
                case .freeTierSetup:
                    freeTierSetupView
                case .licenseActivation:
                    licenseActivationView
                case .installAndPermissions:
                    installAndPermissionsView
                case .cloudDiscovery:
                    cloudDiscoveryView
                case .scanAndReady:
                    scanAndReadyView
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .frame(width: 680)
        .onAppear {
            prefillSavedEmail()
            setup.refreshChecks()

            if !licensing.isLicensed {
                currentStep = .loginOrSignup
            } else {
                switch lifecycleController.onboardingRequestedStep {
                case 1:
                    currentStep = .installAndPermissions
                case 2:
                    currentStep = .cloudDiscovery
                case 3:
                    currentStep = .scanAndReady
                default:
                    currentStep = .loginOrSignup
                }

                if advisor.items.isEmpty && !advisor.isScanning {
                    advisor.startScan()
                }
                if advisor.cloudItems.isEmpty && !advisor.isCloudScanning {
                    advisor.startCloudScan()
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if currentStep == .loginOrSignup && !licensing.isLicensed {
                    isLoginEmailFocused = true
                }
                AppDelegate.shared?.syncOnboardingHeight()
            }
        }
        .onChange(of: currentStep.rawValue) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                AppDelegate.shared?.syncOnboardingHeight()
            }
        }
        .onChange(of: showAdvancedBYOK) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                AppDelegate.shared?.syncOnboardingHeight()
            }
        }
        .onChange(of: showFallbackEmailSignIn) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                AppDelegate.shared?.syncOnboardingHeight()
            }
        }
        .onChange(of: licensing.isLicensed) { nowLicensed in
            if nowLicensed && currentStep.wizardIndex == 0 {
                prefillSavedEmail()
                beginPostAuthOnboarding()
            }
        }
        .onChange(of: licensing.pendingNewGoogleAccount?.email) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                AppDelegate.shared?.syncOnboardingHeight()
            }
        }
    }

    private func prefillSavedEmail() {
        guard licensing.isLicensed else { return }
        let savedEmail = licensing.license.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !savedEmail.isEmpty && savedEmail.contains("@") else { return }

        loginEmail = savedEmail
        if cfEmail.isEmpty {
            cfEmail = savedEmail
        }
        if paidEmail.isEmpty {
            paidEmail = savedEmail
        }
    }

    // MARK: - Persistent Top Stepper Bar

    private var persistentStepperHeader: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill.badge.icloud")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)

                Text("ZeroDrive Setup")
                    .font(.headline.bold())

                Spacer()

                if licensing.isLicensed && UserDefaults.standard.bool(forKey: "hasCompletedOnboardingV3") {
                    Button("← Dashboard") {
                        lifecycleController.showOnboardingSheet = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(mountStatusColor)
                        .frame(width: 8, height: 8)
                    Text(mountStatusLabel)
                        .font(.caption.bold())
                        .foregroundStyle(mountStatusColor)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(mountStatusColor.opacity(0.12))
                .clipShape(Capsule())
            }

            HStack(spacing: 8) {
                ForEach(activeWizardSteps, id: \.index) { item in
                    let isActive = currentStep.wizardIndex == item.index
                    let isPast = item.index < currentStep.wizardIndex && licensing.isLicensed
                    let canClick = licensing.isLicensed

                    Button {
                        if canClick {
                            errorMessage = ""
                            currentStep = item.step
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isPast {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                            Text(item.title)
                                .font(.caption.bold())
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(
                            isActive
                                ? Color.accentColor.opacity(0.16)
                                : Color.secondary.opacity(0.07)
                        )
                        .foregroundStyle(
                            isActive
                                ? Color.accentColor
                                : (isPast ? Color.primary : Color.secondary)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isActive ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canClick && !isActive)
                }
            }
        }
    }

    private var mountStatusColor: Color {
        if !licensing.isLicensed {
            return .secondary
        }
        if supervisor.isMounted {
            return .green
        }
        return .orange
    }

    private var mountStatusLabel: String {
        if !licensing.isLicensed {
            return "Sign In Required"
        }
        if supervisor.isMounted {
            return "My Drive Mounted"
        }
        return "Mounting My Drive…"
    }

    // MARK: - Step 1: Sign In / Sign Up Screen

    private var loginOrSignupView: some View {
        VStack(spacing: 16) {
            if let pending = licensing.pendingNewGoogleAccount {
                newAccountConfirmationView(pending: pending)
            } else {
                standardGoogleSignInView
            }
        }
    }

    private var standardGoogleSignInView: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Image(systemName: "externaldrive.fill.badge.icloud")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)

                Text("Sign In to ZeroDrive")
                    .font(.title2.bold())

                Text("Sign in with Google to restore your existing drive, or create a brand-new segregated Cloud Vault in Finder.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)

                if licensing.isLicensed && !licensing.license.email.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Signed in as \(licensing.license.email)")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                        Button("Continue to Step 2 →") {
                            setup.refreshChecks()
                            currentStep = .installAndPermissions
                        }
                        .font(.caption.bold())
                        .buttonStyle(.link)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.1))
                    .clipShape(Capsule())
                    .padding(.top, 2)
                }
            }
            .padding(.top, 2)

            VStack(spacing: 12) {
                // PRIMARY: Sign in with Google
                if licensing.isAwaitingGoogleAuth {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Waiting for Google Sign-In in your browser…")
                                .font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        HStack(spacing: 12) {
                            Button("Re-open Browser") {
                                licensing.startGoogleSignIn()
                            }
                            .buttonStyle(.link)
                            .font(.caption)

                            Button("Cancel") {
                                licensing.cancelGoogleSignIn()
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Button {
                        errorMessage = ""
                        licensing.startGoogleSignIn()
                    } label: {
                        HStack(spacing: 10) {
                            Text("G")
                                .font(.system(size: 16, weight: .black, design: .rounded))
                                .frame(width: 24, height: 24)
                                .background(Color.white)
                                .foregroundStyle(Color.black)
                                .clipShape(Circle())
                            Text("Sign in with Google")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                if !licensing.googleAuthError.isEmpty {
                    Text(licensing.googleAuthError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                // Secondary: License Key or Direct Email sign-in
                HStack(spacing: 14) {
                    Button("Activate License Key") {
                        paidEmail = loginEmail
                        errorMessage = ""
                        currentStep = .licenseActivation
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Button("View Pro & Agency Plans") {
                        errorMessage = ""
                        currentStep = .planSelection
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }

                DisclosureGroup("Or sign in manually with email", isExpanded: $showFallbackEmailSignIn) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            TextField("you@example.com", text: $loginEmail)
                                .textFieldStyle(.roundedBorder)
                                .focused($isLoginEmailFocused)
                                .onSubmit {
                                    Task { await handleSignInOrSignUp() }
                                }
                            Button("Continue") {
                                Task { await handleSignInOrSignUp() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isWorking || loginEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }

                HStack(spacing: 16) {
                    Label("Client-Isolated Vault", systemImage: "lock.shield.fill")
                    Label("Zero Local SSD", systemImage: "internaldrive")
                    Label("24/7 Agent MCP", systemImage: "sparkles")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)
            }
            .frame(maxWidth: 440)

            Divider()
                .padding(.horizontal, 20)

            // Minimal Free subline — BYOK Cloudflare R2 API Keys required
            HStack {
                Button {
                    cfEmail = loginEmail
                    errorMessage = ""
                    currentStep = .freeTierSetup
                } label: {
                    Text("Want to self-host for free? Connect your own Cloudflare R2 API keys →")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(licensing.isLicensed ? "Close" : "Quit") {
                    if licensing.isLicensed {
                        lifecycleController.showOnboardingSheet = false
                    } else {
                        NSApp.terminate(nil)
                    }
                }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func newAccountConfirmationView(pending: GoogleAuthSessionStatus) -> some View {
        let pendingEmail = pending.email ?? ""
        return VStack(spacing: 14) {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "person.badge.plus")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    Text("Create New ZeroDrive Account")
                        .font(.title2.bold())
                }

                Text("No existing ZeroDrive account was found for **\(pendingEmail)**. Creating an account provisions a brand-new, strictly segregated Cloud Vault.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 490)
            }

            // Verified Google Badge
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("Google Verified: \(pending.name ?? pendingEmail) (\(pendingEmail))")
                    .font(.caption.bold())
                Spacer()
                Button("Switch Account") {
                    licensing.clearPendingNewGoogleAccount()
                }
                .font(.caption2)
                .buttonStyle(.link)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.green.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 500)

            // Two Primary Plans: PRO & AGENCY
            HStack(spacing: 12) {
                selectablePlanBox(
                    id: "pro",
                    title: "Pro",
                    price: "$29/mo (Reg. $49)",
                    detail: "1 TB Segregated Vault • Free Drive Partitions • Unlimited Computers • 24/7 MCP"
                )
                selectablePlanBox(
                    id: "agency",
                    title: "Agency",
                    price: "$297/mo (Reg. $497)",
                    detail: "10 TB Vault • Unlimited Client Vaults • White-Label MCP • 5 Seats"
                )
            }
            .frame(maxWidth: 500)

            // Optional License Key for Paid Activation
            VStack(alignment: .leading, spacing: 4) {
                Text("Have a License Key? (Optional — activates immediately)")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                TextField("ZD-PRO-XXXX-XXXX-XXXXXXXX or ZD-AGY-...", text: $newAccountLicenseKey)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(maxWidth: 500)

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                Button("Upgrade via Stripe Checkout") {
                    openStripeCheckout(tier: selectedNewAccountPlan, email: pendingEmail)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    Task { await handleConfirmCreateNewAccount() }
                } label: {
                    HStack(spacing: 8) {
                        if isWorking {
                            ProgressView().controlSize(.small)
                            Text("Creating Segregated Vault…")
                        } else {
                            Image(systemName: "lock.shield.fill")
                            Text("Create Segregated Account & Drive →")
                        }
                    }
                    .font(.subheadline.bold())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isWorking)
            }

            // Minimal Free BYOK Subline
            Button {
                cfEmail = pendingEmail
                licensing.clearPendingNewGoogleAccount()
                currentStep = .freeTierSetup
            } label: {
                Text("Prefer Free BYOK? Connect your own Cloudflare R2 API keys instead →")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    private func selectablePlanBox(id: String, title: String, price: String, detail: String) -> some View {
        let isSelected = selectedNewAccountPlan == id
        return Button {
            selectedNewAccountPlan = id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.headline.bold())
                    Spacer()
                    Text(price).font(.subheadline.bold()).foregroundStyle(Color.accentColor)
                }
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func handleConfirmCreateNewAccount() async {
        isWorking = true
        errorMessage = ""
        do {
            try await licensing.confirmCreateNewGoogleAccount(
                plan: selectedNewAccountPlan,
                licenseKey: newAccountLicenseKey.isEmpty ? nil : newAccountLicenseKey
            )
            beginPostAuthOnboarding()
        } catch {
            isWorking = false
            errorMessage = error.localizedDescription
        }
    }

    private func beginPostAuthOnboarding() {
        setup.refreshChecks()
        if !advisor.isScanning {
            advisor.startScan()
        }
        if !advisor.isCloudScanning {
            advisor.startCloudScan()
        }
        isWorking = false
        currentStep = .installAndPermissions
    }

    private func handleSignInOrSignUp() async {
        let cleanEmail = loginEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleanEmail.contains("@") && cleanEmail.contains(".") else {
            errorMessage = "Please enter a valid email address."
            return
        }

        isWorking = true
        errorMessage = ""

        do {
            try await ManageLicensing.shared.loginAndProvision(
                email: cleanEmail,
                mountInBackground: true,
                openFinderOnComplete: false
            )
            beginPostAuthOnboarding()
        } catch {
            isWorking = false
            errorMessage = "Sign in failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Step 1 Subscreen: Payment & Plan Selection (Two Plans: Pro & Agency)

    private var planSelectionView: some View {
        VStack(spacing: 16) {
            HStack {
                Button {
                    currentStep = .loginOrSignup
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back to Sign In")
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)

                Spacer()
            }

            VStack(spacing: 6) {
                Image(systemName: "externaldrive.fill.badge.icloud")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)

                Text("Choose Your ZeroDrive Plan")
                    .font(.title2.bold())

                Text("Segregated, client-ready cloud storage in Finder, terminal, and AI agents.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 14) {
                OnboardingPlanCard(
                    title: "Pro",
                    price: "$29/mo",
                    originalPrice: "$49/mo",
                    subprice: "Founders Rate (Reg. $49/mo) • or $197/yr",
                    badge: "FOUNDERS ($29 NOW)",
                    isFeatured: true,
                    features: [
                        "1 TB DFY Cloud Storage (Zero config)",
                        "Free Drive Partitioning (Work, Clients, Personal)",
                        "Unlimited Computers (Mac, Windows, Cloud Servers)",
                        "24/7 Hosted Agent MCP + API Access",
                        "Zero-config setup (no R2 keys required)"
                    ],
                    onSelect: {
                        openStripeCheckout(tier: "pro", email: loginEmail)
                        currentStep = .licenseActivation
                    }
                )

                OnboardingPlanCard(
                    title: "Agency",
                    price: "$297/mo",
                    originalPrice: "$497/mo",
                    subprice: "Founding Agency (Reg. $497/mo) • or $2,970/yr",
                    badge: "FOUNDING ($297 NOW)",
                    isFeatured: false,
                    features: [
                        "10 TB DFY Cloud Storage (+$25/TB add-on)",
                        "Unlimited Segregated Client Vaults",
                        "White-Label Domains & Team MCP Portals",
                        "Unlimited Machine Slots & 5 Team Seats",
                        "Client License Key Issuance & Controls"
                    ],
                    onSelect: {
                        openStripeCheckout(tier: "agency", email: loginEmail)
                        currentStep = .licenseActivation
                    }
                )
            }

            Button("Already have a license key? Activate Key…") {
                currentStep = .licenseActivation
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            // Minimal muted Free subline — requires BYOK Cloudflare R2 API keys
            Button {
                currentStep = .freeTierSetup
            } label: {
                Text("Using your own Cloudflare R2 bucket? Set up Free BYOK with your R2 API keys →")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    // MARK: - Step 1 Subscreen: Free BYOK Cloudflare R2 Setup

    private var freeTierSetupView: some View {
        VStack(spacing: 14) {
            HStack {
                Button {
                    currentStep = .loginOrSignup
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back to Sign In")
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)

                Spacer()

                Button("Upgrade to Pro ($29/mo — Reg. $49/mo) instead →") {
                    currentStep = .planSelection
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 4) {
                Image(systemName: "key.icloud.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)

                Text("Free Tier — Bring Your Own Cloudflare R2")
                    .font(.title3.bold())

                Text("Free mode requires your own Cloudflare R2 API keys and bucket. For zero-config managed storage, switch to **Pro** or **Agency**.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Account Email")
                        .font(.caption.bold())
                    TextField("you@example.com", text: $cfEmail)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Cloudflare Account ID")
                        .font(.caption.bold())
                    TextField("e.g. e9319ad5ca87e4768e7a79f1339ec8c8", text: $cfAccountId)
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
                    TextField("my-zerodrive-vault", text: $cfBucketName)
                        .textFieldStyle(.roundedBorder)
                }

                Button {
                    Task { await connectFreeCloudflare() }
                } label: {
                    HStack(spacing: 8) {
                        if isWorking {
                            ProgressView().controlSize(.small)
                            Text("Connecting Your Cloudflare R2…")
                        } else {
                            Image(systemName: "link.circle.fill")
                            Text("Connect Cloudflare R2 & Continue →")
                        }
                    }
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    isWorking ||
                    cfEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    cfAccountId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    cfAccessKeyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    cfSecretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .frame(maxWidth: 440)

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
    }

    // MARK: - Step 1 Subscreen: Paid License Key Activation

    private var licenseActivationView: some View {
        VStack(spacing: 16) {
            HStack {
                Button {
                    currentStep = .loginOrSignup
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back to Sign In")
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
                    .frame(maxWidth: 420)
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Account Email")
                        .font(.caption.bold())
                    TextField("you@example.com", text: $paidEmail)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("License Key")
                        .font(.caption.bold())
                    TextField("ZD-PRO-XXXX-XXXX-XXXXXXXX or zd_live_...", text: $paidLicenseKey)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .frame(maxWidth: 400)

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            HStack {
                Button("Back") {
                    currentStep = .planSelection
                }

                Spacer()

                Button {
                    Task { await activatePaidVault() }
                } label: {
                    Text(isWorking ? "Verifying & Provisioning…" : "Activate License & Continue →")
                        .bold()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || paidEmail.isEmpty || paidLicenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(maxWidth: 400)
        }
    }

    // MARK: - Step 2: Proper Install & macOS Permissions

    private var installAndPermissionsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Install & Grant Mac Permissions")
                    .font(.title3.bold())
                Text("ZeroDrive checks each system component live so Finder integration, quick actions, and storage scanning work reliably.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                // Card 1: ZeroDrive App & Finder Drive
                setupChecklistCard(
                    icon: "externaldrive.badge.icloud",
                    iconColor: Color.accentColor,
                    title: "ZeroDrive App & Finder Drive (My Drive)",
                    subtitle: appsAndFinderSubtitle,
                    badge: appsAndFinderBadge
                ) {
                    if setup.isRunningFromExternalOrBuild {
                        Button("Copy to /Applications") {
                            Task { await setup.installToApplications() }
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(setup.isWorking)
                    } else if !setup.isFinderSidebarPinned || !setup.isQuickActionsInstalled {
                        Button("Install Now") {
                            Task { await setup.runRecommendedInstall() }
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(setup.isWorking)
                    }
                }

                // Card 2: Mac Folders Permission (Desktop / Documents / Downloads)
                setupChecklistCard(
                    icon: "folder.badge.questionmark",
                    iconColor: .blue,
                    title: "Mac Folders Access (Desktop, Documents, Downloads)",
                    subtitle: "Allows ZeroDrive to scan for heavy videos, installers, and cold folders taking up space on your Mac SSD.",
                    badge: setup.hasUserFoldersAccess
                        ? ("Granted ✓", .green)
                        : ("Action Needed", .blue)
                ) {
                    if !setup.hasUserFoldersAccess {
                        Button("Grant Access…") {
                            setup.requestUserFoldersAccess()
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }
                }

                // Card 3: Optional Full Disk Access & Finder Sync Badges
                setupChecklistCard(
                    icon: "checkmark.shield.fill",
                    iconColor: .purple,
                    title: "Full Disk Access & Finder Badges",
                    subtitle: "Optional: enables deep iCloud cache inspection and Finder sync status badges on folders.",
                    badge: (setup.hasFullDiskAccess && setup.isFinderSyncEnabled)
                        ? ("Enabled ✓", .green)
                        : ("Optional", .secondary)
                ) {
                    HStack(spacing: 6) {
                        Button(setup.hasFullDiskAccess ? "Disk Access ✓" : "Privacy Settings…") {
                            setup.openFullDiskAccessSettings()
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)

                        Button(setup.isFinderSyncEnabled ? "Finder Badges ✓" : "Enable Badges…") {
                            setup.enableFinderExtensionOrOpenSettings()
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }

                // Card 4: Startup & Developer / Agent Tools
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $setup.launchAtLoginEnabled) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Open ZeroDrive automatically when I log in")
                                .font(.subheadline.weight(.medium))
                            Text("Keeps My Drive mounted in Finder and syncing in the background after restarts.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: setup.launchAtLoginEnabled) { newVal in
                        setup.setLaunchAtLogin(newVal)
                    }

                    Divider()

                    HStack {
                        Toggle(isOn: $setup.installCLIToolsEnabled) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Install Terminal CLI (`zd`) & AI Agent Skills (Claude, Cursor, Codex)")
                                    .font(.subheadline.weight(.medium))
                                Text("Adds `~/.local/bin/zd` + `zerodrive-mcp` and links the cloud-organizer skill.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if setup.isCLIAgentToolsInstalled {
                            statusBadge("Installed ✓", color: .green)
                        }
                    }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if !setup.statusMessage.isEmpty {
                Text(setup.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("← Back") {
                    currentStep = .loginOrSignup
                }
                .controlSize(.regular)

                Spacer()

                Button("Skip Setup & Open Finder") {
                    finishOnboardingAndOpenFinder()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)

                Button {
                    Task {
                        await setup.runRecommendedInstall()
                        currentStep = .cloudDiscovery
                    }
                } label: {
                    HStack(spacing: 6) {
                        if setup.isWorking {
                            ProgressView()
                                .controlSize(.small)
                            Text("Installing…")
                        } else {
                            Text("Install & Continue →")
                        }
                    }
                    .bold()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(setup.isWorking)
            }
            .padding(.top, 4)
        }
    }

    private var appsAndFinderSubtitle: String {
        var parts: [String] = []
        parts.append(setup.isInstalledInApplications ? "/Applications ✓" : "Copy to /Applications recommended")
        parts.append(setup.isEngineReady ? "Engine ✓" : "Engine will install")
        parts.append(setup.isFinderSidebarPinned ? "Sidebar My Drive ✓" : "Pin My Drive")
        parts.append(setup.isQuickActionsInstalled ? "Quick Actions ✓" : "Quick Actions")
        return parts.joined(separator: " • ")
    }

    private var appsAndFinderBadge: (String, Color) {
        if setup.isRunningFromExternalOrBuild {
            return ("Action Needed", .blue)
        }
        if setup.isInstalledInApplications && setup.isEngineReady && setup.isFinderSidebarPinned && setup.isQuickActionsInstalled {
            return ("Verified ✓", .green)
        }
        if supervisor.isBusy {
            return ("Mounting…", .orange)
        }
        return ("Action Needed", .blue)
    }

    @ViewBuilder
    private func setupChecklistCard<Accessory: View>(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        badge: (String, Color),
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline.bold())
                    statusBadge(badge.0, color: badge.1)
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            accessory()
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func statusBadge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    // MARK: - Step 3: Connect or Search Your Clouds

    private var cloudDiscoveryView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect or Search Your Clouds")
                    .font(.title3.bold())
                Text("ZeroDrive auto-discovers cloud folders already synced on this Mac so you can index and move files without downloading them to SSD.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Card 1: Cloud Folders Found on This Mac
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Cloud Folders Found on This Mac (Zero-Download Search)", systemImage: "magnifyingglass.circle.fill")
                        .font(.subheadline.bold())
                    Spacer()
                    Button("Rescan") {
                        setup.refreshChecks()
                    }
                    .controlSize(.small)
                }

                if setup.detectedMacClouds.isEmpty {
                    Text("No local iCloud Drive or ~/Library/CloudStorage folders detected yet. You can still connect any cloud account directly below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(setup.detectedMacClouds) { cloud in
                                HStack(spacing: 10) {
                                    Image(systemName: cloud.icon)
                                        .font(.body)
                                        .foregroundStyle(cloud.isResponsive ? Color.accentColor : Color.orange)
                                        .frame(width: 22)

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(cloud.name)
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(1)
                                        Text(cloud.isResponsive
                                             ? "Ready on Mac • 0 KB SSD downloaded"
                                             : "Disconnected in Finder (needs sign-in in provider app)")
                                            .font(.caption2)
                                            .foregroundStyle(cloud.isResponsive ? Color.secondary : Color.orange)
                                    }

                                    Spacer()

                                    Toggle("Searchable", isOn: Binding(
                                        get: { cloud.isIncludedInSearch },
                                        set: { _ in
                                            setup.toggleMacCloud(id: cloud.id)
                                            cloudSelectionDirty = true
                                        }
                                    ))
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .labelsHidden()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.primary.opacity(0.035))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .frame(maxHeight: 175)
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Card 2: Direct Cloud-to-Cloud OAuth Accounts
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Direct Cloud-to-Cloud Accounts (Optional)")
                        .font(.subheadline.bold())
                    Text("Connect accounts directly via OAuth to stream or search cloud files even when they are not synced to Finder.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                let connectedSet = MultiCloudCombineBuilder.shared.connectedExternalClouds()
                HStack(spacing: 10) {
                    ForEach(ExternalCloudProvider.allCases) { provider in
                        let isConnected = connectedSet.contains(provider)
                        let isConnectingThis = advisor.isConnectingProvider == provider.rawValue

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: provider.systemIcon)
                                    .foregroundStyle(isConnected ? .green : Color.accentColor)
                                Text(provider.displayName)
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                            }

                            if isConnected {
                                statusBadge("Connected ✓", color: .green)
                            } else {
                                Button {
                                    Task {
                                        await advisor.connectExternalCloud(provider)
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        if isConnectingThis {
                                            ProgressView()
                                                .controlSize(.mini)
                                            Text("Connecting…")
                                        } else {
                                            Text("Connect…")
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                                .disabled(advisor.isConnectingProvider != nil)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.035))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack {
                Button("← Back") {
                    currentStep = .installAndPermissions
                }
                .controlSize(.regular)

                Spacer()

                Button("Skip Clouds") {
                    if advisor.items.isEmpty && !advisor.isScanning {
                        advisor.startScan()
                    }
                    currentStep = .scanAndReady
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)

                Button {
                    if cloudSelectionDirty || (advisor.cloudItems.isEmpty && !advisor.isCloudScanning) {
                        cloudSelectionDirty = false
                        advisor.startCloudScan()
                    }
                    if advisor.items.isEmpty && !advisor.isScanning {
                        advisor.startScan()
                    }
                    currentStep = .scanAndReady
                } label: {
                    Text("View Initial Scan Results →")
                        .bold()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Step 4: Initial Scan Results & Where Everything Lives

    private var scanAndReadyView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Initial Scan Complete — You're Ready")
                    .font(.title3.bold())
                Text("Here is what ZeroDrive found on your Mac and connected clouds, plus where to open and control your drive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Section 1: Live Initial Scan Summary
            VStack(alignment: .leading, spacing: 10) {
                if advisor.isScanning || advisor.isCloudScanning {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Scanning Mac SSD & cloud stubs (0 bytes downloaded)…")
                                .font(.caption.bold())
                                .foregroundStyle(Color.accentColor)
                            Spacer()
                            Text(advisor.isScanning ? advisor.statusMessage : advisor.cloudStatusMessage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        ProgressView(value: advisor.isScanning ? max(0.15, advisor.scanProgress) : 0.75)
                            .progressViewStyle(.linear)
                    }
                }

                HStack(spacing: 10) {
                    // Tile 1: Reclaimable on Mac SSD
                    VStack(alignment: .leading, spacing: 4) {
                        Text("RECLAIMABLE ON MAC SSD")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text(advisor.totalReclaimableBytes > 0 ? formattedReclaimable : (advisor.isScanning ? "Scanning…" : "0 B"))
                            .font(.title3.bold().monospacedDigit())
                            .foregroundStyle(advisor.totalReclaimableBytes > 0 ? Color.accentColor : Color.primary)
                        Text("\(advisor.items.count) large/cold files")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if advisor.diskBreakdown.cloudGhostCount > 0 {
                            Text("Excluded \(advisor.diskBreakdown.cloudGhostCount) 0-byte cloud ghosts")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    // Tile 2: Searchable Cloud Files
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SEARCHABLE CLOUD FILES")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text("\(advisor.cloudItems.count) files")
                            .font(.title3.bold().monospacedDigit())
                            .foregroundStyle(.blue)
                        Text("Across \(advisor.cloudProviders.count) cloud source(s)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(formattedCloudTotal) • 0 KB on SSD")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    // Tile 3: My Drive Vault Status
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MY DRIVE VAULT STATUS")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text(supervisor.isMounted ? "Mounted & Ready" : "Connecting…")
                            .font(.title3.bold())
                            .foregroundStyle(supervisor.isMounted ? .green : .orange)
                        Text(licensing.license.tier)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("~/ZeroDrive/My Drive")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if !advisor.folderSummaries.isEmpty {
                    HStack(spacing: 6) {
                        Text("Top folders:")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        ForEach(advisor.folderSummaries.prefix(3)) { summary in
                            Text("\(summary.folderName) • \(summary.formattedSize)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.12))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                        Spacer()
                    }
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Section 2: Where to Find & Use ZeroDrive (3 Visual Guide Tiles)
            VStack(alignment: .leading, spacing: 8) {
                Text("WHERE EVERYTHING LIVES")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("1. Finder Sidebar (My Drive)", systemImage: "sidebar.left")
                            .font(.caption.bold())
                            .foregroundStyle(Color.accentColor)
                        Text("Under **Favorites → My Drive** in Finder (and `~/ZeroDrive` in Terminal). Open & save files directly in the cloud.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 2)
                        Button("Reveal in Finder") {
                            supervisor.pinToFinderSidebarIfNeeded()
                            supervisor.openInFinder(supervisor.mountPoint.appendingPathComponent("My Drive"))
                        }
                        .controlSize(.mini)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(Color.secondary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 5) {
                        Label("2. Right-Click Quick Actions", systemImage: "cursorarrow.click.2")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                        Text("Right-click any Mac folder → **Quick Actions → Move to ZeroDrive & Free Mac Space** (optional local shortcut).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(Color.secondary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 5) {
                        Label("3. Menu Bar & Account Bar", systemImage: "menubar.rectangle")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                        Text("Use the top-right drive icon for live speeds, or **Log Out / Switch Account** at the top of Dashboard.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(Color.secondary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            // Footer: First-Value Launch Actions
            HStack(spacing: 8) {
                Button("← Back") {
                    currentStep = .cloudDiscovery
                }
                .controlSize(.regular)

                Spacer()

                if advisor.totalReclaimableBytes > 0 {
                    Button("Free Up \(formattedReclaimable) Now →") {
                        markOnboardingCompleted()
                        lifecycleController.showOnboardingSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            NotificationCenter.default.post(name: NSNotification.Name("OpenStorageAdvisorTab"), object: nil)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }

                Button("Move a Folder…") {
                    markOnboardingCompleted()
                    lifecycleController.showOnboardingSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        NotificationCenter.default.post(name: NSNotification.Name("OpenDashboardMoveFolderPicker"), object: nil)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button("Open Dashboard") {
                    markOnboardingCompleted()
                    lifecycleController.showOnboardingSheet = false
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button("Finish & Open My Drive in Finder ✓") {
                    finishOnboardingAndOpenFinder()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.top, 4)
        }
    }

    private func markOnboardingCompleted() {
        supervisor.pinToFinderSidebarIfNeeded()
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboardingV3")
    }

    private func finishOnboardingAndOpenFinder() {
        markOnboardingCompleted()
        Task {
            await ManageFileProvider.shared.registerDomainIfNeeded()
        }
        lifecycleController.showOnboardingSheet = false
        supervisor.openInFinder(supervisor.mountPoint.appendingPathComponent("My Drive"))
    }

    // MARK: - Actions

    private func activateFreeVault() async {
        let cleanEmail = cfEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleanEmail.contains("@") && cleanEmail.contains(".") else {
            errorMessage = "Please enter a valid email address."
            return
        }

        isWorking = true
        errorMessage = ""

        do {
            let freeKey = "zd_free_\(UUID().uuidString.prefix(8).lowercased())"
            let result = try await DFYProvisioningClient.shared.provisionVault(
                email: cleanEmail,
                licenseKey: freeKey,
                isFreeTier: true
            )

            try MultiCloudCombineBuilder.shared.configureDFYPrimaryVault(
                result: result,
                spoolCapGB: 10
            )

            var meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
            meta.displayLabel = "ZeroDrive (10 GB Free)"
            MultiCloudCombineBuilder.shared.saveVaultMetadata(meta)

            let record = LicenseRecord(
                email: cleanEmail,
                licenseKey: freeKey,
                tier: "Free Starter",
                quotaTB: 0.01,
                status: "Active (Free Tier)",
                hardwareUUID: ManageLicensing.getHardwareUUID(),
                machineName: Host.current().localizedName ?? "Mac",
                activatedAt: Date(),
                isProvisioned: true
            )
            ManageLicensing.shared.applyProvisionedRecord(record)

            Task { @MainActor in
                await supervisor.forceCleanAndRemount()
                supervisor.pinToFinderSidebarIfNeeded()
                await ManageFileProvider.shared.registerDomainIfNeeded()
            }
            beginPostAuthOnboarding()
        } catch {
            isWorking = false
            errorMessage = "Provisioning failed: \(error.localizedDescription)"
        }
    }

    private func connectFreeCloudflare() async {
        let cleanEmail = cfEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let accountId = cfAccountId.trimmingCharacters(in: .whitespacesAndNewlines)
        let accessKey = cfAccessKeyId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretKey = cfSecretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanEmail.contains("@") && cleanEmail.contains(".") else {
            errorMessage = "Please enter a valid email address."
            return
        }
        guard !accountId.isEmpty && !accessKey.isEmpty && !secretKey.isEmpty else {
            errorMessage = "Cloudflare Account ID, R2 Access Key ID, and R2 Secret Access Key are required for Free BYOK."
            return
        }

        isWorking = true
        errorMessage = ""

        let endpoint = "https://\(accountId).r2.cloudflarestorage.com"
        let bucket = cfBucketName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "zerodrive-vault-free"
            : cfBucketName.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try MultiCloudCombineBuilder.shared.configureBYOKPrimaryVault(
                preset: .cloudflareR2,
                bucket: bucket,
                accessKey: accessKey,
                secretKey: secretKey,
                endpoint: endpoint,
                region: "auto",
                spoolCapGB: 10
            )

            let record = LicenseRecord(
                email: cleanEmail,
                licenseKey: "zd_byok_free_\(UUID().uuidString.prefix(8).lowercased())",
                tier: "Free (BYOK)",
                quotaTB: 0.01,
                status: "Active (BYOK Cloudflare R2)",
                hardwareUUID: ManageLicensing.getHardwareUUID(),
                machineName: Host.current().localizedName ?? "Mac",
                activatedAt: Date(),
                isProvisioned: true
            )
            ManageLicensing.shared.applyProvisionedRecord(record)

            Task { @MainActor in
                await supervisor.forceCleanAndRemount()
                supervisor.pinToFinderSidebarIfNeeded()
                await ManageFileProvider.shared.registerDomainIfNeeded()
            }
            beginPostAuthOnboarding()
        } catch {
            isWorking = false
            errorMessage = "Failed to connect Cloudflare R2: \(error.localizedDescription)"
        }
    }

    private func activatePaidVault() async {
        let cleanEmail = paidEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanKey = paidLicenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanEmail.contains("@") && cleanEmail.contains(".") else {
            errorMessage = "Please enter a valid email address."
            return
        }
        guard !cleanKey.isEmpty else {
            errorMessage = "Please enter your ZeroDrive license key."
            return
        }

        isWorking = true
        errorMessage = ""

        do {
            try await ManageLicensing.shared.activateLicenseKey(cleanKey, email: cleanEmail)
            beginPostAuthOnboarding()
        } catch {
            isWorking = false
            errorMessage = "License activation failed: \(error.localizedDescription)"
        }
    }

    private func openStripeCheckout(tier: String, email: String = "") {
        var urlStr = "https://api.zerodrive.dev/v1/billing/checkout?tier=\(tier)"
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanEmail.isEmpty,
           let encoded = cleanEmail.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            urlStr += "&email=\(encoded)"
        }
        if let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
        }
    }
}

public struct OnboardingPlanCard: View {
    public let title: String
    public let price: String
    public var originalPrice: String? = nil
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
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let originalPrice, !originalPrice.isEmpty {
                    Text(originalPrice)
                        .font(.subheadline.weight(.semibold))
                        .strikethrough(true, color: .secondary)
                        .foregroundStyle(.secondary)
                }
                Text(price).font(.title2.bold())
            }
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
