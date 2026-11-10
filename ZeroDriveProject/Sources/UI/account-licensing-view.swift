import SwiftUI
import AppKit

public struct AccountLicensingView: View {
    @ObservedObject private var licensing = ManageLicensing.shared
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor
    @ObservedObject private var vaultStats = VaultStats.shared

    @State private var inputKey: String = ""
    @State private var inputEmail: String = ""
    @State private var isShowingKeyInput: Bool = false
    @State private var isShowingSwitchAccountSheet: Bool = false
    @State private var feedbackMessage: String = ""

    public init() {}

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
                                    .background(Color.accentColor.opacity(0.15))
                                    .foregroundStyle(Color.accentColor)
                                    .clipShape(Capsule())
                            }

                            Text("Status: \(licensing.license.status) • Machine Activated")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

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
                            value: String(format: "%.1f TB", licensing.license.quotaTB),
                            subtitle: "Unlimited throughput",
                            color: .primary
                        )

                        statPill(
                            title: "ACTIVATED MACHINES",
                            value: "1 of 4 Slots",
                            subtitle: licensing.license.machineName,
                            color: .green
                        )

                        statPill(
                            title: "PROVISIONING",
                            value: licensing.license.isProvisioned ? "Operational" : "Pending",
                            subtitle: "ZeroDrive Cloud Vault",
                            color: licensing.license.isProvisioned ? .green : .orange
                        )
                    }
                }
                .padding(.vertical, 4)
            }

            // MARK: - 2. Active Master License Key
            Section("Active Master License Key") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("License Key")
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

                        Button("Change Key…") {
                            isShowingKeyInput.toggle()
                        }
                        .controlSize(.small)
                    }

                    if isShowingKeyInput {
                        HStack {
                            TextField("Enter license key (zd_live_...)", text: $inputKey)
                                .textFieldStyle(.roundedBorder)

                            Button("Activate") {
                                Task {
                                    do {
                                        try await licensing.activateLicenseKey(inputKey)
                                        isShowingKeyInput = false
                                        inputKey = ""
                                        feedbackMessage = "License successfully activated!"
                                    } catch {
                                        feedbackMessage = error.localizedDescription
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(inputKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    if !feedbackMessage.isEmpty {
                        Text(feedbackMessage)
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.vertical, 2)
            }

            // MARK: - 3. Machine Hardware Binding
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

            // MARK: - 4. 1-Click Provisioning / Switch Account
            Section("Account Management") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Need to switch account or re-provision?")
                            .font(.body.weight(.medium))
                        Text("Log into a different ZeroDrive account or configure a new cloud vault.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Switch Account…") {
                        isShowingSwitchAccountSheet = true
                    }
                    .controlSize(.regular)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Account & Licensing")
        .sheet(isPresented: $isShowingSwitchAccountSheet) {
            switchAccountModal
        }
    }

    private var switchAccountModal: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.system(size: 32))
                .foregroundStyle(Color.accentColor)

            Text("Login & Provision ZeroDrive")
                .font(.title3.bold())

            Text("Enter your email address to log in and automatically provision your cloud vault.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            TextField("Email address", text: $inputEmail)
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
                .buttonStyle(.borderedProminent)
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
