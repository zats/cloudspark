import Foundation

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

struct DashboardPageDeployment {
    let latestStatus: String?
    let latestBranch: String?
    let lastReleaseAt: Date?
}

enum DashboardProjectKind: Equatable {
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

    var statusText: String? {
        latestStatus
    }

    var statusKind: DashboardStatusKind {
        DashboardStatusKind(status: latestStatus)
    }

    var id: String {
        "\(accountID):\(kind == .worker ? "worker" : "page"):\(name)"
    }

    var buildID: String? {
        externalScriptID.map { "\(accountID):\($0)" }
    }
}
