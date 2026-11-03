import SwiftUI

public struct OnboardingView: View {
    @EnvironmentObject var lifecycleController: AppLifecycleController
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor

    @State private var mode: StorageMode = .dfyManaged
    @State private var email: String = ""
    @State private var licenseKey: String = ""
    @State private var spoolCapGB: Int = 250

    @State private var preset: CloudPreset = .cloudflareR2
    @State private var bucketName: String = ""
    @State private var accessKey: String = ""
    @State private var secretKey: String = ""
    @State private var customEndpoint: String = ""
    @State private var region: String = "auto"

    @State private var isWorking: Bool = false
    @State private var errorMessage: String = ""

    public init() {}

    public var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.fill.badge.icloud")
                .font(.system(size: 42))
                .foregroundStyle(.blue)

            Text("Cloud Storage Setup").font(.title2).bold()
            Text("Choose whether to use your included 5 TB ZeroDrive Cloud Vault or plug in your own S3 / R2 / Backblaze keys.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Picker("Storage Mode", selection: $mode) {
                Text("ZeroDrive 5 TB Cloud (1-Click)").tag(StorageMode.dfyManaged)
                Text("Use My Own Keys (BYOK)").tag(StorageMode.byokOpen)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 380)

            if mode == .dfyManaged {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your 5 TB ZeroDrive Cloud Vault mounts directly in Finder at ~/ZeroDrive/Vault.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Your Email Address (optional for instant setup)", text: $email)
                        .textFieldStyle(.roundedBorder)
                    SecureField("License Key (optional)", text: $licenseKey)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        Task { await connectDFYVault() }
                    } label: {
                        Text(isWorking ? "Activating & Mounting ~/ZeroDrive…" : "Save & Mount My 5 TB ZeroDrive")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isWorking)
                }
                .frame(maxWidth: 380)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Cloud Provider", selection: $preset) {
                        ForEach(CloudPreset.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    TextField("Bucket Name (e.g. my-media-vault)", text: $bucketName)
                        .textFieldStyle(.roundedBorder)
                    TextField(preset == .backblazeB2 ? "Application Key ID" : "Access Key ID", text: $accessKey)
                        .textFieldStyle(.roundedBorder)
                    SecureField(preset == .backblazeB2 ? "Application Key" : "Secret Access Key", text: $secretKey)
                        .textFieldStyle(.roundedBorder)

                    if preset != .backblazeB2 {
                        TextField("S3 Endpoint URL (e.g. https://<ACCOUNT_ID>.r2.cloudflarestorage.com)", text: $customEndpoint)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        Task { await connectBYOKVault() }
                    } label: {
                        Text(isWorking ? "Testing Connection & Mounting…" : "Save & Mount My Bucket")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isWorking || bucketName.isEmpty || accessKey.isEmpty || secretKey.isEmpty)
                }
                .frame(maxWidth: 380)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Picker("Max Temporary Upload Cache on Mac:", selection: $spoolCapGB) {
                    Text("25 GB Temp Cache").tag(25)
                    Text("50 GB Temp Cache").tag(50)
                    Text("100 GB Temp Cache").tag(100)
                    Text("250 GB Temp Cache").tag(250)
                }
                Text("Note: Your cloud drive holds 5 TB. This setting only limits how much temporary Mac space can be used while files are actively uploading (cleared automatically 60s after upload).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 380)

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            Button("Cancel / Close") {
                lifecycleController.showOnboardingSheet = false
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 460)
        .preferredColorScheme(.dark)
        .onAppear {
            let meta = MultiCloudCombineBuilder.shared.loadVaultMetadata()
            spoolCapGB = meta.spoolCapGB
        }
    }

    private func connectDFYVault() async {
        isWorking = true
        errorMessage = ""
        let targetEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "andrew@aisimple.co"
            : email

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
                    errorMessage = "Credential warning (\(msg)). Attempting mount…"
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
