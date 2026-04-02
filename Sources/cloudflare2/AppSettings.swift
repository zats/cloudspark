import Foundation

struct AppSettings: Codable {
    let accountID: String
    let workerName: String
}

enum AppSettingsStore {
    private static let key = "cloudflare2.settings"

    static func load() -> AppSettings? {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }

    static func save(_ settings: AppSettings) throws {
        let data = try JSONEncoder().encode(settings)
        UserDefaults.standard.set(data, forKey: key)
    }
}
