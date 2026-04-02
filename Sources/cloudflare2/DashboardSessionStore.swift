import Foundation
import Security

enum DashboardSessionStore {
    private static let service = "cloudflare2.dashboard"
    private static let account = "default"

    static func load() throws -> DashboardSession? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw DashboardError.invalidSessionData
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(DashboardSession.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw DashboardError.keychain(status)
        }
    }

    static func save(_ session: DashboardSession) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)

        try clear()

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DashboardError.keychain(status)
        }
    }

    static func clear() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DashboardError.keychain(status)
        }
    }
}

enum DashboardError: LocalizedError {
    case invalidSessionData
    case keychain(OSStatus)
    case userCancelledLogin
    case loginFailed(String)
    case requestFailed(Int, String)
    case workerNotFound(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidSessionData:
            return "Stored dashboard session is invalid."
        case let .keychain(status):
            return "Keychain error: \(status)"
        case .userCancelledLogin:
            return "Dashboard login was cancelled."
        case let .loginFailed(message):
            return message
        case let .requestFailed(code, message):
            return "Dashboard request failed with status \(code): \(message)"
        case let .workerNotFound(worker):
            return "Worker '\(worker)' was not found."
        case .invalidResponse:
            return "Dashboard returned an invalid response."
        }
    }
}
