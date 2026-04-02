import Foundation

final class DashboardAPIClient {
    private let session: DashboardSession
    private let client: URLSession

    init(session: DashboardSession, client: URLSession = .shared) {
        self.session = session
        self.client = client
    }

    func listLatestBuilds(accountID: String, externalScriptIDs: [String]) async throws -> [DashboardBuild] {
        try await listBuilds(
            path: "/accounts/\(accountID)/builds/builds/latest",
            queryItems: [URLQueryItem(name: "external_script_ids", value: externalScriptIDs.joined(separator: ","))]
        )
    }

    func listBuilds(accountID: String, versionIDs: [String]) async throws -> [DashboardBuild] {
        try await listBuilds(
            path: "/accounts/\(accountID)/builds/builds",
            queryItems: [URLQueryItem(name: "version_ids", value: versionIDs.joined(separator: ","))]
        )
    }

    private func listBuilds(path: String, queryItems: [URLQueryItem]) async throws -> [DashboardBuild] {
        let data = try await send(path: path, queryItems: queryItems)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError(message: "Invalid dashboard response.")
        }

        if let success = object["success"] as? Bool, success == false {
            let errors = (object["errors"] as? [[String: Any]] ?? [])
                .compactMap { $0["message"] as? String }
                .joined(separator: "\n")
            throw CLIError(message: errors.isEmpty ? "Dashboard request failed." : errors)
        }

        return parseBuilds(from: object["result"])
    }

    private func send(path: String, queryItems: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(string: "https://dash.cloudflare.com/api/v4\(path)")
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw CLIError(message: "Invalid dashboard URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (field, value) in browserHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue(session.xAtok, forHTTPHeaderField: "x-atok")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await client.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CLIError(message: "Invalid dashboard response.")
        }
        guard 200 ..< 300 ~= httpResponse.statusCode else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw CLIError(message: "Dashboard request failed with status \(httpResponse.statusCode): \(message)")
        }
        return data
    }

    private var browserHeaders: [String: String] {
        [
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
            "Referer": "https://dash.cloudflare.com/",
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1",
            "x-cross-site-security": "dash",
        ]
    }

    private var cookieHeader: String {
        session.cookies
            .filter { cookie in
                guard let expiresDate = cookie.expiresDate else { return true }
                return expiresDate > Date()
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    private func parseBuilds(from value: Any?) -> [DashboardBuild] {
        if let array = value as? [[String: Any]] {
            return array.compactMap { DashboardBuild(dictionary: $0, mapKey: nil) }
        }
        if let dictionary = value as? [String: Any] {
            if let builds = dictionary["builds"] as? [[String: Any]] {
                return builds.compactMap { DashboardBuild(dictionary: $0, mapKey: nil) }
            }
            if let builds = dictionary["builds"] as? [String: Any] {
                return builds.compactMap { key, value in
                    guard let build = value as? [String: Any] else {
                        return nil
                    }
                    return DashboardBuild(dictionary: build, mapKey: key)
                }
            }
            if let items = dictionary["items"] as? [[String: Any]] {
                return items.compactMap { DashboardBuild(dictionary: $0, mapKey: nil) }
            }
            return dictionary.values
                .compactMap { $0 as? [String: Any] }
                .compactMap { DashboardBuild(dictionary: $0, mapKey: nil) }
        }
        return []
    }
}

private extension DashboardBuild {
    init?(dictionary: [String: Any], mapKey: String?) {
        let id = (dictionary["build_uuid"] as? String)
            ?? (dictionary["id"] as? String)
            ?? (dictionary["uuid"] as? String)
        guard let id, !id.isEmpty else {
            return nil
        }

        let branch = (dictionary["branch"] as? String)
            ?? (dictionary["source_branch"] as? String)
            ?? ((dictionary["build_trigger_metadata"] as? [String: Any])?["branch"] as? String)
        self.init(
            id: id,
            status: dictionary["status"] as? String,
            buildOutcome: dictionary["build_outcome"] as? String,
            branch: branch,
            createdOn: (dictionary["created_on"] as? String) ?? (dictionary["created_at"] as? String),
            versionIDs: (dictionary["version_ids"] as? [String]) ?? (mapKey.map { [$0] } ?? [])
        )
    }
}
