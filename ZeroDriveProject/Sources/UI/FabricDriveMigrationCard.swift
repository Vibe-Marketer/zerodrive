import SwiftUI
import UniformTypeIdentifiers

public struct FabricSpaceItem: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let url: URL
    public var fileCount: Int
    public var sizeBytes: Int64

    public var formattedSize: String {
        if sizeBytes == 0 {
            return fileCount == 0 ? "Empty" : "Zero KB"
        }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

public struct FabricDriveMigrationCard: View {
    @EnvironmentObject var supervisor: RcloneDaemonSupervisor
    @ObservedObject private var turbo = TurboMigrationManager.shared

    @State private var detectedSpaces: [FabricSpaceItem] = []
    
    // Unified Selected Source
    @State private var selectedItemURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/CloudStorage/FabricDrive/Andrew Naegeles Workspace/Spaces/_SKILLS")
    @State private var sourceItemCount: Int = 0
    @State private var sourceSizeBytes: Int64 = 0
    @State private var isLocationADropTargeted: Bool = false

    public init() {}

    private var isSourceFromFabric: Bool {
        selectedItemURL.path.contains("FabricDrive")
    }

    private var selectedItemName: String {
        selectedItemURL.lastPathComponent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            
            // MARK: - 1. Visual Left-to-Right Transfer Pipeline Card
            VStack(alignment: .leading, spacing: 12) {
                // Header Row
                HStack(alignment: .center) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(turbo.telemetry.isRunning ? Color.green : (turbo.telemetry.isComplete ? Color.blue : Color.secondary))
                            .frame(width: 9, height: 9)
                        Text(turbo.telemetry.isRunning ? "Direct Pipeline Move Active" : "ZeroDrive Direct Migration Pipeline")
                            .font(.headline)
                    }

                    Spacer()

                    if turbo.telemetry.isRunning {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("32 Parallel Streams • Auto De-dupe")
                                .font(.caption.bold())
                                .foregroundStyle(Color.accentColor)
                        }
                    } else if turbo.telemetry.isComplete {
                        Text("Ready for Next Move")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                                .font(.caption2)
                            Text("Auto De-duplication Active")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 3-Column Pipeline: [Location A (Source)] ──► [Pipeline Speed & Progress] ──► [ZeroDrive (Destination)]
                HStack(alignment: .center, spacing: 12) {
                    // LEFT BOX: Location A (Source) - Click to Open Finder / Multi-select or Drop Files
                    Button {
                        if !turbo.telemetry.isRunning {
                            openFinderFilePicker()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 5) {
                                Image(systemName: isSourceFromFabric ? "cloud.fill" : "laptopcomputer")
                                    .foregroundStyle(.blue)
                                Text("LOCATION A (SOURCE)")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if !turbo.telemetry.isRunning {
                                    Text("Browse (Cmd+A)…")
                                        .font(.caption2.bold())
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            
                            if turbo.telemetry.isRunning {
                                Text(turbo.telemetry.sourceLocation.isEmpty ? turbo.telemetry.spaceName : turbo.telemetry.sourceLocation)
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text("Drain: \(ByteCountFormatter.string(fromByteCount: turbo.telemetry.remainingBytes, countStyle: .file)) left")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text("\(max(0, turbo.telemetry.totalFiles - turbo.telemetry.movedFiles)) items remaining")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if !turbo.queuedSpaces.isEmpty {
                                HStack(spacing: 5) {
                                    Image(systemName: "square.stack.3d.up.fill")
                                        .font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                    Text("\(turbo.queuedSpaces.count) Items Staged in Queue")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                                Text("Drain: \(totalQueuedSizeFormatted)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text("Click to browse or drop more items")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary.opacity(0.8))
                            } else {
                                HStack(spacing: 5) {
                                    Image(systemName: "folder.fill")
                                        .font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                    Text(selectedItemName)
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }

                                Text("Drain: \(ByteCountFormatter.string(fromByteCount: sourceSizeBytes, countStyle: .file)) (\(sourceItemCount) items)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text("Click to search Finder or drop files here")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary.opacity(0.8))
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isLocationADropTargeted ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isLocationADropTargeted ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: 1.2)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(turbo.telemetry.isRunning)
                    .onDrop(of: [.fileURL], isTargeted: $isLocationADropTargeted) { providers in
                        handleDropOnLocationA(providers)
                        return true
                    }

                    // MIDDLE CONNECTOR: Transfer Speed, Direction Arrow & ETA
                    VStack(spacing: 5) {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill")
                                .foregroundStyle(turbo.telemetry.isRunning ? Color.orange : Color.secondary)
                                .font(.caption)
                            Text(turbo.telemetry.isRunning ? String(format: "%.1f MB/s", turbo.telemetry.speedMBps) : "0.0 MB/s")
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(turbo.telemetry.isRunning ? Color.primary : Color.secondary)
                        }

                        // Animated / Directional Flow Arrow
                        HStack(spacing: 2) {
                            Rectangle()
                                .fill(turbo.telemetry.isRunning ? Color.accentColor : Color.secondary.opacity(0.3))
                                .frame(height: 2)
                            Image(systemName: "chevron.right")
                                .font(.caption.bold())
                                .foregroundStyle(turbo.telemetry.isRunning ? Color.accentColor : Color.secondary.opacity(0.3))
                        }

                        Text(turbo.telemetry.isRunning ? formatETA(turbo.telemetry.etaSeconds) : "Idle")
                            .font(.caption2.bold().monospacedDigit())
                            .foregroundStyle(turbo.telemetry.isRunning ? Color.accentColor : Color.secondary)
                    }
                    .frame(width: 140)

                    // RIGHT BOX: ZeroDrive Vault (Destination)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            Image(systemName: "icloud.fill")
                                .foregroundStyle(.green)
                            Text("ZERODRIVE (DEST)")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                        }
                        
                        // Destination Path Bar
                        HStack(spacing: 4) {
                            Image(systemName: "externaldrive.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                            Text("ZeroDrive")
                                .font(.caption.bold())
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.tertiary)
                            Text(turbo.telemetry.isRunning ? (turbo.telemetry.destLocation.isEmpty ? "My Drive/\(turbo.telemetry.spaceName)" : turbo.telemetry.destLocation) : "My Drive/\(selectedItemName)")
                                .font(.subheadline.bold())
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        
                        if turbo.telemetry.isRunning {
                            Text("Landed: \(ByteCountFormatter.string(fromByteCount: turbo.telemetry.movedBytes, countStyle: .file))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.green)
                            Text("\(turbo.telemetry.movedFiles)/\(turbo.telemetry.totalFiles) items landed")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("ZeroDrive Vault")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Available via ~/ZeroDrive")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // High-visibility Progress Bar
                ProgressView(value: turbo.telemetry.isRunning ? (turbo.telemetry.percent / 100.0) : (turbo.telemetry.isComplete ? 1.0 : 0.0))
                    .progressViewStyle(.linear)

                // Sub-Bar: "In Progress" & "Up Next in Queue"
                VStack(alignment: .leading, spacing: 4) {
                    if turbo.telemetry.isRunning && !turbo.telemetry.currentFile.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text.fill")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                            Text("In Progress:")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Text(turbo.telemetry.currentFile)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    if !turbo.queuedSpaces.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.right.to.line.compact")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Text("Up Next in Queue:")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Text(turbo.queuedSpaces.joined(separator: " ➔ "))
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }

                Divider()
                    .padding(.vertical, 2)

                // Bottom Metrics & "All Said and Done" Projections
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("🎯 ALL SAID & DONE PROJECTION")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Text("• Vault Target: ~82.4 GB in ZeroDrive")
                                .font(.caption)
                            Text("• Target Mac SSD: ~48 GB Free Headroom")
                                .font(.caption)
                        }
                        if let ledger = turbo.ledger, ledger.totalFreedOnMacBytes > 0 {
                            Text("• Space Recovered: +\(ByteCountFormatter.string(fromByteCount: ledger.totalFreedOnMacBytes, countStyle: .file)) SSD space permanently freed on Mac")
                                .font(.caption.bold())
                                .foregroundStyle(.green)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        Text("Mac SSD Free:")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: turbo.telemetry.freeDiskBytes > 0 ? turbo.telemetry.freeDiskBytes : Int64(shutilCurrentFree()), countStyle: .file))
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(Color.green)
                        if turbo.telemetry.isRunning {
                            Button("Stop Transfer") {
                                turbo.cancel()
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(14)
            .background(turbo.telemetry.isRunning ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(turbo.telemetry.isRunning ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.12), lineWidth: 1)
            )

            // MARK: - 2. Action Controls & Finder Multi-Select Button
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Button {
                        openFinderFilePicker()
                    } label: {
                        Label("Choose in Finder (Multi-Select / Cmd+A)…", systemImage: "folder.badge.gearshape")
                    }
                    .controlSize(.regular)

                    Button {
                        turbo.stageSpace(selectedItemName)
                    } label: {
                        Label("Stage Item", systemImage: "plus.circle")
                    }
                    .controlSize(.regular)
                    .disabled(turbo.queuedSpaces.contains(selectedItemName))

                    Spacer()

                    if !turbo.queuedSpaces.isEmpty && !turbo.telemetry.isRunning {
                        Button {
                            turbo.runQueuedMoves()
                        } label: {
                            Text("Start All (\(turbo.queuedSpaces.count) Queued Moves)")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    } else {
                        Button {
                            startDirectMoveCurrentSource()
                        } label: {
                            Text(turbo.telemetry.isRunning ? "Add to Queue" : "Turbo Move to ZeroDrive")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                }

                // Fabric Quick Stage All option
                if !detectedSpaces.isEmpty {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)
                        Text("Fabric Drive: \(detectedSpaces.count) spaces available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Stage All Fabric Spaces (\(detectedSpaces.count))") {
                            turbo.stageAllSpaces(detectedSpaces.map { $0.name })
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                    }
                }

                // Staged Queue Area
                if !turbo.queuedSpaces.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Staged Moves (\(turbo.queuedSpaces.count) queued • \(totalQueuedSizeFormatted)):")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Clear Queue") {
                                turbo.clearQueue()
                            }
                            .controlSize(.small)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)

                            if !turbo.telemetry.isRunning {
                                Button("Go Ahead (Start Staged Moves)") {
                                    turbo.runQueuedMoves()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }

                        ForEach(turbo.queuedSpaces, id: \.self) { space in
                            HStack {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(Color.accentColor)
                                Text(space)
                                    .font(.subheadline.weight(.medium))
                                if let found = detectedSpaces.first(where: { $0.name == space }) {
                                    Text("(\(found.formattedSize))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    turbo.unstageSpace(space)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(Color.secondary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .onAppear {
            scanFabricSpaces()
            updateSourceStats(selectedItemURL)
        }
    }

    // MARK: - Native Finder Search & Multi-Select File Picker

    private func openFinderFilePicker() {
        let panel = NSOpenPanel()
        panel.title = "Select Files or Folders to Move to ZeroDrive"
        panel.prompt = "Select for Move"
        panel.message = "Choose any folder(s) or file(s). Use Cmd+A or Shift-click to select everything at once."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true // <--- ENABLED: Multi-select & Cmd+A
        panel.directoryURL = selectedItemURL.deletingLastPathComponent()

        if panel.runModal() == .OK {
            let urls = panel.urls
            guard !urls.isEmpty else { return }

            if urls.count == 1 {
                selectedItemURL = urls[0]
                updateSourceStats(urls[0])
            } else {
                // Multi-select: Stage all selected items into the queue!
                turbo.stageURLs(urls)
                selectedItemURL = urls[0]
                updateSourceStats(urls[0])
            }
        }
    }

    private func handleDropOnLocationA(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var targetURL: URL? = nil
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    targetURL = url
                } else if let url = item as? URL {
                    targetURL = url
                }
                if let url = targetURL {
                    DispatchQueue.main.async {
                        if providers.count == 1 {
                            self.selectedItemURL = url
                            self.updateSourceStats(url)
                        } else {
                            self.turbo.stageURLs([url])
                            self.selectedItemURL = url
                            self.updateSourceStats(url)
                        }
                    }
                }
            }
        }
    }

    private func startDirectMoveCurrentSource() {
        if isSourceFromFabric {
            if turbo.telemetry.isRunning {
                turbo.stageSpace(selectedItemName)
            } else {
                turbo.startMove(spaceName: selectedItemName)
            }
        } else {
            turbo.startDirectMove(urls: [selectedItemURL])
        }
    }

    private func updateSourceStats(_ url: URL) {
        if let found = detectedSpaces.first(where: { $0.url.path == url.path }) {
            self.sourceItemCount = found.fileCount
            self.sourceSizeBytes = found.sizeBytes
            return
        }

        DispatchQueue.global(qos: .utility).async {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }

            if !isDir.boolValue {
                let sz = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                DispatchQueue.main.async {
                    self.sourceItemCount = 1
                    self.sourceSizeBytes = sz
                }
                return
            }

            var count = 0
            var size: Int64 = 0
            if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                for case let fileURL as URL in enumerator {
                    if let res = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                       res.isRegularFile == true {
                        count += 1
                        size += Int64(res.fileSize ?? 0)
                        if count > 5000 { break }
                    }
                }
            }

            DispatchQueue.main.async {
                self.sourceItemCount = count
                self.sourceSizeBytes = size
            }
        }
    }

    private var totalQueuedSizeFormatted: String {
        let total = turbo.queuedSpaces.reduce(Int64(0)) { acc, name in
            acc + (detectedSpaces.first(where: { $0.name == name })?.sizeBytes ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func formatETA(_ seconds: Int) -> String {
        if seconds <= 0 { return "Calculating..." }
        let mins = seconds / 60
        let secs = seconds % 60
        return mins > 0 ? "ETA: \(mins)m \(secs)s" : "ETA: \(secs)s"
    }

    private func shutilCurrentFree() -> UInt64 {
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? NSNumber {
            return free.uint64Value
        }
        return 41 * 1024 * 1024 * 1024
    }

    private func scanFabricSpaces() {
        DispatchQueue.global(qos: .utility).async {
            let base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/CloudStorage/FabricDrive/Andrew Naegeles Workspace/Spaces")
            guard let items = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else {
                return
            }

            var scanned: [FabricSpaceItem] = []
            for item in items {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                let name = item.lastPathComponent
                if name.hasPrefix(".") { continue }

                var count = 0
                var size: Int64 = 0
                if let enumerator = FileManager.default.enumerator(at: item, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                    for case let fileURL as URL in enumerator {
                        if let res = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                           res.isRegularFile == true {
                            count += 1
                            size += Int64(res.fileSize ?? 0)
                        }
                    }
                }

                scanned.append(FabricSpaceItem(
                    id: name,
                    name: name,
                    url: item,
                    fileCount: count,
                    sizeBytes: size
                ))
            }

            let sorted = scanned.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                self.detectedSpaces = sorted
                if let first = sorted.first(where: { $0.name == "_SKILLS" }) ?? sorted.first {
                    if self.selectedItemURL.path.contains("FabricDrive") {
                        self.selectedItemURL = first.url
                        self.sourceItemCount = first.fileCount
                        self.sourceSizeBytes = first.sizeBytes
                    }
                }
            }
        }
    }
}
