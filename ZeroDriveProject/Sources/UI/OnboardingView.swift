import SwiftUI

public struct OnboardingView: View {
    @EnvironmentObject var lifecycleController: AppLifecycleController
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor

    @State private var email: String = ""
    @State private var licenseKey: String = ""
    @State private var spoolCapGB: Int = 50
    @State private var showCustomKeys: Bool = false

    @State private var preset: CloudPreset = .cloudflareR2
    @State private var bucketName: String = ""
    @State private var accessKey: String = ""
    @State private var secretKey: String = ""
    @State private var customEndpoint: String = ""
    @State private var region: String = "auto"

    @State private var isWorking: Bool = false
    @State private var errorMessage: String = ""

    public init() {}

    private var isValidEmail: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && trimmed.contains(".")
    }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.fill.badge.icloud")
                .font(.system(size: 40))
                .foregroundStyle(.blue)

            VStack(spacing: 4) {
                Text("Welcome to ZeroDrive")
                    .font(.title2.bold())
                Text("Your cloud folder in Finder.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !showCustomKeys {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Email address", text: $email)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        Task { await connectDFYVault() }
                    } label: {
                        Text(isWorking ? "Connecting…" : "Continue")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isWorking || !isValidEmail)
                }
                .frame(maxWidth: 340)
            }

            DisclosureGroup("Use your own storage keys", isExpanded: $showCustomKeys) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Provider", selection: $preset) {
                        ForEach(CloudPreset.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    TextField("Bucket name", text: $bucketName)
                        .textFieldStyle(.roundedBorder)
                    TextField(preset == .backblazeB2 ? "Application Key ID" : "Access Key ID", text: $accessKey)
                        .textFieldStyle(.roundedBorder)
                    SecureField(preset == .backblazeB2 ? "Application Key" : "Secret Access Key", text: $secretKey)
                        .textFieldStyle(.roundedBorder)

                    if preset != .backblazeB2 {
                        TextField("Endpoint URL", text: $customEndpoint)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        Task { await connectBYOKVault() }
                    } label: {
                        Text(isWorking ? "Connecting…" : "Connect Bucket")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(isWorking || bucketName.isEmpty || accessKey.isEmpty || secretKey.isEmpty)
                }
                .padding(.top, 8)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 340)

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    lifecycleController.showOnboardingSheet = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
            spoolCapGB = meta.spoolCapGB
        }
    }

    private func connectDFYVault() async {
        let targetEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetEmail.isEmpty else {
            errorMessage = "Please enter your email address."
            return
        }
        isWorking = true
        errorMessage = ""

        do {
            let result = try await DFYProvisioningClient.shared.provisionVault(
                email: targetEmail,
                licenseKey: licenseKey
            )
            try MultiCloudCombineBuilder.shared.configureDFYPrimaryVault(
                result: result,
                spoolCapGB: spoolCapGB
            )
            await supervisor.forceCleanAndRemount()
            isWorking = false
            lifecycleController.showOnboardingSheet = false
        } catch {
            isWorking = false
            errorMessage = "Setup failed: \(error.localizedDescription)"
        }
    }

    private func connectBYOKVault() async {
        isWorking = true
        errorMessage = ""

        do {
            try MultiCloudCombineBuilder.shared.configureBYOKPrimaryVault(
                preset: preset,
                bucket: bucketName,
                accessKey: accessKey,
                secretKey: secretKey,
                endpoint: customEndpoint,
                region: region,
                spoolCapGB: spoolCapGB
            )

            if let rcloneURL = await supervisor.resolveOrDownloadRcloneBinary() {
                let (valid, msg) = await MultiCloudCombineBuilder.shared.validatePrimaryVault(
                    rcloneURL: rcloneURL,
                    bucket: bucketName
                )
                if !valid {
                    errorMessage = "Credential warning: \(msg)"
                }
            }

            await supervisor.forceCleanAndRemount()
            isWorking = false
            lifecycleController.showOnboardingSheet = false
        } catch {
            isWorking = false
            errorMessage = "Failed to save config: \(error.localizedDescription)"
        }
    }
}
