import Foundation

enum AppPreferences {
    private static let notificationsEnabledKey = "notificationsEnabled"
    private static let refreshIntervalKey = "refreshInterval"
    private static let favoriteProjectIDsKey = "favoriteProjectIDs"

    enum RefreshInterval: String, CaseIterable {
        case manual
        case seconds10
        case seconds30
        case minute1
        case minutes5

        var title: String {
            switch self {
            case .manual: "Manual"
            case .seconds10: "10s"
            case .seconds30: "30s"
            case .minute1: "1m"
            case .minutes5: "5m"
            }
        }

        var timeInterval: TimeInterval? {
            switch self {
            case .manual: nil
            case .seconds10: 10
            case .seconds30: 30
            case .minute1: 60
            case .minutes5: 300
            }
        }
    }

    static var notificationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: notificationsEnabledKey)
    }

    static func setNotificationsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: notificationsEnabledKey)
    }

    static var refreshInterval: RefreshInterval {
        guard let rawValue = UserDefaults.standard.string(forKey: refreshIntervalKey),
              let interval = RefreshInterval(rawValue: rawValue) else {
            return .seconds10
        }
        return interval
    }

    static func setRefreshInterval(_ interval: RefreshInterval) {
        UserDefaults.standard.set(interval.rawValue, forKey: refreshIntervalKey)
    }

    static var favoriteProjectIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: favoriteProjectIDsKey) ?? [])
    }

    static func setFavoriteProjectIDs(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids).sorted(), forKey: favoriteProjectIDsKey)
    }
}
