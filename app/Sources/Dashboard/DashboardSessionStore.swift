import Foundation
import Security

enum DashboardSessionStore {
    private static let service = "\(AppBundle.bundleID).dashboard.v2"

    static func load() throws -> DashboardSession? {
        try loadAll().first
    }

    static func loadAll() throws -> [DashboardSession] {
        let sessions = try loadSessions(service: service)
        return deduplicate(sessions).sorted { $0.capturedAt > $1.capturedAt }
    }

    static func save(_ session: DashboardSession) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)

        try clear(storageKey: session.storageKey)

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: session.storageKey,
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
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DashboardError.keychain(status)
        }
    }

    static func clear(storageKey: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: storageKey,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DashboardError.keychain(status)
        }
    }

    private static func deduplicate(_ sessions: [DashboardSession]) -> [DashboardSession] {
        var unique: [String: DashboardSession] = [:]
        for session in sessions {
            if let existing = unique[session.storageKey], existing.capturedAt >= session.capturedAt {
                continue
            }
            unique[session.storageKey] = session
        }
        return Array(unique.values)
    }

    private static func loadSessions(service: String) throws -> [DashboardSession] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecItemNotFound:
            return []
        case errSecSuccess:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let rows = item as? [Data] {
                return try rows.map { try decoder.decode(DashboardSession.self, from: $0) }
            }
            if let data = item as? Data {
                return [try decoder.decode(DashboardSession.self, from: data)]
            }
            throw DashboardError.invalidSessionData
        default:
            throw DashboardError.keychain(status)
        }
    }
}

enum DashboardError: LocalizedError {
    case invalidSessionData
    case keychain(OSStatus)
    case userCancelledLogin
    case loginFailed(String)
    case userNotLoggedIn
    case requestFailed(Int, String)
    case workerNotFound(String)
    case missingAccountContext
    case notificationsDenied
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
        case .userNotLoggedIn:
            return "Not logged in."
        case let .requestFailed(code, message):
            return "Dashboard request failed with status \(code): \(message)"
        case let .workerNotFound(worker):
            return "Worker '\(worker)' was not found."
        case .missingAccountContext:
            return "Dashboard account context is missing."
        case .notificationsDenied:
            return "Notifications permission was denied."
        case .invalidResponse:
            return "Dashboard returned an invalid response."
        }
    }
}
