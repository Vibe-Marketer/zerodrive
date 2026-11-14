import SwiftUI
import AppKit

public struct UpdateAvailableSheet: View {
    @ObservedObject private var updater = ManageAppUpdates.shared
    @Environment(\.dismiss) private var dismiss

    public init() {}

    private var targetVersion: String {
        updater.latestRelease?.version ?? "New Version"
    }

    private var activeTransfersWarning: String? {
        let dirty = SpoolAndGuardManager.shared.dirtyFileCount
        if TurboMigrationManager.shared.isLocalTransferRunning {
            return "A file transfer is currently running. Installing will finish flushing transfers before restarting."
        }
        if dirty > 0 {
            return "\(dirty) file(s) are still syncing and will finish saving before ZeroDrive restarts."
        }
        return nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.app.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text("ZeroDrive Update Available")
                        .font(.title2.bold())
                    Text("Version \(targetVersion) is ready to install (you're on v\(updater.currentVersion)).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            // Trust & Verification Badges
            HStack(spacing: 10) {
                Label("Verified Developer ID", systemImage: "checkmark.seal.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.12))
                    .clipShape(Capsule())

                Label("ECDSA + SHA-256 Checked", systemImage: "lock.shield.fill")
                    .font(.caption.bold())
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Capsule())

                if let artifact = updater.platformArtifact, artifact.size > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: artifact.size, countStyle: .file))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            // Release Notes (includes any skipped versions)
            VStack(alignment: .leading, spacing: 6) {
                Text(updater.missedReleases.count > 1
                     ? "What's New Across \(updater.missedReleases.count) Releases"
                     : "What's New in v\(targetVersion)")
                    .font(.headline)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        let entries = updater.missedReleases.isEmpty
                            ? (updater.latestRelease.map { [$0] } ?? [])
                            : updater.missedReleases
                        ForEach(entries) { rel in
                            ReleaseNotesSectionCard(release: rel, isCurrentVersion: false)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 160, maxHeight: 240)
                .padding(10)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if let transferWarning = activeTransfersWarning {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.orange)
                    Text(transferWarning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Download / Install Progress
            if updater.isDownloading || updater.isInstalling {
                VStack(alignment: .leading, spacing: 6) {
                    if updater.isInstalling {
                        ProgressView()
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView(value: updater.downloadProgress)
                            .progressViewStyle(.linear)
                    }

                    HStack {
                        Text(updater.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if updater.isDownloading && updater.totalBytes > 0 {
                            Text("\(ByteCountFormatter.string(fromByteCount: updater.downloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: updater.totalBytes, countStyle: .file))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if !updater.errorMessage.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(updater.errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Actions
            HStack {
                if updater.isDownloading {
                    Button("Pause Download") {
                        updater.cancelDownload()
                    }
                    .controlSize(.regular)
                } else {
                    Button("Remind Me Later") {
                        updater.deferCurrentUpdate()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(updater.isInstalling)
                }

                Spacer()

                Button {
                    updater.startDownloadAndInstall()
                } label: {
                    if updater.isInstalling {
                        Text("Installing & Restarting…")
                    } else if updater.isDownloading {
                        Text("Downloading… \(Int(updater.downloadProgress * 100))%")
                    } else if !updater.errorMessage.isEmpty {
                        Label("Retry Download & Install", systemImage: "arrow.clockwise")
                    } else {
                        Label("Download & Install Now", systemImage: "arrow.down.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(updater.isDownloading || updater.isInstalling)
            }
        }
        .padding(22)
        .frame(width: 540)
    }
}

public struct WhatsNewChangelogSheet: View {
    @ObservedObject private var updater = ManageAppUpdates.shared
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: updater.justUpdatedFromVersion != nil ? "sparkles.rectangle.stack.fill" : "doc.text.magnifyingglass")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    if let prev = updater.justUpdatedFromVersion {
                        Text("Updated to ZeroDrive v\(updater.currentVersion)!")
                            .font(.title2.bold())
                        Text("Upgraded cleanly from v\(prev). Here's everything new:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("What's New in ZeroDrive")
                            .font(.title2.bold())
                        Text("Current version: v\(updater.currentVersion) (Build \(updater.currentBuild))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if updater.updateAvailable, let latest = updater.latestRelease {
                    Button("Install v\(latest.version)") {
                        dismiss()
                        updater.showUpdatePromptSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if updater.justUpdatedFromVersion != nil && !updater.missedReleases.isEmpty {
                        Text("INCLUDED IN THIS UPDATE")
                            .font(.caption.bold())
                            .foregroundStyle(Color.accentColor)

                        ForEach(updater.missedReleases) { rel in
                            ReleaseNotesSectionCard(release: rel, isCurrentVersion: rel.version == updater.currentVersion)
                        }

                        let otherReleases = updater.allReleases.filter { rel in
                            !updater.missedReleases.contains(where: { $0.version == rel.version })
                        }
                        if !otherReleases.isEmpty {
                            Divider()
                                .padding(.vertical, 4)
                            Text("EARLIER RELEASES")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            ForEach(otherReleases) { rel in
                                ReleaseNotesSectionCard(release: rel, isCurrentVersion: false)
                            }
                        }
                    } else {
                        ForEach(updater.allReleases) { rel in
                            ReleaseNotesSectionCard(release: rel, isCurrentVersion: rel.version == updater.currentVersion)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 240, maxHeight: 380)

            HStack {
                Button("Check for Updates") {
                    Task {
                        await updater.checkForUpdates(trigger: .manual)
                    }
                }
                .disabled(updater.isChecking)

                if !updater.statusMessage.isEmpty {
                    Text(updater.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}

private struct ReleaseNotesSectionCard: View {
    let release: ReleaseEntry
    let isCurrentVersion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("v\(release.version)")
                    .font(.headline.bold().monospacedDigit())

                if isCurrentVersion {
                    Text("CURRENT")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.16))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                }

                Text(release.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Text(release.date)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(release.highlights, id: \.self) { bullet in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                            .padding(.top, 2)
                        Text(bullet)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isCurrentVersion ? Color.green.opacity(0.35) : Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }
}

public struct UpdateBannerCard: View {
    @ObservedObject private var updater = ManageAppUpdates.shared

    public init() {}

    public var body: some View {
        if updater.updateAvailable, let latest = updater.latestRelease {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("ZeroDrive v\(latest.version) is Available")
                        .font(.subheadline.bold())
                    Text(latest.summary ?? latest.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button("What's New") {
                    updater.openChangelog()
                }
                .controlSize(.small)

                Button("Download & Install") {
                    updater.showUpdatePromptSheet = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
            )
        } else if let prev = updater.justUpdatedFromVersion {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Updated to ZeroDrive v\(updater.currentVersion)")
                        .font(.subheadline.bold())
                    Text("Upgraded from v\(prev). Click to view what changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("See What's New") {
                    updater.openChangelog()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
            .background(Color.green.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.green.opacity(0.25), lineWidth: 1)
            )
        }
    }
}
