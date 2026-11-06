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

            Section("Storage") {
                LabeledContent("Space used on this Mac") {
                    HStack(spacing: 8) {
                        Text(ByteCountFormatter.string(fromByteCount: spoolManager.telemetry.spoolUsedBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button("Clear") {
                            clearLocalCache()
                        }
                        .controlSize(.small)
                    }
                }
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
        let cacheDir = supervisor.cacheDir
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        showFeedback("Cleared space on this Mac.")
    }
}
