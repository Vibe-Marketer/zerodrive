import Foundation
import FileProvider

public actor ManageFileProvider {
    public static let shared = ManageFileProvider()

    private let appGroupIdentifier = "group.co.aisimple.zerodrive"
    private let domainIdentifier = NSFileProviderDomainIdentifier("ZeroDrive")

    public func syncCredentialsToAppGroup(
        endpoint: String = "https://api.zerodrive.dev",
        token: String = "zd_sec_b07b3671b1c45b32195f8353d4df8945ee31448699a361b32b6f8192a9b03633"
    ) {
        if let groupDefaults = UserDefaults(suiteName: appGroupIdentifier) {
            groupDefaults.set(endpoint, forKey: "api_endpoint")
            groupDefaults.set(token, forKey: "api_token")
            groupDefaults.synchronize()
        }
    }

    public func registerDomainIfNeeded() async {
        syncCredentialsToAppGroup()

        let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: "ZeroDrive")
        // Clean any stale or orphaned domain state first
        do {
            try await NSFileProviderManager.remove(domain)
            NSLog("[ZeroDrive] Purged stale domain state")
        } catch {}

        do {
            try await NSFileProviderManager.add(domain)
            NSLog("[ZeroDrive] FileProvider domain successfully registered: %@", domain.displayName)
            setupCloudStorageSymlink()
        } catch {
            NSLog("[ZeroDrive] FileProvider domain registration notice: %@", error.localizedDescription)
            setupCloudStorageSymlink()
        }
    }

    public func setupCloudStorageSymlink() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cloudStoragePath = homeDir.appendingPathComponent("Library/CloudStorage/ZeroDrive").path
        let userSymlink = homeDir.appendingPathComponent("ZeroDrive").path

        if FileManager.default.fileExists(atPath: cloudStoragePath) {
            do {
                if FileManager.default.fileExists(atPath: userSymlink) {
                    let dest = try FileManager.default.destinationOfSymbolicLink(atPath: userSymlink)
                    if dest == cloudStoragePath { return }
                    try FileManager.default.removeItem(atPath: userSymlink)
                }
                try FileManager.default.createSymbolicLink(atPath: userSymlink, withDestinationPath: cloudStoragePath)
                NSLog("[ZeroDrive] Updated ~/ZeroDrive symlink -> %@", cloudStoragePath)
            } catch {
                NSLog("[ZeroDrive] Symlink update warning: %@", error.localizedDescription)
            }
        }
    }
}
