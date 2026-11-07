import SwiftUI
import UniformTypeIdentifiers

public struct PendingTransferItem: Identifiable {
    public let id = UUID()
    public let urls: [URL]
    public var destinationFolder: String
    public var isCopy: Bool = false
    public var leaveSymlink: Bool = false

    public init(
        urls: [URL],
        destinationFolder: String = "",
        isCopy: Bool = false,
        leaveSymlink: Bool = false
    ) {
        self.urls = urls
        if !destinationFolder.isEmpty {
            self.destinationFolder = destinationFolder
        } else if let first = urls.first {
            self.destinationFolder = first.lastPathComponent
        } else {
            self.destinationFolder = ""
        }
        self.isCopy = isCopy
        self.leaveSymlink = leaveSymlink
    }
}

public struct TransferConfirmationSheet: View {
    let pendingItem: PendingTransferItem
    let onConfirm: (PendingTransferItem) -> Void
    let onCancel: () -> Void

    @State private var destinationFolder: String = ""
    @State private var isCopy: Bool = false
    @State private var leaveSymlink: Bool = false
    @State private var isCalculating: Bool = true
    @State private var totalSizeBytes: Int64 = 0
    @State private var totalItemCount: Int = 0

    public init(
        pendingItem: PendingTransferItem,
        onConfirm: @escaping (PendingTransferItem) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.pendingItem = pendingItem
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _destinationFolder = State(initialValue: pendingItem.destinationFolder)
        _isCopy = State(initialValue: pendingItem.isCopy)
        _leaveSymlink = State(initialValue: pendingItem.leaveSymlink)
    }

    private var primaryURL: URL? {
        pendingItem.urls.first
    }

    private var displayName: String {
        if pendingItem.urls.count > 1 {
            return "\(pendingItem.urls.count) Items Selected"
        }
        return primaryURL?.lastPathComponent ?? "Item"
    }

    private var isDirectory: Bool {
        if let url = primaryURL {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        return false
    }

    private var iconName: String {
        if pendingItem.urls.count > 1 {
            return "square.stack.3d.up.fill"
        }
        return isDirectory ? "folder.fill" : "doc.fill"
    }

    private var formattedSize: String {
        if isCalculating {
            return "Checking size…"
        }
        let sizeStr = ByteCountFormatter.string(fromByteCount: totalSizeBytes, countStyle: .file)
        if totalItemCount > 1 {
            return "\(sizeStr) • \(totalItemCount) files"
        }
        return sizeStr
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "icloud.and.arrow.up.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Move to ZeroDrive Cloud")
                        .font(.headline)
                    Text("Check what you're moving and where it will go in My Drive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {

                    // MARK: - 1. Source Card
                    VStack(alignment: .leading, spacing: 8) {
                        Text("FROM THIS MAC")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Image(systemName: iconName)
                                .font(.system(size: 28))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 36, height: 36)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(displayName)
                                    .font(.title3.weight(.semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                HStack(spacing: 6) {
                                    Text(formattedSize)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)

                                    if let url = primaryURL {
                                        Text("•")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                        Text(truncatedBreadcrumb(url.path))
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                            .help(url.path)
                                    }
                                }
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    // MARK: - 2. Destination Card
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TO MY DRIVE (CLOUD VAULT)")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "externaldrive.fill")
                                    .foregroundStyle(Color.accentColor)
                                Text("My Drive")
                                    .font(.subheadline.bold())
                                Image(systemName: "chevron.right")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.tertiary)

                                TextField("Folder name in My Drive", text: $destinationFolder)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.subheadline)
                            }

                            HStack(spacing: 8) {
                                Text("Quick pick:")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                Button(displayName) {
                                    destinationFolder = displayName
                                }
                                .buttonStyle(.borderless)
                                .font(.caption2)
                                .controlSize(.mini)
                                .foregroundStyle(destinationFolder == displayName ? Color.accentColor : Color.secondary)

                                Button("Top Level (My Drive)") {
                                    destinationFolder = ""
                                }
                                .buttonStyle(.borderless)
                                .font(.caption2)
                                .controlSize(.mini)
                                .foregroundStyle(destinationFolder.isEmpty ? Color.accentColor : Color.secondary)

                                Button("Archive / \(displayName)") {
                                    destinationFolder = "Archive/\(displayName)"
                                }
                                .buttonStyle(.borderless)
                                .font(.caption2)
                                .controlSize(.mini)
                                .foregroundStyle(destinationFolder.hasPrefix("Archive") ? Color.accentColor : Color.secondary)
                            }
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    // MARK: - 3. Action Mode (Move vs Copy) + Symlink Toggle
                    VStack(alignment: .leading, spacing: 10) {
                        Text("HOW TO TRANSFER")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)

                        Picker("Method", selection: $isCopy) {
                            Text("Move & Free Up Mac Space").tag(false)
                            Text("Copy Only (Keep on Mac)").tag(true)
                        }
                        .pickerStyle(.segmented)

                        if !isCopy && isDirectory && pendingItem.urls.count == 1 {
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle(isOn: $leaveSymlink) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "link")
                                            .foregroundStyle(Color.accentColor)
                                        Text("Leave a shortcut (symlink) in the old spot")
                                            .font(.subheadline.weight(.medium))
                                    }
                                }
                                Text("Leaves a 0 KB link behind so your apps, scripts, and automations still find this folder where it used to be.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 22)
                            }
                            .padding(10)
                            .background(Color.accentColor.opacity(0.07))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                            Text(isCopy
                                 ? "Copies files to your Cloud Vault and keeps the originals on this Mac."
                                 : "Every file is verified safe in your Cloud Vault before it is removed from your Mac.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer Actions
            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    var finalItem = pendingItem
                    finalItem.destinationFolder = destinationFolder.trimmingCharacters(in: .whitespacesAndNewlines)
                    finalItem.isCopy = isCopy
                    finalItem.leaveSymlink = (!isCopy && isDirectory) ? leaveSymlink : false
                    onConfirm(finalItem)
                } label: {
                    Text(isCopy ? "Copy to Cloud" : (leaveSymlink && isDirectory ? "Move & Leave Shortcut" : "Move & Free Space"))
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 510, height: isDirectory && !isCopy ? 485 : 420)
        .onAppear {
            calculateSourceStats()
        }
    }

    private func truncatedBreadcrumb(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var clean = path
        if clean.hasPrefix(home) {
            clean = "~" + clean.dropFirst(home.count)
        }
        let parts = clean.split(separator: "/")
        if parts.count > 3 {
            return parts.prefix(2).joined(separator: "/") + "/…/" + parts.last!
        }
        return clean
    }

    private func calculateSourceStats() {
        let urlsToScan = pendingItem.urls
        DispatchQueue.global(qos: .userInitiated).async {
            var bytes: Int64 = 0
            var files: Int = 0

            for url in urlsToScan {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                            while let fileURL = enumerator.nextObject() as? URL {
                                if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                                   values.isRegularFile == true {
                                    files += 1
                                    bytes += Int64(values.fileSize ?? 0)
                                }
                            }
                        }
                    } else {
                        files += 1
                        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                            bytes += (attrs[.size] as? Int64) ?? 0
                        }
                    }
                }
            }

            let finalBytes = bytes
            let finalFiles = files
            DispatchQueue.main.async {
                self.totalSizeBytes = finalBytes
                self.totalItemCount = finalFiles
                self.isCalculating = false
            }
        }
    }
}
