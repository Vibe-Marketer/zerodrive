import SwiftUI
import Charts
import AppKit

public struct AutostartAndWorkflowsView: View {
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor
    @EnvironmentObject var spoolManager: SpoolAndGuardManager

    @State private var autoStartEnabled: Bool = false
    @State private var streamGuardEnabled: Bool = false
    @State private var statusBanner: String = ""

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings, Speed & Finder Shortcuts").font(.title2).bold()

                // 60s Rolling Bandwidth Chart
                GroupBox("Live Upload Speed (MB/s)") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(String(format: "Current Upload Speed: %.2f MB/s", spoolManager.telemetry.uploadSpeedMBps))
                                .font(.headline)
                                .monospacedDigit()
                            Spacer()
                            Text("\(spoolManager.telemetry.activeUploads) uploading • \(spoolManager.telemetry.activeQueued) waiting")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Chart(spoolManager.bandwidthHistory) { sample in
                            AreaMark(
                                x: .value("Time", sample.timestamp),
                                y: .value("MB/s", sample.speedMBps)
                            )
                            .foregroundStyle(.blue.opacity(0.2))

                            LineMark(
                                x: .value("Time", sample.timestamp),
                                y: .value("MB/s", sample.speedMBps)
                            )
                            .foregroundStyle(.blue)
                        }
                        .chartXAxis(.hidden)
                        .frame(height: 100)
                    }
                    .padding(8)
                }

                // Everyday Preferences
                GroupBox("Performance & Login Preferences") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Video Call / Zoom Protection (Cap Uploads at 3 MB/s)").bold()
                                Text("Keeps background cloud uploads from slowing down your Zoom calls or live streams.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $streamGuardEnabled)
                                .onChange(of: streamGuardEnabled) { active in
                                    spoolManager.telemetry.streamGuardActive = active
                                    Task {
                                        _ = await RcloneRCClient.shared.setBandwidthCap(rate: active ? "3M:off" : "off")
                                    }
                                }
                        }

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Smooth 4K / 8K Video Playback Mode").bold()
                                Text("Pre-loads larger video chunks in RAM so scrubbing heavy timeline files in Finder never stutters.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $supervisor.boostVideoBufferEnabled)
                                .onChange(of: supervisor.boostVideoBufferEnabled) { _ in
                                    if supervisor.isMounted {
                                        Task { await supervisor.forceCleanAndRemount() }
                                    }
                                }
                        }

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Start ZeroDrive Automatically When I Log In").bold()
                                Text("Mounts ~/ZeroDrive in the background every time you turn on your Mac.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $autoStartEnabled)
                                .onChange(of: autoStartEnabled) { enabled in
                                    configureLaunchAgent(enabled: enabled)
                                }
                        }
                    }
                    .padding(10)
                }

                // Finder Quick Actions & Repair
                GroupBox("Finder Sidebar Shortcut & Right-Click Menu Integration") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Finder Extension & Right-Click Quick Actions").bold()
                            Text("Pins ZeroDrive next to Home in the Finder Sidebar and adds 'Move to Cloud & Free Space' and 'Copy to 5 TB Cloud Vault' when you right-click any file or folder in Finder.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Re-Sync Finder Menu & Sidebar") {
                            supervisor.pinToFinderSidebarIfNeeded()
                            supervisor.installFinderWorkflowsAndEnableExtension()
                            statusBanner = "Synced Finder Sidebar shortcut, right-click Quick Actions, and FinderSync Extension!"
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Repair Drive Mount") {
                            Task { await supervisor.forceCleanAndRemount() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(10)
                }

                if !statusBanner.isEmpty {
                    Text(statusBanner)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .onAppear {
            let plistURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents/com.zerodrive.desktop.plist")
            autoStartEnabled = FileManager.default.fileExists(atPath: plistURL.path)
        }
    }

    private func configureLaunchAgent(enabled: Bool) {
        let agentsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        let plistURL = agentsDir.appendingPathComponent("com.zerodrive.desktop.plist")
        let mountPath = supervisor.mountPoint.path
        let cachePath = supervisor.cacheDir.path

        if enabled {
            try? FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
            let content = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.zerodrive.desktop</string>
                <key>ProgramArguments</key>
                <array>
                    <string>/Applications/ZeroDrive.app/Contents/Resources/rclone</string>
                    <string>nfsmount</string>
                    <string>ZeroDriveUnified:</string>
                    <string>\(mountPath)</string>
                    <string>--volname=ZeroDrive</string>
                    <string>--vfs-cache-mode=writes</string>
                    <string>--cache-dir=\(cachePath)</string>
                    <string>--vfs-cache-max-size=250G</string>
                    <string>--vfs-write-back=15s</string>
                    <string>--vfs-cache-max-age=1m</string>
                    <string>--vfs-read-chunk-size=8M</string>
                    <string>--vfs-read-chunk-size-limit=128M</string>
                    <string>--buffer-size=32M</string>
                    <string>--vfs-read-ahead=64M</string>
                    <string>--dir-cache-time=9999h</string>
                    <string>--attr-timeout=24h</string>
                    <string>--allow-non-empty</string>
                    <string>--noappledouble=true</string>
                    <string>--noapplexattr=true</string>
                    <string>--rc</string>
                    <string>--rc-addr=127.0.0.1:55729</string>
                    <string>--rc-no-auth</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <dict>
                    <key>SuccessfulExit</key>
                    <false/>
                </dict>
            </dict>
            </plist>
            """
            try? content.write(to: plistURL, atomically: true, encoding: .utf8)
            statusBanner = "Enabled automatic login startup!"
        } else {
            try? FileManager.default.removeItem(at: plistURL)
            statusBanner = "Disabled automatic login startup."
        }
    }

    private func installFinderQuickActions() {
        let servicesDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services")
        try? FileManager.default.createDirectory(at: servicesDir, withIntermediateDirectories: true)
        let mountPath = supervisor.mountPoint.path

        let scripts: [(String, String)] = [
            (
                "ZeroDrive - Move to _Retakes.sh",
                """
                #!/usr/bin/env bash
                mkdir -p "\(mountPath)/_Retakes"
                for f in "$@"; do
                  mv "$f" "\(mountPath)/_Retakes/"
                done
                """
            ),
            (
                "ZeroDrive - Evict Local Spool Copy.sh",
                """
                #!/usr/bin/env bash
                for f in "$@"; do
                  rel="${f#\(mountPath)/}"
                  curl -s -X POST http://127.0.0.1:55729/vfs/forget -H "Content-Type: application/json" -d "{\\"file\\": \\"$rel\\"}"
                done
                """
            ),
            (
                "ZeroDrive - Refresh Cloud Folder.sh",
                """
                #!/usr/bin/env bash
                curl -s -X POST http://127.0.0.1:55729/vfs/refresh -H "Content-Type: application/json" -d '{"recursive":"true","_async":"true"}'
                """
            )
        ]

        for (name, body) in scripts {
            let fileURL = servicesDir.appendingPathComponent(name)
            try? body.write(to: fileURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
        }
        statusBanner = "Installed 3 Finder right-click shortcuts!"
    }
}
