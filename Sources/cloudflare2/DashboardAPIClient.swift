import Foundation

final class DashboardAPIClient {
    private let session: DashboardSession
    private let client: URLSession
    private static let graphQLURL = URL(string: "https://dash.cloudflare.com/api/v4/graphql")!

    init(session: DashboardSession, client: URLSession = .shared) {
        self.session = session
        self.client = client
    }

    func listOverviewProjects(accountID: String) async throws -> [DashboardProject] {
        let data = try await send(
            path: "/accounts/\(accountID)/workers-and-pages/overview",
            queryItems: [
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "per_page", value: "10"),
                URLQueryItem(name: "sort", value: "last_modified"),
            ]
        )
        let object = try parseJSON(data)
        guard let result = object["result"] as? [[String: Any]] else {
            throw DashboardError.invalidResponse
        }

        return result.compactMap { item in
            switch item["type"] as? String {
            case "service":
                guard let service = item["service"] as? [String: Any],
                      let name = service["id"] as? String,
                      !name.isEmpty
                else {
                    return nil
                }
                let environment = service["default_environment"] as? [String: Any]
                let script = environment?["script"] as? [String: Any]
                return DashboardProject(
                    kind: .worker,
                    name: name,
                    subtitle: nil,
                    externalScriptID: (script?["tag"] as? String) ?? (environment?["script_tag"] as? String),
                    latestStatus: nil,
                    latestBranch: nil,
                    lastReleaseAt: parseDate(
                        service["modified_on"] as? String
                            ?? environment?["modified_on"] as? String
                            ?? script?["modified_on"] as? String
                    ),
                    metrics: nil
                )
            case "project":
                guard let project = item["project"] as? [String: Any],
                      let name = project["name"] as? String,
                      !name.isEmpty
                else {
                    return nil
                }
                return DashboardProject(
                    kind: .page,
                    name: name,
                    subtitle: project["subdomain"] as? String,
                    externalScriptID: nil,
                    latestStatus: nil,
                    latestBranch: nil,
                    lastReleaseAt: parseDate(project["last_activity"] as? String),
                    metrics: nil
                )
            default:
                return nil
            }
        }
    }

    func listWorkers(accountID: String) async throws -> [DashboardProject] {
        let data = try await send(
            path: "/accounts/\(accountID)/workers/scripts",
            queryItems: []
        )
        let object = try parseJSON(data)
        guard let result = object["result"] as? [[String: Any]] else {
            throw DashboardError.invalidResponse
        }

        return result.compactMap { item in
            guard let name = item["id"] as? String, !name.isEmpty else {
                return nil
            }
            return DashboardProject(
                kind: .worker,
                name: name,
                subtitle: nil,
                externalScriptID: item["tag"] as? String,
                latestStatus: nil,
                latestBranch: nil,
                lastReleaseAt: nil,
                metrics: nil
            )
        }
    }

    func listPages(accountID: String) async throws -> [DashboardProject] {
        let data = try await send(
            path: "/accounts/\(accountID)/pages/projects",
            queryItems: []
        )
        let object = try parseJSON(data)
        guard let result = object["result"] as? [[String: Any]] else {
            throw DashboardError.invalidResponse
        }

        return result.compactMap { item in
            guard let name = item["name"] as? String, !name.isEmpty else {
                return nil
            }
            let latestDeployment = item["latest_deployment"] as? [String: Any]
            let latestStage = latestDeployment?["latest_stage"] as? [String: Any]
            let trigger = latestDeployment?["deployment_trigger"] as? [String: Any]
            let metadata = trigger?["metadata"] as? [String: Any]
            return DashboardProject(
                kind: .page,
                name: name,
                subtitle: item["subdomain"] as? String,
                externalScriptID: nil,
                latestStatus: latestStage?["status"] as? String,
                latestBranch: metadata?["branch"] as? String,
                lastReleaseAt: nil,
                metrics: nil
            )
        }
    }

    func listPageDeployments(accountID: String, projectNames: [String]) async throws -> [String: DashboardPageDeployment] {
        var deployments: [String: DashboardPageDeployment] = [:]
        for name in projectNames {
            if let deployment = try await fetchPageDeployment(accountID: accountID, projectName: name) {
                deployments[name] = deployment
            }
        }
        return deployments
    }

    func listWorkerMetrics(accountID: String, now: Date = Date()) async throws -> [String: DashboardProjectMetrics] {
        let end = makePlainDateFormatter().string(from: now)
        let start = makePlainDateFormatter().string(from: now.addingTimeInterval(-24 * 60 * 60))
        let body: [String: Any] = [
            "operationName": "getServiceRequestsQuery",
            "variables": [
                "accountTag": accountID,
                "filter": [
                    "AND": [
                        [
                            "datetimeHour_leq": end,
                            "datetimeHour_geq": start,
                        ],
                    ],
                ],
            ],
            "query": """
            query getServiceRequestsQuery($accountTag: string, $filter: ZoneWorkersRequestsFilter_InputObject) {
              viewer {
                accounts(filter: {accountTag: $accountTag}) {
                  workersInvocationsAdaptive(limit: 10000, filter: $filter) {
                    sum {
                      errors
                      requests
                    }
                    quantiles {
                      cpuTimeP50
                    }
                    dimensions {
                      scriptName
                    }
                  }
                }
              }
            }
            """,
        ]
        let data = try await sendGraphQL(body: body)
        let object = try parseJSON(data)
        guard let dataObject = object["data"] as? [String: Any],
              let viewer = dataObject["viewer"] as? [String: Any],
              let accounts = viewer["accounts"] as? [[String: Any]],
              let account = accounts.first,
              let rows = account["workersInvocationsAdaptive"] as? [[String: Any]]
        else {
            throw DashboardError.invalidResponse
        }

        struct PartialMetric {
            var requests = 0
            var errors = 0
            var weightedCPUTime = 0.0
        }

        var metrics: [String: PartialMetric] = [:]
        for row in rows {
            guard let dimensions = row["dimensions"] as? [String: Any],
                  let scriptName = dimensions["scriptName"] as? String,
                  !scriptName.isEmpty
            else {
                continue
            }
            let sum = row["sum"] as? [String: Any]
            let quantiles = row["quantiles"] as? [String: Any]
            let requests = sum?["requests"] as? Int ?? 0
            let errors = sum?["errors"] as? Int ?? 0
            let cpuTimeP50 = quantiles?["cpuTimeP50"] as? Double ?? Double(quantiles?["cpuTimeP50"] as? Int ?? 0)

            metrics[scriptName, default: PartialMetric()].requests += requests
            metrics[scriptName, default: PartialMetric()].errors += errors
            metrics[scriptName, default: PartialMetric()].weightedCPUTime += cpuTimeP50 * Double(requests)
        }

        return metrics.reduce(into: [String: DashboardProjectMetrics]()) { partialResult, entry in
            let requests = max(entry.value.requests, 1)
            partialResult[entry.key] = DashboardProjectMetrics(
                requests: entry.value.requests,
                errors: entry.value.errors,
                averageCPUTimeMS: entry.value.weightedCPUTime / Double(requests) / 1000
            )
        }
    }

    func resolveExternalScriptID(accountID: String, workerName: String) async throws -> String {
        guard let match = try await listWorkers(accountID: accountID).first(where: { $0.name == workerName }),
              let tag = match.externalScriptID,
              !tag.isEmpty
        else {
            throw DashboardError.workerNotFound(workerName)
        }

        return tag
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
        let object = try parseJSON(data)
        let result = object["result"]
        return parseBuilds(from: result)
    }

    private func fetchPageDeployment(accountID: String, projectName: String) async throws -> DashboardPageDeployment? {
        guard let escapedProjectName = projectName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw DashboardError.invalidResponse
        }
        let data = try await send(
            path: "/accounts/\(accountID)/pages/projects/\(escapedProjectName)",
            queryItems: []
        )
        let object = try parseJSON(data)
        guard let result = object["result"] as? [String: Any] else {
            throw DashboardError.invalidResponse
        }
        let latestDeployment = result["latest_deployment"] as? [String: Any]
        let latestStage = latestDeployment?["latest_stage"] as? [String: Any]
        let trigger = latestDeployment?["deployment_trigger"] as? [String: Any]
        let metadata = trigger?["metadata"] as? [String: Any]
        return DashboardPageDeployment(
            latestStatus: latestStage?["status"] as? String,
            latestBranch: metadata?["branch"] as? String,
            lastReleaseAt: parseDate(
                latestDeployment?["modified_on"] as? String
                    ?? latestStage?["ended_on"] as? String
            )
        )
    }

    private func send(path: String, queryItems: [URLQueryItem], httpMethod: String = "GET", body: Data? = nil) async throws -> Data {
        var components = URLComponents(string: "https://dash.cloudflare.com/api/v4\(path)")
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw DashboardError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = httpMethod
        for (field, value) in browserHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue(session.xAtok, forHTTPHeaderField: "x-atok")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.httpBody = body

        let (data, response) = try await client.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DashboardError.invalidResponse
        }
        guard 200 ..< 300 ~= httpResponse.statusCode else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw DashboardError.requestFailed(httpResponse.statusCode, message)
        }
        return data
    }

    private func sendGraphQL(body: [String: Any]) async throws -> Data {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: Self.graphQLURL)
        request.httpMethod = "POST"
        for (field, value) in browserHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(session.xAtok, forHTTPHeaderField: "x-atok")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.httpBody = bodyData

        let (data, response) = try await client.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DashboardError.invalidResponse
        }
        guard 200 ..< 300 ~= httpResponse.statusCode else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw DashboardError.requestFailed(httpResponse.statusCode, message)
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

    private func parseJSON(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DashboardError.invalidResponse
        }
        if let errors = object["errors"] as? [[String: Any]], !errors.isEmpty {
            let message = errors
                .compactMap { $0["message"] as? String }
                .joined(separator: "\n")
            throw DashboardError.loginFailed(message.isEmpty ? "Dashboard request failed." : message)
        }
        if let success = object["success"] as? Bool, success == false {
            let errors = (object["errors"] as? [[String: Any]] ?? [])
                .compactMap { $0["message"] as? String }
                .joined(separator: "\n")
            throw DashboardError.loginFailed(errors.isEmpty ? "Dashboard request failed." : errors)
        }
        return object
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

    private func parseDate(_ value: String?) -> Date? {
        guard let value else {
            return nil
        }
        return DashboardDateParser.parse(value)
    }

    private func makePlainDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
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
        let versionIDs = (dictionary["version_ids"] as? [String]) ?? (mapKey.map { [$0] } ?? [])
        self.init(
            id: id,
            status: dictionary["status"] as? String,
            buildOutcome: dictionary["build_outcome"] as? String,
            branch: branch,
            createdOn: (dictionary["created_on"] as? String) ?? (dictionary["created_at"] as? String),
            versionIDs: versionIDs
        )
    }
}

private enum DashboardDateParser {
    private static func fractionalFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func plainFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    static func parse(_ value: String) -> Date? {
        fractionalFormatter().date(from: value) ?? plainFormatter().date(from: value)
    }
}
