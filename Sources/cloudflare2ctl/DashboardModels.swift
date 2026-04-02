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
}

struct DashboardBuild: Encodable {
    let id: String
    let status: String?
    let buildOutcome: String?
    let branch: String?
    let createdOn: String?
    let versionIDs: [String]
}
