import Foundation

struct DashboardSession: Codable {
    let capturedAt: Date
    let xAtok: String
    let cookies: [DashboardCookie]
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
}
