import Foundation

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

    var isInProgress: Bool {
        guard let status else { return false }
        return ["queued", "initializing", "running"].contains(status.lowercased())
    }

    var isSuccessful: Bool {
        if let outcome = buildOutcome?.lowercased(), ["success", "successful", "succeeded"].contains(outcome) {
            return true
        }
        if let status = status?.lowercased(), ["success", "successful", "succeeded", "deployed", "complete", "completed"].contains(status) {
            return true
        }
        return false
    }

    var isFailed: Bool {
        if let outcome = buildOutcome?.lowercased(), ["failed", "failure", "errored", "error", "canceled", "cancelled"].contains(outcome) {
            return true
        }
        if let status = status?.lowercased(), ["failed", "failure", "errored", "error", "canceled", "cancelled"].contains(status) {
            return true
        }
        return false
    }
}

struct DashboardProjectMetrics {
    let requests: Int
    let errors: Int
    let averageCPUTimeMS: Double
}

struct DashboardPageDeployment {
    let latestStatus: String?
    let latestBranch: String?
    let lastReleaseAt: Date?
}

enum DashboardProjectKind {
    case worker
    case page
}

struct DashboardProject {
    let accountID: String
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

    var id: String {
        "\(accountID):\(kind == .worker ? "worker" : "page"):\(name)"
    }

    var buildID: String? {
        externalScriptID.map { "\(accountID):\($0)" }
    }
}
