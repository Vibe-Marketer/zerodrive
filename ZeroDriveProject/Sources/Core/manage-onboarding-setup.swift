import Foundation
import AppKit
import Darwin

public struct DetectedMacCloud: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let icon: String
    public let path: String
    public let isResponsive: Bool
    public var isIncludedInSearch: Bool

    public init(
        id: String,
        name: String,
        icon: String,
        path: String,
        isResponsive: Bool,
        isIncludedInSearch: Bool
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.path = path
        self.isResponsive = isResponsive
        self.isIncludedInSearch = isIncludedInSearch
    }
}

private struct OnboardingChecksSnapshot: Sendable {
    let isInstalledInApplications: Bool
    let isRunningFromExternalOrBuild: Bool
    let isEngineReady: Bool
    let isFinderSidebarPinned: Bool
    let isQuickActionsInstalled: Bool
    let hasUserFoldersAccess: Bool
    let hasFullDiskAccess: Bool
    let isFinderSyncEnabled: Bool
    let launchAtLoginEnabled: Bool
    let isCLIAgentToolsInstalled: Bool
    let detectedMacClouds: [DetectedMacCloud]
}

@MainActor
public final class ManageOnboardingSetup: ObservableObject {
    public static let shared = ManageOnboardingSetup()

    nonisolated public static let excludedCloudsDefaultsKey = "zerodrive_excluded_mac_clouds"

    @Published public private(set) var isInstalledInApplications: Bool = false
    @Published public private(set) var isRunningFromExternalOrBuild: Bool = false
    @Published public private(set) var isEngineReady: Bool = false
    @Published public private(set) var isFinderSidebarPinned: Bool = false
    @Published public private(set) var isQuickActionsInstalled: Bool = false
    @Published public private(set) var hasUserFoldersAccess: Bool = false
    @Published public private(set) var hasFullDiskAccess: Bool = false
    @Published public private(set) var isFinderSyncEnabled: Bool = false
    @Published public var launchAtLoginEnabled: Bool = false
    @Published public var installCLIToolsEnabled: Bool = true
    @Published public private(set) var isCLIAgentToolsInstalled: Bool = false
    @Published public private(set) var detectedMacClouds: [DetectedMacCloud] = []
    @Published public private(set) var isWorking: Bool = false
    @Published public private(set) var statusMessage: String = ""

    private var activeObserver: NSObjectProtocol?

    private init() {
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshChecks()
            }
        }
        refreshChecks()
    }

    deinit {
        if let observer = activeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public func refreshChecks() {
        let bundlePath = Bundle.main.bundleURL.path
        let engineReady = RcloneDaemonSupervisor.shared.resolveRcloneBinary() != nil
        let excludedPaths = Set(UserDefaults.standard.stringArray(forKey: Self.excludedCloudsDefaultsKey) ?? [])

        Task.detached(priority: .userInitiated) {
            let snapshot = Self.collectChecksSnapshot(
                bundlePath: bundlePath,
                engineReady: engineReady,
                excludedCloudPaths: excludedPaths
            )
            await MainActor.run {
                self.isInstalledInApplications = snapshot.isInstalledInApplications
                self.isRunningFromExternalOrBuild = snapshot.isRunningFromExternalOrBuild
                self.isEngineReady = snapshot.isEngineReady
                self.isFinderSidebarPinned = snapshot.isFinderSidebarPinned
                self.isQuickActionsInstalled = snapshot.isQuickActionsInstalled
                self.hasUserFoldersAccess = snapshot.hasUserFoldersAccess
                self.hasFullDiskAccess = snapshot.hasFullDiskAccess
                self.isFinderSyncEnabled = snapshot.isFinderSyncEnabled
                self.launchAtLoginEnabled = snapshot.launchAtLoginEnabled
                self.isCLIAgentToolsInstalled = snapshot.isCLIAgentToolsInstalled
                self.detectedMacClouds = snapshot.detectedMacClouds
            }
        }
    }

    public func toggleMacCloud(id: String) {
        guard let idx = detectedMacClouds.firstIndex(where: { $0.id == id }) else { return }
        detectedMacClouds[idx].isIncludedInSearch.toggle()

        var excluded = Set(UserDefaults.standard.stringArray(forKey: Self.excludedCloudsDefaultsKey) ?? [])
        let path = detectedMacClouds[idx].path
        if detectedMacClouds[idx].isIncludedInSearch {
            excluded.remove(path)
        } else {
            excluded.insert(path)
        }
        UserDefaults.standard.set(Array(excluded), forKey: Self.excludedCloudsDefaultsKey)
    }

    @discardableResult
    public func installToApplications() async -> Bool {
        let sourcePath = Bundle.main.bundleURL.path
        let destPath = "/Applications/ZeroDrive.app"
        guard sourcePath.hasSuffix(".app"), sourcePath != destPath else {
            refreshChecks()
            return true
        }

        isWorking = true
        statusMessage = "Installing ZeroDrive to /Applications…"

        let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
            _ = Self.runSync("/usr/bin/ditto", [sourcePath, destPath])
            let clearOK = Self.runSync("/usr/bin/xattr", ["-cr", destPath])
            return clearOK && FileManager.default.fileExists(atPath: destPath)
        }.value

        isWorking = false
        statusMessage = ok ? "Installed in /Applications/ZeroDrive.app" : "Could not copy app automatically — drag ZeroDrive to Applications."
        refreshChecks()
        return ok
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
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

        launchAtLoginEnabled = FileManager.default.fileExists(atPath: plistURL.path)
    }

    public func installCLIAgentTools() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let localBin = home.appendingPathComponent(".local/bin")
        let resourceURL = Bundle.main.resourceURL

        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try? fm.createDirectory(at: localBin, withIntermediateDirectories: true)

            let cliCandidates = [
                resourceURL?.appendingPathComponent("zerodrive"),
                URL(fileURLWithPath: "/Users/Naegele/_LAB/zerodrive/bin/zerodrive")
            ].compactMap { $0 }

            if let srcCLI = cliCandidates.first(where: { fm.fileExists(atPath: $0.path) }) {
                let dstCLI = localBin.appendingPathComponent("zerodrive")
                if dstCLI.path != srcCLI.path {
                    try? fm.removeItem(at: dstCLI)
                    try? fm.copyItem(at: srcCLI, to: dstCLI)
                }
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dstCLI.path)

                let zdLink = localBin.appendingPathComponent("zd")
                try? fm.removeItem(at: zdLink)
                try? fm.createSymbolicLink(at: zdLink, withDestinationURL: dstCLI)
            }

            let mcpCandidates = [
                resourceURL?.appendingPathComponent("zerodrive-mcp"),
                URL(fileURLWithPath: "/Users/Naegele/_LAB/zerodrive/bin/zerodrive-mcp")
            ].compactMap { $0 }

            if let srcMCP = mcpCandidates.first(where: { fm.fileExists(atPath: $0.path) }) {
                let dstMCP = localBin.appendingPathComponent("zerodrive-mcp")
                if dstMCP.path != srcMCP.path {
                    try? fm.removeItem(at: dstMCP)
                    try? fm.copyItem(at: srcMCP, to: dstMCP)
                }
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dstMCP.path)
            }
        }.value

        _ = ManageStorageAdvisor.shared.installOrganizeSkillToAgents()
        refreshChecks()
    }

    public func runRecommendedInstall() async {
        isWorking = true
        statusMessage = "Installing Finder integration, engine & shortcuts…"

        _ = await RcloneDaemonSupervisor.shared.resolveOrDownloadRcloneBinary()
        RcloneDaemonSupervisor.shared.pinToFinderSidebarIfNeeded()
        RcloneDaemonSupervisor.shared.installFinderWorkflowsAndEnableExtension()
        await ManageFileProvider.shared.registerDomainIfNeeded()
        setLaunchAtLogin(launchAtLoginEnabled)

        if installCLIToolsEnabled {
            await installCLIAgentTools()
        }

        isWorking = false
        statusMessage = "System components installed"
        refreshChecks()
    }

    public func requestUserFoldersAccess() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default

        for folderName in ["Downloads", "Desktop", "Documents"] {
            let folderURL = home.appendingPathComponent(folderName)
            _ = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
        }

        let grantedNow = Self.checkUserFoldersAccess(home: home)
        if !grantedNow {
            let panel = NSOpenPanel()
            panel.title = "Grant Folder Access to ZeroDrive"
            panel.prompt = "Grant Folder Access"
            panel.message = "Select your Home, Downloads, or Desktop folder so ZeroDrive can scan for large movable files."
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = home
            _ = panel.runModal()

            if !Self.checkUserFoldersAccess(home: home),
               let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                NSWorkspace.shared.open(settingsURL)
            }
        }

        refreshChecks()
        if Self.checkUserFoldersAccess(home: home) {
            ManageStorageAdvisor.shared.startScan()
        }
    }

    public func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    public func enableFinderExtensionOrOpenSettings() {
        Task {
            let enabled = await Task.detached(priority: .userInitiated) { () -> Bool in
                _ = Self.runSync("/usr/bin/pluginkit", ["-e", "use", "-i", "co.aisimple.zerodrive.FinderSync"])
                return Self.checkFinderSyncEnabled()
            }.value

            self.refreshChecks()
            if !enabled {
                let primaryURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
                let fallbackURL = URL(string: "x-apple.systempreferences:com.apple.preference.extensions")
                if let url = primaryURL, NSWorkspace.shared.open(url) {
                    return
                }
                if let fb = fallbackURL {
                    NSWorkspace.shared.open(fb)
                }
            }
        }
    }

    // MARK: - Nonisolated Probes

    private nonisolated static func collectChecksSnapshot(
        bundlePath: String,
        engineReady: Bool,
        excludedCloudPaths: Set<String>
    ) -> OnboardingChecksSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default

        let appExists = (bundlePath == "/Applications/ZeroDrive.app")
            || fm.fileExists(atPath: "/Applications/ZeroDrive.app")
        let runningOutsideApps = !bundlePath.hasPrefix("/Applications/")

        let sidebarPinned = checkFinderSidebarPinned(home: home)
        let workflowPath = home.appendingPathComponent("Library/Services/ZeroDrive - Move to Cloud & Free Space.workflow").path
        let quickActionsReady = fm.fileExists(atPath: workflowPath)
        let foldersOK = checkUserFoldersAccess(home: home)
        let fdaOK = checkFullDiskAccess(home: home)
        let finderSyncOK = checkFinderSyncEnabled()
        let launchAgentExists = fm.fileExists(atPath: home.appendingPathComponent("Library/LaunchAgents/co.aisimple.zerodrive.plist").path)

        let zdPath = home.appendingPathComponent(".local/bin/zd").path
        let cliPath = home.appendingPathComponent(".local/bin/zerodrive").path
        let cliInstalled = fm.isExecutableFile(atPath: zdPath) && fm.isExecutableFile(atPath: cliPath)

        let clouds = discoverMacClouds(home: home, excludedPaths: excludedCloudPaths)

        return OnboardingChecksSnapshot(
            isInstalledInApplications: appExists,
            isRunningFromExternalOrBuild: runningOutsideApps,
            isEngineReady: engineReady,
            isFinderSidebarPinned: sidebarPinned,
            isQuickActionsInstalled: quickActionsReady,
            hasUserFoldersAccess: foldersOK,
            hasFullDiskAccess: fdaOK,
            isFinderSyncEnabled: finderSyncOK,
            launchAtLoginEnabled: launchAgentExists,
            isCLIAgentToolsInstalled: cliInstalled,
            detectedMacClouds: clouds
        )
    }

    private nonisolated static func checkFinderSidebarPinned(home: URL) -> Bool {
        let fm = FileManager.default
        let mysidesPaths = ["/opt/homebrew/bin/mysides", "/usr/local/bin/mysides"]
        if let mysides = mysidesPaths.first(where: { fm.isExecutableFile(atPath: $0) }) {
            let output = runCapture(mysides, ["list"])
            let lines = output.components(separatedBy: .newlines)
            if lines.contains(where: { $0.hasPrefix("My Drive ->") && !$0.contains("NOTFOUND") }) {
                return true
            }
            if !lines.isEmpty {
                return false
            }
        }
        return fm.fileExists(atPath: home.appendingPathComponent("ZeroDrive").path)
    }

    private nonisolated static func checkUserFoldersAccess(home: URL) -> Bool {
        let canReadDir: (String) -> Bool = { path in
            guard let dir = opendir(path) else { return false }
            closedir(dir)
            return true
        }
        let downloadsOK = canReadDir(home.appendingPathComponent("Downloads").path)
        let desktopOK = canReadDir(home.appendingPathComponent("Desktop").path)
        return downloadsOK && desktopOK
    }

    private nonisolated static func checkFullDiskAccess(home: URL) -> Bool {
        let protectedDirs = [
            home.appendingPathComponent("Library/Safari").path,
            home.appendingPathComponent("Library/Mail").path
        ]
        for path in protectedDirs {
            var st = stat()
            if Darwin.lstat(path, &st) == 0, let dir = opendir(path) {
                closedir(dir)
                return true
            }
        }
        return false
    }

    private nonisolated static func checkFinderSyncEnabled() -> Bool {
        let output = runCapture("/usr/bin/pluginkit", ["-m", "-i", "co.aisimple.zerodrive.FinderSync"])
        return output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains(where: { $0.hasPrefix("+") })
    }

    private nonisolated static func discoverMacClouds(home: URL, excludedPaths: Set<String>) -> [DetectedMacCloud] {
        var clouds: [DetectedMacCloud] = []

        let icloudPath = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path
        var icloudStat = stat()
        if Darwin.lstat(icloudPath, &icloudStat) == 0, (icloudStat.st_mode & S_IFMT) == S_IFDIR {
            clouds.append(DetectedMacCloud(
                id: "icloud",
                name: "iCloud Drive",
                icon: "icloud.fill",
                path: icloudPath,
                isResponsive: true,
                isIncludedInSearch: !excludedPaths.contains(icloudPath)
            ))
        }

        let cloudStoragePath = home.appendingPathComponent("Library/CloudStorage").path
        if let dir = opendir(cloudStoragePath) {
            defer { closedir(dir) }
            var entries: [String] = []
            while let entry = readdir(dir) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." || name.hasPrefix(".") || name.hasPrefix("ZeroDrive") {
                    continue
                }
                if isArchivedTimestampCloudFolder(name) {
                    continue
                }
                entries.append(name)
            }

            for name in entries.sorted() {
                let fullPath = cloudStoragePath + "/" + name
                var st = stat()
                guard Darwin.lstat(fullPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }

                var responsive = false
                if let subDir = opendir(fullPath) {
                    closedir(subDir)
                    responsive = true
                }

                let (displayName, iconName) = cloudDisplayInfo(folderName: name)
                clouds.append(DetectedMacCloud(
                    id: "cs_\(name)",
                    name: displayName,
                    icon: iconName,
                    path: fullPath,
                    isResponsive: responsive,
                    isIncludedInSearch: !excludedPaths.contains(fullPath)
                ))
            }
        }

        return clouds
    }

    private nonisolated static func isArchivedTimestampCloudFolder(_ name: String) -> Bool {
        guard name.hasSuffix(")"), let openIdx = name.lastIndex(of: "("), openIdx > name.startIndex else {
            return false
        }
        let prefix = name[..<openIdx]
        guard prefix.hasSuffix(" ") else { return false }
        let inner = name[name.index(after: openIdx)..<name.index(before: name.endIndex)]
        return inner.contains("-") && inner.contains(where: \.isNumber)
    }

    private nonisolated static func cloudDisplayInfo(folderName: String) -> (String, String) {
        let lower = folderName.lowercased()
        if lower.hasPrefix("googledrive-") {
            let account = String(folderName.dropFirst("GoogleDrive-".count))
            return ("Google Drive (\(account))", "externaldrive.connected.to.line.below")
        }
        if lower.contains("fabric") {
            return ("Fabric Drive", "folder.fill.badge.gearshape")
        }
        if lower.hasPrefix("onedrive") {
            return ("OneDrive", "cloud.fill")
        }
        if lower.hasPrefix("dropbox") {
            return ("Dropbox", "shippingbox.fill")
        }
        return (folderName, "cloud.fill")
    }

    private nonisolated static func runSync(_ executable: String, _ arguments: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    private nonisolated static func runCapture(_ executable: String, _ arguments: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
