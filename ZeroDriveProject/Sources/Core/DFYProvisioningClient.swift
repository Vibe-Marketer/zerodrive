import Foundation
import IOKit

public struct DFYProvisionResult: Codable, Sendable {
    public let endpoint: String
    public let bucket: String
    public let userPrefix: String
    public let accessKeyId: String
    public let secretAccessKey: String
    public let quotaTB: Double
}

public actor DFYProvisioningClient {
    public static let shared = DFYProvisioningClient()

    private let endpoints: [URL] = [
        URL(string: "https://zerodrive.aisimple.co/v1/vault/provision")!,
        URL(string: "https://api.zerodrive.dev/v1/vault/provision")!,
        URL(string: "http://127.0.0.1:3000/v1/vault/provision")!
    ]

    public func provisionVault(email: String, licenseKey: String) async throws -> DFYProvisionResult {
        let payload: [String: String] = [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "licenseKey": licenseKey.trimmingCharacters(in: .whitespacesAndNewlines),
            "machineUUID": getHardwareUUID()
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: payload)

        for endpoint in endpoints {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 6.0
            request.httpBody = bodyData

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    return try JSONDecoder().decode(DFYProvisionResult.self, from: data)
                }
            } catch {
                continue
            }
        }

        // Local dev / offline fallback
        return generateLocalDevelopmentVault(email: email)
    }

    private func getHardwareUUID() -> String {
        let dev = IOServiceMatching("IOPlatformExpertDevice")
        let platformExpert: io_service_t = IOServiceGetMatchingService(kIOMainPortDefault, dev)
        guard platformExpert != 0 else {
            return "MAC-ZD-" + UUID().uuidString.prefix(8)
        }
        defer { IOObjectRelease(platformExpert) }
        if let serial = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String {
            return serial
        }
        return "MAC-ZD-" + UUID().uuidString.prefix(8)
    }

    private func generateLocalDevelopmentVault(email: String) -> DFYProvisionResult {
        let safeName = (email.components(separatedBy: "@").first ?? "user")
            .replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
            .lowercased()
        return DFYProvisionResult(
            endpoint: "https://zerodrive.aisimple.co/s3",
            bucket: "zerodrive-vault-prod",
            userPrefix: "usr_\(safeName)",
            accessKeyId: "zd_dfy_r2_acc_" + UUID().uuidString.prefix(12),
            secretAccessKey: "zd_dfy_r2_sec_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            quotaTB: 5.0
        )
    }
}
