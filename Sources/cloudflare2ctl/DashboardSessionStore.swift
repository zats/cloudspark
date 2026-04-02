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
                throw CLIError(message: "Stored session is invalid.")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(DashboardSession.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw CLIError(message: "Keychain error: \(status)")
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
            throw CLIError(message: "Keychain error: \(status)")
        }
    }
}
