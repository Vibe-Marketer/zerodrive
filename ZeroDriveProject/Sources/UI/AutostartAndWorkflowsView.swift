import SwiftUI
import AppKit

public struct AutostartAndWorkflowsView: View {
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor
    @EnvironmentObject var spoolManager: SpoolAndGuardManager

    @State private var autoStartEnabled: Bool = false
    @State private var streamGuardEnabled: Bool = false
    @State private var statusFeedback: String = ""

    public init() {}

    public var body: some View {
        Form {
            Section("General") {
                Toggle("Open at Login", isOn: $autoStartEnabled)
                    .onChange(of: autoStartEnabled) { enabled in
                        setAutoStart(enabled)
                    }

                Toggle("Smooth video playback", isOn: $supervisor.boostVideoBufferEnabled)
                    .onChange(of: supervisor.boostVideoBufferEnabled) { _ in
                        if supervisor.isMounted {
                            Task { await supervisor.forceCleanAndRemount() }
                        }
                    }

                Toggle("Slow uploads during calls", isOn: $streamGuardEnabled)
                    .onChange(of: streamGuardEnabled) { active in
                        spoolManager.telemetry.streamGuardActive = active
                        Task {
                            _ = await RcloneRCClient.shared.setBandwidthCap(rate: active ? "3M:off" : "off")
                        }
                    }
            }

            Section("Finder") {
                LabeledContent("Finder sidebar") {
                    Button("Add to Sidebar") {
                        supervisor.pinToFinderSidebarIfNeeded()
                        showFeedback("Added to Finder sidebar.")
                    }
                    .controlSize(.small)
                }

                LabeledContent("Right-click menu") {
                    Button("Update") {
                        supervisor.installFinderWorkflowsAndEnableExtension()
                        showFeedback("Updated right-click menu.")
                    }
                    .controlSize(.small)
                }
            }

            Section("Storage & SSD Breathing Room") {
                LabeledContent("Space used on this Mac") {
                    HStack(spacing: 8) {
                        Text(ByteCountFormatter.string(fromByteCount: spoolManager.telemetry.spoolUsedBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button("Clear Cache Safely") {
                            clearLocalCache()
                        }
                        .controlSize(.small)
                    }
                }
                
                Picker("Cache Size Target", selection: Binding(
                    get: { MultiCloudCombineBuilder.shared.loadVaultMetadata().spoolCapGB },
                    set: { newVal in
                        var m = MultiCloudCombineBuilder.shared.loadVaultMetadata()
                        m.spoolCapGB = newVal
                        MultiCloudCombineBuilder.shared.saveVaultMetadata(m)
                    }
                )) {
                    Text("25 GB").tag(25)
                    Text("50 GB (Default)").tag(50)
                    Text("100 GB").tag(100)
                    Text("200 GB").tag(200)
                }

                Picker("Guaranteed Minimum Free Mac SSD Space", selection: Binding(
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

            Section("Dot-Files & Privacy Controls") {
                Toggle("Include Notes & Workspaces (.obsidian, .vscode, .cursor)", isOn: Binding(
                    get: { MultiCloudCombineBuilder.shared.loadVaultMetadata().uploadAppWorkspaces },
                    set: { newVal in
                        var m = MultiCloudCombineBuilder.shared.loadVaultMetadata()
                        m.uploadAppWorkspaces = newVal
                        MultiCloudCombineBuilder.shared.saveVaultMetadata(m)
                    }
                ))

                Toggle("Include Developer Version Control (.git, .github, .claude)", isOn: Binding(
                    get: { MultiCloudCombineBuilder.shared.loadVaultMetadata().uploadDevConfigs },
                    set: { newVal in
                        var m = MultiCloudCombineBuilder.shared.loadVaultMetadata()
                        m.uploadDevConfigs = newVal
                        MultiCloudCombineBuilder.shared.saveVaultMetadata(m)
                    }
                ))

                Toggle("Include Secret & Environment Files (.env, keys, credentials)", isOn: Binding(
                    get: { MultiCloudCombineBuilder.shared.loadVaultMetadata().uploadSecretEnvFiles },
                    set: { newVal in
                        var m = MultiCloudCombineBuilder.shared.loadVaultMetadata()
                        m.uploadSecretEnvFiles = newVal
                        MultiCloudCombineBuilder.shared.saveVaultMetadata(m)
                    }
                ))
                
                Text("Default excludes .env files so API keys and secrets stay strictly on your local machine.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !statusFeedback.isEmpty {
                Section {
                    Text(statusFeedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            // Safe eviction: tell rclone VFS to drop all cached clean read chunks without deleting uncommitted writes
            _ = await RcloneRCClient.shared.forgetAll()
            
            // On-disk prune: only remove .bin chunk files inside vfs cache subdirectories, NEVER touching dirty write queues
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
                showFeedback("Safely cleared read cache on this Mac.")
            }
        }
    }
}
