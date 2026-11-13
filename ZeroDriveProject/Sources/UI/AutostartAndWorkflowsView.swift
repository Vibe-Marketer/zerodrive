import SwiftUI
import AppKit

public struct AutostartAndWorkflowsView: View {
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor
    @EnvironmentObject var spoolManager: SpoolAndGuardManager
    @ObservedObject private var onboardingSetup = ManageOnboardingSetup.shared

    @State private var autoStartEnabled: Bool = false
    @State private var streamGuardEnabled: Bool = false
    @AppStorage("zerodrive_bandwidth_limit") private var bandwidthLimit: String = "off"
    @State private var statusFeedback: String = ""

    public init() {}

    public var body: some View {
        Form {
            Section("Setup, Permissions & CLI Tools") {
                LabeledContent("Onboarding & Permissions Wizard") {
                    Button("Open Setup Guide…") {
                        AppLifecycleController.shared.openOnboarding(atStep: 1)
                    }
                    .controlSize(.small)
                }

                LabeledContent("Terminal CLI (`zd`) & Agent Skills") {
                    HStack(spacing: 8) {
                        Text(onboardingSetup.isCLIAgentToolsInstalled ? "Installed in ~/.local/bin" : "Not Installed")
                            .font(.caption)
                            .foregroundStyle(onboardingSetup.isCLIAgentToolsInstalled ? .green : .secondary)
                        Button("Install / Repair CLI & Skills") {
                            Task {
                                await onboardingSetup.installCLIAgentTools()
                                showFeedback("Installed CLI tools (`zd`, `zerodrive-mcp`) and AI agent skills.")
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("General") {
                Toggle("Open ZeroDrive automatically when you log in", isOn: $autoStartEnabled)
                    .onChange(of: autoStartEnabled) { enabled in
                        setAutoStart(enabled)
                    }

                Toggle("Smooth video playback (faster pre-buffering)", isOn: $supervisor.boostVideoBufferEnabled)
                    .onChange(of: supervisor.boostVideoBufferEnabled) { _ in
                        if supervisor.isMounted {
                            Task { await supervisor.forceCleanAndRemount() }
                        }
                    }

                Toggle("Pause heavy uploads during Zoom or video calls", isOn: $streamGuardEnabled)
                    .onChange(of: streamGuardEnabled) { active in
                        spoolManager.telemetry.streamGuardActive = active
                        Task {
                            _ = await RcloneRCClient.shared.setBandwidthCap(rate: active ? "3M:off" : bandwidthLimit)
                        }
                    }

                Picker("Network Bandwidth Limit", selection: $bandwidthLimit) {
                    Text("Unlimited (Full Line Speed)").tag("off")
                    Text("50 MB/s (High Speed)").tag("50M")
                    Text("15 MB/s (Balanced)").tag("15M")
                    Text("3 MB/s (Hotspot / Mobile Data)").tag("3M")
                }
                .onChange(of: bandwidthLimit) { newLimit in
                    Task {
                        _ = await RcloneRCClient.shared.setBandwidthCap(rate: newLimit)
                    }
                }
            }

            Section("Finder Integration") {
                LabeledContent("Finder Favorites Sidebar") {
                    Button("Pin My Drive to Sidebar") {
                        supervisor.pinToFinderSidebarIfNeeded()
                        showFeedback("Pinned My Drive to Finder sidebar.")
                    }
                    .controlSize(.small)
                }

                LabeledContent("Finder Right-Click Menu") {
                    Button("Refresh Quick Actions") {
                        supervisor.installFinderWorkflowsAndEnableExtension()
                        showFeedback("Updated Finder right-click menu.")
                    }
                    .controlSize(.small)
                }
            }

            Section("Mac Disk Protection") {
                LabeledContent("Temporary cache used on this Mac") {
                    HStack(spacing: 8) {
                        Text(ByteCountFormatter.string(fromByteCount: spoolManager.telemetry.spoolUsedBytes, countStyle: .file))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button("Empty Temporary Cache") {
                            clearLocalCache()
                        }
                        .controlSize(.small)
                    }
                }

                Picker("Max temporary cache size", selection: Binding(
                    get: { MultiCloudCombineBuilder.shared.loadVaultMetadata().spoolCapGB },
                    set: { newVal in
                        var m = MultiCloudCombineBuilder.shared.loadVaultMetadata()
                        m.spoolCapGB = newVal
                        MultiCloudCombineBuilder.shared.saveVaultMetadata(m)
                    }
                )) {
                    Text("25 GB").tag(25)
                    Text("50 GB (Recommended)").tag(50)
                    Text("100 GB").tag(100)
                    Text("200 GB").tag(200)
                }

                Picker("Always keep at least this much Mac space free", selection: Binding(
                    get: { MultiCloudCombineBuilder.shared.loadVaultMetadata().minFreeSpaceGB },
                    set: { newVal in
                        var m = MultiCloudCombineBuilder.shared.loadVaultMetadata()
                        m.minFreeSpaceGB = newVal
                        MultiCloudCombineBuilder.shared.saveVaultMetadata(m)
                    }
                )) {
                    Text("10 GB").tag(10)
                    Text("15 GB (Recommended)").tag(15)
                    Text("25 GB").tag(25)
                    Text("40 GB").tag(40)
                }
            }

            Section("Hidden & Developer Files") {
                Toggle("Include Notes & Editor Folders (.obsidian, .vscode, .cursor)", isOn: Binding(
                    get: { MultiCloudCombineBuilder.shared.loadVaultMetadata().uploadAppWorkspaces },
                    set: { newVal in
                        var m = MultiCloudCombineBuilder.shared.loadVaultMetadata()
                        m.uploadAppWorkspaces = newVal
                        MultiCloudCombineBuilder.shared.saveVaultMetadata(m)
                    }
                ))

                Toggle("Include Git & Agent Folders (.git, .github, .claude)", isOn: Binding(
                    get: { MultiCloudCombineBuilder.shared.loadVaultMetadata().uploadDevConfigs },
                    set: { newVal in
                        var m = MultiCloudCombineBuilder.shared.loadVaultMetadata()
                        m.uploadDevConfigs = newVal
                        MultiCloudCombineBuilder.shared.saveVaultMetadata(m)
                    }
                ))

                Toggle("Include Secret Key Files (.env, .pem, .key)", isOn: Binding(
                    get: { MultiCloudCombineBuilder.shared.loadVaultMetadata().uploadSecretEnvFiles },
                    set: { newVal in
                        var m = MultiCloudCombineBuilder.shared.loadVaultMetadata()
                        m.uploadSecretEnvFiles = newVal
                        MultiCloudCombineBuilder.shared.saveVaultMetadata(m)
                    }
                ))

                Text("By default, .env and key files are skipped so your API keys never leave your Mac.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !statusFeedback.isEmpty {
                Section {
                    Text(statusFeedback)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear {
            checkAutoStartStatus()
            streamGuardEnabled = spoolManager.telemetry.streamGuardActive
        }
    }

    private func showFeedback(_ text: String) {
        statusFeedback = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if statusFeedback == text {
                statusFeedback = ""
            }
        }
    }

    private func checkAutoStartStatus() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plistURL = home.appendingPathComponent("Library/LaunchAgents/co.aisimple.zerodrive.plist")
        self.autoStartEnabled = FileManager.default.fileExists(atPath: plistURL.path)
    }

    private func setAutoStart(_ enabled: Bool) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let launchAgentsDir = home.appendingPathComponent("Library/LaunchAgents")
        let plistURL = launchAgentsDir.appendingPathComponent("co.aisimple.zerodrive.plist")

        if enabled {
            try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>co.aisimple.zerodrive</string>
                <key>ProgramArguments</key>
                <array>
                    <string>/usr/bin/open</string>
                    <string>-a</string>
                    <string>/Applications/ZeroDrive.app</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>ProcessType</key>
                <string>Interactive</string>
            </dict>
            </plist>
            """
            try? plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }

    private func clearLocalCache() {
        Task {
            _ = await RcloneRCClient.shared.forgetAll()
            let cacheDir = supervisor.cacheDir.appendingPathComponent("vfs")
            if FileManager.default.fileExists(atPath: cacheDir.path) {
                if let enumerator = FileManager.default.enumerator(at: cacheDir, includingPropertiesForKeys: [.isRegularFileKey]) {
                    for case let fileURL as URL in enumerator {
                        if fileURL.pathExtension == "bin" {
                            try? FileManager.default.removeItem(at: fileURL)
                        }
                    }
                }
            }
            await MainActor.run {
                showFeedback("Safely cleared temporary read cache on this Mac.")
            }
        }
    }
}
