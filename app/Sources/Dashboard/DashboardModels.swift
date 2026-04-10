import Foundation

enum DashboardDemoMode {
    static let isEnabled: Bool = {
        guard let value = ProcessInfo.processInfo.environment["DEMO"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(value)
    }()

    static func displayProjectName(_ name: String) -> String {
        guard isEnabled else {
            return name
        }
        return name.replacingOccurrences(of: "lorica", with: "mythos")
    }

    static func displayEmail(_ email: String?) -> String? {
        guard let email, isEnabled else {
            return email
        }
        return email.replacingOccurrences(of: "@getlorica.com", with: "@acme.com")
    }
}

enum DashboardStatusKind: Equatable {
    case inProgress
    case success
    case failure
    case neutral

    private static let inProgressValues: Set<String> = [
        "queued",
        "initializing",
        "running",
        "building",
        "deploying",
    ]

    private static let successValues: Set<String> = [
        "success",
        "successful",
        "succeeded",
        "deployed",
        "complete",
        "completed",
    ]

    private static let failureValues: Set<String> = [
        "fail",
        "failed",
        "failure",
        "errored",
        "error",
        "canceled",
        "cancelled",
    ]

    init(status: String?) {
        let normalized = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let normalized, Self.inProgressValues.contains(normalized) {
            self = .inProgress
            return
        }
        if let normalized, Self.successValues.contains(normalized) {
            self = .success
            return
        }
        if let normalized, Self.failureValues.contains(normalized) {
            self = .failure
            return
        }
        self = .neutral
    }
}

struct DashboardSession: Codable {
    let capturedAt: Date
    let xAtok: String
    let cookies: [DashboardCookie]
    let accountID: String?
    let workerName: String?
    let userEmail: String?
    let userDisplayName: String?
    let userAvatarURL: String?

    var storageKey: String {
        if let accountID, !accountID.isEmpty {
            return accountID
        }
        return xAtok
    }
}

struct DashboardSessionContext {
    let accountID: String
    let workerName: String?
}

struct DashboardUserProfile {
    let email: String?
    let displayName: String?
    let avatarURL: String?
}

struct DashboardCookie: Codable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expiresDate: Date?
    let isSecure: Bool
    let isHTTPOnly: Bool

    init(cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expiresDate = cookie.expiresDate
        isSecure = cookie.isSecure
        isHTTPOnly = cookie.isHTTPOnly
    }

    var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
            .secure: isSecure,
        ]
        if let expiresDate {
            properties[.expires] = expiresDate
        }
        if isHTTPOnly {
            properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }
        return HTTPCookie(properties: properties)
    }
}

struct DashboardBuild: Encodable {
    let id: String
    let status: String?
    let buildOutcome: String?
    let branch: String?
    let createdOn: String?
    let versionIDs: [String]
    let destinationURL: URL?

    var statusKind: DashboardStatusKind {
        DashboardStatusKind(status: status)
    }

    var outcomeKind: DashboardStatusKind {
        DashboardStatusKind(status: buildOutcome)
    }

    var isInProgress: Bool {
        statusKind == .inProgress
    }

    var isSuccessful: Bool {
        outcomeKind == .success || statusKind == .success
    }

    var isFailed: Bool {
        outcomeKind == .failure || statusKind == .failure
    }
}

struct DashboardProjectMetrics: Equatable {
    let requests: Int
    let errors: Int
    let averageCPUTimeMS: Double
}

struct DashboardPageDeployment: Equatable {
    let id: String?
    let latestStatus: String?
    let latestBranch: String?
    let lastReleaseAt: Date?
}

enum DashboardProjectKind: String, Codable, Equatable {
    case worker
    case page
}

struct DashboardProject: Equatable {
    let accountID: String
    let accountEmail: String?
    let kind: DashboardProjectKind
    let name: String
    let subtitle: String?
    let externalScriptID: String?
    let latestStatus: String?
    let latestBranch: String?
    let lastReleaseAt: Date?
    let metrics: DashboardProjectMetrics?
    let destinationURL: URL?

    var statusText: String? {
        latestStatus
    }

    var displayName: String {
        DashboardDemoMode.displayProjectName(name)
    }

    var displayAccountEmail: String? {
        DashboardDemoMode.displayEmail(accountEmail)
    }

    var statusKind: DashboardStatusKind {
        DashboardStatusKind(status: latestStatus)
    }

    var id: String {
        "\(accountID):\(kind.rawValue):\(name)"
    }

    var buildID: String? {
        externalScriptID.map { "\(accountID):\($0)" }
    }
}

struct DashboardHiddenProject: Codable, Equatable {
    let accountID: String
    let accountEmail: String?
    let kind: DashboardProjectKind
    let name: String

    init(project: DashboardProject) {
        accountID = project.accountID
        accountEmail = project.accountEmail
        kind = project.kind
        name = project.name
    }

    var id: String {
        "\(accountID):\(kind.rawValue):\(name)"
    }

    var displayName: String {
        DashboardDemoMode.displayProjectName(name)
    }

    var displayAccountEmail: String? {
        DashboardDemoMode.displayEmail(accountEmail)
    }
}
