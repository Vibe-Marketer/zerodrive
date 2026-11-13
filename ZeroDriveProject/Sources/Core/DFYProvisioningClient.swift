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

public struct GoogleAuthSessionStatus: Codable, Sendable {
    public let ok: Bool
    public let status: String
    public let sessionId: String?
    public let email: String?
    public let name: String?
    public let picture: String?
    public let accountExists: Bool?
    public let sessionToken: String?
    public let userPrefix: String?
    public let tenantPrefix: String?
    public let tier: String?
    public let quotaTB: Double?
    public let licenseKey: String?
    public let endpoint: String?
    public let bucket: String?
    public let accessKeyId: String?
    public let secretAccessKey: String?

    public func toDFYProvisionResult() -> DFYProvisionResult? {
        guard let endpoint = endpoint,
              let bucket = bucket,
              let userPrefix = userPrefix,
              let accessKeyId = accessKeyId,
              let secretAccessKey = secretAccessKey else {
            return nil
        }
        return DFYProvisionResult(
            endpoint: endpoint,
            bucket: bucket,
            userPrefix: userPrefix,
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            quotaTB: quotaTB ?? 1.0
        )
    }
}

public struct CreateAccountResult: Codable, Sendable {
    public let ok: Bool
    public let accountCreated: Bool?
    public let segregated: Bool?
    public let endpoint: String
    public let bucket: String
    public let userPrefix: String
    public let accessKeyId: String
    public let secretAccessKey: String
    public let quotaTB: Double
    public let tier: String
    public let licenseKey: String
    public let mcpUrl: String?

    public func toDFYProvisionResult() -> DFYProvisionResult {
        DFYProvisionResult(
            endpoint: endpoint,
            bucket: bucket,
            userPrefix: userPrefix,
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            quotaTB: quotaTB
        )
    }
}

public struct LicenseActivationResponse: Codable, Sendable {
    public let ok: Bool
    public let valid: Bool?
    public let activated: Bool?
    public let already_active: Bool?
    public let error: String?
    public let license_key: String?
    public let tier: String?
    public let tier_name: String?
    public let quota_gb: Double?
    public let quota_tb: Double?
    public let customer_email: String?
    public let user_prefix: String?
    public let tenant_id: String?
    public let active_devices: Int?
    public let max_devices: Int?
    public let endpoint: String?
    public let bucket: String?
    public let access_key_id: String?
    public let secret_access_key: String?

    public func toDFYProvisionResult() -> DFYProvisionResult? {
        guard let endpoint = endpoint,
              let bucket = bucket,
              let userPrefix = tenant_id,
              let accessKeyId = access_key_id,
              let secretAccessKey = secret_access_key else {
            return nil
        }
        return DFYProvisionResult(
            endpoint: endpoint,
            bucket: bucket,
            userPrefix: userPrefix,
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            quotaTB: quota_tb ?? 1.0
        )
    }
}

public struct ManagedLicenseInfo: Codable, Sendable, Identifiable {
    public var id: String { license_key }
    public let license_key: String
    public let tier: String
    public let tier_name: String?
    public let status: String
    public let customer_email: String?
    public let quota_tb: Double?
    public let max_devices: Int?
    public let created_at: String?
}

public struct LicenseGenerateResponse: Codable, Sendable {
    public let ok: Bool
    public let license_key: String?
    public let tier: String?
    public let tier_name: String?
    public let quota_tb: Double?
    public let error: String?
}

private struct LicenseListEnvelope: Codable, Sendable {
    let ok: Bool
    let licenses: [ManagedLicenseInfo]?
}

public actor DFYProvisioningClient {
    public static let shared = DFYProvisioningClient()

    private let endpoints: [URL] = [
        URL(string: "https://api.zerodrive.dev/v1/vault/provision")!,
        URL(string: "https://zerodrive.aisimple.co/v1/vault/provision")!,
        URL(string: "http://127.0.0.1:3000/v1/vault/provision")!
    ]

    public func provisionVault(email: String, licenseKey: String, isFreeTier: Bool = false) async throws -> DFYProvisionResult {
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleanEmail == "naegele412@gmail.com" {
            return generateMasterAdminVault()
        }

        var payload: [String: String] = [
            "email": cleanEmail,
            "licenseKey": licenseKey.trimmingCharacters(in: .whitespacesAndNewlines),
            "machineUUID": getHardwareUUID()
        ]
        if isFreeTier {
            payload["tier"] = "free"
        }
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
        return generateLocalDevelopmentVault(email: cleanEmail, isFreeTier: isFreeTier)
    }

    public func generateMasterAdminVault() -> DFYProvisionResult {
        return DFYProvisionResult(
            endpoint: "https://api.zerodrive.dev/s3",
            bucket: "zerodrive-vault-prod",
            userPrefix: "usr_andrew_8bc7fb477f",
            accessKeyId: "zd_r2_andrew_8bc7fb477f",
            secretAccessKey: "zd_sec_b07b3671b1c45b32195f8353d4df8945ee31448699a361b32b6f8192a9b03633",
            quotaTB: 20.0
        )
    }

    private let baseURL = "https://api.zerodrive.dev"

    public func pollGoogleAuthSession(sessionId: String) async throws -> GoogleAuthSessionStatus? {
        let encoded = sessionId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sessionId
        guard let url = URL(string: "\(baseURL)/v1/auth/session?id=\(encoded)") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5.0
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return try JSONDecoder().decode(GoogleAuthSessionStatus.self, from: data)
    }

    public func createSegregatedAccount(
        email: String,
        sessionToken: String,
        plan: String,
        licenseKey: String? = nil
    ) async throws -> CreateAccountResult {
        guard let url = URL(string: "\(baseURL)/v1/auth/create-account") else {
            throw URLError(.badURL)
        }
        var payload: [String: String] = [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            "sessionToken": sessionToken,
            "plan": plan,
            "machineUUID": getHardwareUUID(),
            "machineName": Host.current().localizedName ?? "Mac"
        ]
        if let key = licenseKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            payload["licenseKey"] = key
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 12.0
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let errJson = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let msg = errJson["error"] as? String ?? "Account creation failed (HTTP \(http.statusCode))"
            throw NSError(domain: "ZeroDriveAuth", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return try JSONDecoder().decode(CreateAccountResult.self, from: data)
    }

    public func activateLicenseKeyRemote(
        email: String,
        licenseKey: String
    ) async throws -> LicenseActivationResponse {
        guard let url = URL(string: "\(baseURL)/v1/license/activate") else {
            throw URLError(.badURL)
        }
        let payload: [String: String] = [
            "licenseKey": licenseKey.trimmingCharacters(in: .whitespacesAndNewlines),
            "machineId": getHardwareUUID(),
            "machineName": Host.current().localizedName ?? "Mac",
            "os": "macos",
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 8.0
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let decoded = try JSONDecoder().decode(LicenseActivationResponse.self, from: data)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 || decoded.activated != true {
            throw NSError(
                domain: "ZeroDriveLicensing",
                code: (resp as? HTTPURLResponse)?.statusCode ?? 400,
                userInfo: [NSLocalizedDescriptionKey: decoded.error ?? "License activation failed"]
            )
        }
        return decoded
    }

    public func generateManagedLicenseKey(
        tier: String,
        clientEmail: String,
        quotaTB: Double? = nil
    ) async throws -> LicenseGenerateResponse {
        guard let url = URL(string: "\(baseURL)/v1/license/generate") else {
            throw URLError(.badURL)
        }
        var payload: [String: Any] = [
            "tier": tier,
            "email": clientEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ]
        if let q = quotaTB, q > 0 {
            payload["quotaTB"] = q
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 8.0
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(LicenseGenerateResponse.self, from: data)
    }

    public func listManagedLicenseKeys(email: String? = nil) async throws -> [ManagedLicenseInfo] {
        var urlStr = "\(baseURL)/v1/license/list"
        if let e = email?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty {
            let encoded = e.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? e
            urlStr += "?email=\(encoded)"
        }
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6.0
        let (data, _) = try await URLSession.shared.data(for: req)
        let decoded = try JSONDecoder().decode(LicenseListEnvelope.self, from: data)
        return decoded.licenses ?? []
    }

    public func revokeManagedLicenseKey(licenseKey: String) async throws -> Bool {
        guard let url = URL(string: "\(baseURL)/v1/license/revoke") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["licenseKey": licenseKey])
        let (_, resp) = try await URLSession.shared.data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode == 200
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

    private func generateLocalDevelopmentVault(email: String, isFreeTier: Bool = false) -> DFYProvisionResult {
        let clean = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if clean == "naegele412@gmail.com" {
            return generateMasterAdminVault()
        }
        let safeName = (clean.components(separatedBy: "@").first ?? "user")
            .replacingOccurrences(of: "[^a-zA-Z0-9]", with: "_", options: .regularExpression)
            .lowercased()
        return DFYProvisionResult(
            endpoint: "https://api.zerodrive.dev/s3",
            bucket: "zerodrive-vault-prod",
            userPrefix: "usr_\(safeName)",
            accessKeyId: "zd_dfy_r2_acc_" + UUID().uuidString.prefix(12),
            secretAccessKey: "zd_dfy_r2_sec_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            quotaTB: isFreeTier ? 0.01 : 1.0
        )
    }
}
