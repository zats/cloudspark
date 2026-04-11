import Foundation
import CryptoKit

final class DashboardAPIClient: @unchecked Sendable {
    private let session: DashboardSession
    private let client: URLSession
    private static let graphQLURL = URL(string: "https://dash.cloudflare.com/api/v4/graphql")!

    init(session: DashboardSession, client: URLSession = .shared) {
        self.session = session
        self.client = client
    }

    func fetchCurrentUserProfile() async throws -> DashboardUserProfile {
        let data = try await send(path: "/user", queryItems: [])
        let object = try parseJSON(data)
        guard let result = object["result"] as? [String: Any] else {
            throw DashboardError.invalidResponse
        }

        let email = result["email"] as? String
        let username = (result["username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstName = (result["first_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastName = (result["last_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameComponents = ([firstName, lastName] as [String?]).compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        let displayName = nameComponents.isEmpty ? username : nameComponents.joined(separator: " ")
        let directAvatarURL = (result["avatar_url"] as? String)
            ?? (result["profile_image_url"] as? String)
            ?? (result["avatar"] as? String)
            ?? (result["image_url"] as? String)

        return DashboardUserProfile(
            email: email,
            displayName: displayName,
            avatarURL: directAvatarURL ?? email.flatMap(makeAvatarURL(email:))
        )
    }

    func resolveSessionContext() async throws -> DashboardSessionContext {
        let persistenceData = try await send(path: "/persistence/user", queryItems: [])
        guard let persistence = try JSONSerialization.jsonObject(with: persistenceData) as? [String: Any] else {
            throw DashboardError.invalidResponse
        }

        let recentsByAccount = (persistence["recents"] as? [String: Any] ?? [:]).reduce(into: [String: [[String: Any]]]()) {
            guard let items = $1.value as? [[String: Any]] else {
                return
            }
            $0[$1.key] = items
        }

        let accountID = try resolveAccountID(from: recentsByAccount)
        let workerName = recentsByAccount[accountID]?
            .filter { ($0["type"] as? String) == "worker" }
            .max { lastTimestamp(in: $0) < lastTimestamp(in: $1) }?["zone"] as? String

        return DashboardSessionContext(accountID: accountID, workerName: workerName)
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
                    accountID: accountID,
                    accountEmail: nil,
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
                    metrics: nil,
                    destinationURL: nil
                )
            case "project":
                guard let project = item["project"] as? [String: Any],
                      let name = project["name"] as? String,
                      !name.isEmpty
                else {
                    return nil
                }
                return DashboardProject(
                    accountID: accountID,
                    accountEmail: nil,
                    kind: .page,
                    name: name,
                    subtitle: project["subdomain"] as? String,
                    externalScriptID: nil,
                    latestStatus: nil,
                    latestBranch: nil,
                    lastReleaseAt: parseDate(project["last_activity"] as? String),
                    metrics: nil,
                    destinationURL: nil
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
                accountID: accountID,
                accountEmail: nil,
                kind: .worker,
                name: name,
                subtitle: nil,
                externalScriptID: item["tag"] as? String,
                latestStatus: nil,
                latestBranch: nil,
                lastReleaseAt: nil,
                metrics: nil,
                destinationURL: nil
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
                accountID: accountID,
                accountEmail: nil,
                kind: .page,
                name: name,
                subtitle: item["subdomain"] as? String,
                externalScriptID: nil,
                latestStatus: latestStage?["status"] as? String,
                latestBranch: metadata?["branch"] as? String,
                lastReleaseAt: nil,
                metrics: nil,
                destinationURL: nil
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

    func listLatestWorkerReleases(accountID: String, workers: [DashboardProject]) async throws -> [DashboardBuild] {
        let externalScriptIDs = workers.compactMap(\.externalScriptID)
        var releases = try await listLatestBuilds(accountID: accountID, externalScriptIDs: externalScriptIDs)
        let existingScriptIDs = Set(releases.flatMap(\.versionIDs))

        for worker in workers {
            guard let scriptID = worker.externalScriptID,
                  !existingScriptIDs.contains(scriptID),
                  let deployment = try await fetchLatestWorkerDeployment(
                      accountID: accountID,
                      workerName: worker.name,
                      externalScriptID: scriptID
                  )
            else {
                continue
            }
            releases.append(deployment)
        }

        return releases
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

    private func fetchLatestWorkerDeployment(accountID: String, workerName: String, externalScriptID: String) async throws -> DashboardBuild? {
        guard let escapedWorkerName = workerName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw DashboardError.invalidResponse
        }

        let data = try await send(
            path: "/accounts/\(accountID)/workers/scripts/\(escapedWorkerName)/deployments",
            queryItems: []
        )
        let object = try parseJSON(data)
        guard let result = object["result"] as? [String: Any],
              let deployments = result["deployments"] as? [[String: Any]],
              let latestDeployment = deployments.max(by: {
                  parseDate($0["created_on"] as? String) ?? .distantPast
                      < parseDate($1["created_on"] as? String) ?? .distantPast
              })
        else {
            return nil
        }

        let deploymentVersionIDs = (latestDeployment["versions"] as? [[String: Any]] ?? [])
            .compactMap { $0["version_id"] as? String }
        let versionIDs = [externalScriptID] + deploymentVersionIDs.filter { $0 != externalScriptID }

        return DashboardBuild(
            id: (latestDeployment["id"] as? String) ?? externalScriptID,
            status: nil,
            buildOutcome: "success",
            branch: nil,
            createdOn: latestDeployment["created_on"] as? String,
            versionIDs: versionIDs,
            destinationURL: workerDeploymentsURL(accountID: accountID, workerName: workerName)
        )
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
            id: latestDeployment?["id"] as? String,
            latestStatus: latestStage?["status"] as? String,
            latestBranch: metadata?["branch"] as? String,
            lastReleaseAt: parseDate(
                latestStage?["started_on"] as? String
                    ?? latestDeployment?["created_on"] as? String
                    ?? latestDeployment?["modified_on"] as? String
                    ?? latestStage?["ended_on"] as? String
            )
        )
    }

    func listObservabilityFields(
        accountID: String,
        workerName: String,
        timeframe: DashboardObservabilityTimeframe
    ) async throws -> [DashboardObservabilityField] {
        let body: [String: Any] = [
            "from": timeframe.apiValue["from"] ?? 0,
            "to": timeframe.apiValue["to"] ?? 0,
            "datasets": [],
            "filters": observabilityFilters(workerName: workerName),
            "limit": 10_000,
        ]
        let data = try await send(
            path: "/accounts/\(accountID)/workers/observability/telemetry/keys",
            queryItems: [],
            httpMethod: "POST",
            body: try JSONSerialization.data(withJSONObject: body)
        )
        let object = try parseJSON(data)
        guard let result = object["result"] as? [[String: Any]] else {
            throw DashboardError.invalidResponse
        }

        return result.compactMap { item in
            guard let key = item["key"] as? String,
                  let type = item["type"] as? String,
                  !key.isEmpty
            else {
                return nil
            }
            let lastSeenAt = item["lastSeenAt"] as? Double ?? Double(item["lastSeenAt"] as? Int64 ?? 0)
            return DashboardObservabilityField(
                key: key,
                type: type,
                lastSeenAt: lastSeenAt > 0 ? Date(timeIntervalSince1970: lastSeenAt / 1000) : nil
            )
        }
    }

    func queryObservability(
        accountID: String,
        workerName: String,
        view: DashboardObservabilityView,
        timeframe: DashboardObservabilityTimeframe
    ) async throws -> DashboardObservabilityQueryResult {
        var parameters: [String: Any] = [
            "datasets": ["cloudflare-workers", "otel"],
            "filters": observabilityFilters(workerName: workerName),
            "filterCombination": "and",
        ]

        if view == .visualizations {
            parameters["calculations"] = [["operator": "count"]]
            parameters["groupBys"] = []
            parameters["orderBy"] = [
                "value": "count",
                "limit": view.limit,
                "order": "desc",
            ]
            parameters["limit"] = view.limit
        }

        var body: [String: Any] = [
            "queryId": "workers-observability",
            "parameters": parameters,
            "timeframe": timeframe.apiValue,
            "view": view.apiView,
            "limit": view.limit,
            "offsetDirection": "next",
        ]
        if view.includesChart {
            body["chart"] = true
        }

        let data = try await send(
            path: "/accounts/\(accountID)/workers/observability/telemetry/query",
            queryItems: [],
            httpMethod: "POST",
            body: try JSONSerialization.data(withJSONObject: body)
        )
        let object = try parseJSON(data)
        guard let result = object["result"] as? [String: Any],
              let container = observabilityContainer(from: result, view: view)
        else {
            throw DashboardError.invalidResponse
        }

        let fields = parseObservabilityFields(from: container["fields"])
        let rows = parseObservabilityRows(from: container, view: view)
        let chartPoints = parseObservabilityChartPoints(from: container["series"])
        return DashboardObservabilityQueryResult(fields: fields, rows: rows, chartPoints: chartPoints)
    }

    private func observabilityContainer(from result: [String: Any], view: DashboardObservabilityView) -> [String: Any]? {
        if let container = result[view.apiView] as? [String: Any] {
            return container
        }

        if view == .visualizations,
           let calculations = result["calculations"] as? [[String: Any]]
        {
            if let first = calculations.first {
                var container = first
                if let fields = result["fields"] {
                    container["fields"] = fields
                }
                return container
            }
            return [:]
        }

        guard view == .traces else {
            return nil
        }

        let traces = result["traces"] as? [[String: Any]] ?? []
        let traceSummaries = result["traceSummaries"] as? [[String: Any]] ?? []
        guard !traces.isEmpty || !traceSummaries.isEmpty else {
            return [:]
        }

        var container: [String: Any] = [:]
        container["traces"] = !traceSummaries.isEmpty ? traceSummaries : traces
        if let fields = result["fields"] {
            container["fields"] = fields
        }
        if let series = result["series"] {
            container["series"] = series
        }
        return container
    }

    func createObservabilityLiveTailSession(
        accountID: String,
        workerName: String
    ) async throws -> DashboardObservabilityLiveTailSession {
        let body: [String: Any] = [
            "scriptId": workerName,
            "filters": [],
            "filterCombination": "and",
        ]
        let data = try await send(
            path: "/accounts/\(accountID)/workers/observability/telemetry/live-tail",
            queryItems: [],
            httpMethod: "POST",
            body: try JSONSerialization.data(withJSONObject: body)
        )
        let object = try parseJSON(data)
        let result = object["result"] as? [String: Any] ?? [:]
        let socketURL = (object["wsUrl"] as? String).flatMap(URL.init(string:))
            ?? makeLiveTailSocketURL(from: result, accountID: accountID, workerName: workerName)
        guard let socketURL else {
            throw DashboardError.invalidResponse
        }

        return DashboardObservabilityLiveTailSession(socketURL: socketURL)
    }

    func sendObservabilityLiveTailHeartbeat(
        accountID: String,
        workerName: String
    ) async throws {
        let body: [String: Any] = ["scriptId": workerName]
        _ = try await send(
            path: "/accounts/\(accountID)/workers/observability/telemetry/live-tail/heartbeat",
            queryItems: [],
            httpMethod: "POST",
            body: try JSONSerialization.data(withJSONObject: body)
        )
    }

    func fetchWorkerMetrics(
        accountID: String,
        workerName: String,
        timeframe: DashboardMetricsTimeframe,
        selectedVersionIDs: [String]?
    ) async throws -> DashboardWorkerMetricsSnapshot {
        let deployments = try await listWorkerDeployments(accountID: accountID, workerName: workerName)
        let versionOptions = uniqueMetricsVersionOptions(from: deployments)
        let activeVersionOptions = deployments.first.map { deployment in
            deployment.versions.map {
                DashboardWorkerVersionOption(
                    id: $0.versionID,
                    deployedAt: deployment.createdOn,
                    percentage: $0.percentage
                )
            }
        } ?? []
        let activeDeploymentRows = try await fetchActiveDeploymentRows(
            accountID: accountID,
            workerName: workerName,
            timeframe: timeframe,
            deployments: deployments
        )

        async let summaries = fetchWorkerMetricsSummaries(
            accountID: accountID,
            workerName: workerName,
            timeframe: timeframe,
            scriptVersions: selectedVersionIDs
        )
        async let requestsChart = fetchWorkerRequestsChart(
            accountID: accountID,
            workerName: workerName,
            timeframe: timeframe,
            scriptVersions: selectedVersionIDs
        )
        async let errorsByVersionChart = fetchWorkerErrorsByVersionChart(
            accountID: accountID,
            workerName: workerName,
            timeframe: timeframe,
            scriptVersions: selectedVersionIDs
        )
        async let errorsByStatusChart = fetchWorkerErrorsByStatusChart(
            accountID: accountID,
            workerName: workerName,
            timeframe: timeframe,
            scriptVersions: selectedVersionIDs
        )
        async let clientDisconnectedByVersionChart = fetchWorkerClientDisconnectedByVersionChart(
            accountID: accountID,
            workerName: workerName,
            timeframe: timeframe,
            scriptVersions: selectedVersionIDs
        )
        async let clientDisconnectedByTypeChart = fetchWorkerClientDisconnectedByTypeChart(
            accountID: accountID,
            workerName: workerName,
            timeframe: timeframe,
            scriptVersions: selectedVersionIDs
        )
        async let subrequests = fetchWorkerSubrequests(
            accountID: accountID,
            workerName: workerName,
            timeframe: timeframe,
            scriptVersions: selectedVersionIDs
        )
        async let requestDistribution = fetchWorkerRequestDistribution(
            accountID: accountID,
            workerName: workerName,
            timeframe: timeframe,
            scriptVersions: selectedVersionIDs
        )
        async let cpuTimeChart = fetchWorkerPercentileChart(
            accountID: accountID,
            workerName: workerName,
            timeframe: timeframe,
            scriptVersions: selectedVersionIDs,
            title: "CPU Time",
            unit: .milliseconds,
            operationName: "GetWorkerCPUTime",
            quantileFields: ["cpuTimeP50", "cpuTimeP90", "cpuTimeP99", "cpuTimeP999"]
        )
        async let wallTimeChart = fetchWorkerPercentileChart(
            accountID: accountID,
            workerName: workerName,
            timeframe: timeframe,
            scriptVersions: selectedVersionIDs,
            title: "Wall Time",
            unit: .milliseconds,
            operationName: "GetWorkerWallTime",
            quantileFields: ["wallTimeP50", "wallTimeP90", "wallTimeP99", "wallTimeP999"]
        )
        async let requestDurationChart = fetchWorkerPercentileChart(
            accountID: accountID,
            workerName: workerName,
            timeframe: timeframe,
            scriptVersions: selectedVersionIDs,
            title: "Request duration",
            unit: .milliseconds,
            operationName: "GetWorkerRequestDuration",
            quantileFields: ["requestDurationP50", "requestDurationP90", "requestDurationP99", "requestDurationP999"]
        )
        async let placementPerformance = fetchWorkerPlacementPerformance(
            accountID: accountID,
            workerName: workerName,
            timeframe: timeframe,
            scriptVersions: selectedVersionIDs
        )

        return try await DashboardWorkerMetricsSnapshot(
            versionOptions: versionOptions,
            activeVersionOptions: activeVersionOptions,
            selectedVersionIDs: selectedVersionIDs,
            summaries: summaries,
            activeDeployment: DashboardActiveDeploymentData(rows: activeDeploymentRows),
            requestsChart: requestsChart,
            errorsByVersionChart: errorsByVersionChart,
            errorsByStatusChart: errorsByStatusChart,
            clientDisconnectedByVersionChart: clientDisconnectedByVersionChart,
            clientDisconnectedByTypeChart: clientDisconnectedByTypeChart,
            cpuTimeChart: cpuTimeChart,
            wallTimeChart: wallTimeChart,
            requestDurationChart: requestDurationChart,
            subrequests: subrequests,
            requestDistribution: requestDistribution,
            placementPerformance: placementPerformance
        )
    }

    private func listWorkerDeployments(accountID: String, workerName: String) async throws -> [DashboardWorkerDeploymentRecord] {
        guard let escapedWorkerName = workerName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw DashboardError.invalidResponse
        }
        let data = try await send(
            path: "/accounts/\(accountID)/workers/scripts/\(escapedWorkerName)/deployments",
            queryItems: []
        )
        let object = try parseJSON(data)
        guard let result = object["result"] as? [String: Any],
              let deployments = result["deployments"] as? [[String: Any]]
        else {
            throw DashboardError.invalidResponse
        }

        return deployments.compactMap { deployment in
            guard let id = deployment["id"] as? String else {
                return nil
            }
            let createdOn = parseDate(deployment["created_on"] as? String)
            let versions = (deployment["versions"] as? [[String: Any]] ?? []).compactMap { version -> DashboardWorkerDeploymentVersionRecord? in
                guard let versionID = version["version_id"] as? String else {
                    return nil
                }
                let percentage = version["percentage"] as? Double ?? Double(version["percentage"] as? Int ?? 0)
                return DashboardWorkerDeploymentVersionRecord(
                    versionID: versionID,
                    percentage: percentage
                )
            }
            return DashboardWorkerDeploymentRecord(
                id: id,
                createdOn: createdOn,
                versions: versions
            )
        }
    }

    private func uniqueMetricsVersionOptions(from deployments: [DashboardWorkerDeploymentRecord]) -> [DashboardWorkerVersionOption] {
        var seen = Set<String>()
        var options: [DashboardWorkerVersionOption] = []
        for deployment in deployments {
            for version in deployment.versions where !seen.contains(version.versionID) {
                seen.insert(version.versionID)
                options.append(DashboardWorkerVersionOption(
                    id: version.versionID,
                    deployedAt: deployment.createdOn,
                    percentage: version.percentage
                ))
            }
        }
        return options
    }

    private func fetchActiveDeploymentRows(
        accountID: String,
        workerName: String,
        timeframe: DashboardMetricsTimeframe,
        deployments: [DashboardWorkerDeploymentRecord]
    ) async throws -> [DashboardActiveDeploymentRow] {
        guard let activeDeployment = deployments.first, !activeDeployment.versions.isEmpty else {
            return []
        }
        let rows = try await graphQLRows(body: [
            "operationName": "GetWorkersVersionMetrics",
            "variables": metricsVariables(
                accountID: accountID,
                workerName: workerName,
                timeframe: timeframe,
                scriptVersions: activeDeployment.versions.map(\.versionID)
            ),
            "query": """
            query GetWorkersVersionMetrics($accountTag: string!, $lookbackTime: Time, $datetimeStart: Time, $datetimeEnd: Time, $scriptName: string, $scriptVersions: [string]) {
              viewer {
                accounts(filter: {accountTag: $accountTag}) {
                  workersSubrequestsAdaptiveGroups(limit: 10000, filter: {scriptName: $scriptName, datetime_geq: $datetimeStart, datetime_leq: $datetimeEnd, scriptVersion_in: $scriptVersions}) {
                    sum {
                      subrequests
                      __typename
                    }
                    dimensions {
                      cacheStatus
                      scriptVersion
                      __typename
                    }
                    __typename
                  }
                  workersInvocationsAdaptive(limit: 10000, filter: {scriptName: $scriptName, datetime_geq: $datetimeStart, datetime_leq: $datetimeEnd, scriptVersion_in: $scriptVersions}) {
                    sum {
                      requests
                      errors
                      __typename
                    }
                    quantiles {
                      cpuTimeP50
                      __typename
                    }
                    dimensions {
                      scriptVersion
                      datetimeFifteenMinutes
                      __typename
                    }
                    __typename
                  }
                  __typename
                }
                __typename
              }
            }
            """
        ], field: "workersInvocationsAdaptive")

        var requestsByVersion: [String: Int] = [:]
        var errorsByVersion: [String: Int] = [:]
        var weightedCPUByVersion: [String: Double] = [:]
        var latestRateByVersion: [String: Double] = [:]
        var latestBucketDateByVersion: [String: Date] = [:]

        for row in rows {
            guard let dimensions = row["dimensions"] as? [String: Any],
                  let versionID = dimensions["scriptVersion"] as? String
            else {
                continue
            }
            let sum = row["sum"] as? [String: Any] ?? [:]
            let quantiles = row["quantiles"] as? [String: Any] ?? [:]
            let requests = intValue(sum["requests"])
            let errors = intValue(sum["errors"])
            let cpuTimeP50 = doubleValue(quantiles["cpuTimeP50"]) / 1000

            requestsByVersion[versionID, default: 0] += requests
            errorsByVersion[versionID, default: 0] += errors
            weightedCPUByVersion[versionID, default: 0] += cpuTimeP50 * Double(requests)

            if let bucketDate = parseDate(dimensions["datetimeFifteenMinutes"] as? String),
               latestBucketDateByVersion[versionID] == nil || bucketDate >= latestBucketDateByVersion[versionID, default: .distantPast]
            {
                latestBucketDateByVersion[versionID] = bucketDate
                latestRateByVersion[versionID] = Double(requests) / (15 * 60)
            }
        }

        return activeDeployment.versions.map { version in
            let requests = requestsByVersion[version.versionID, default: 0]
            let errors = errorsByVersion[version.versionID, default: 0]
            let weightedCPU = weightedCPUByVersion[version.versionID, default: 0]
            let cpuMS = requests > 0 ? weightedCPU / Double(requests) : 0
            let errorRate = requests > 0 ? Double(errors) / Double(requests) : 0
            return DashboardActiveDeploymentRow(
                id: version.versionID,
                deployedAt: activeDeployment.createdOn,
                trafficPercent: version.percentage,
                requestsPerSecond: latestRateByVersion[version.versionID, default: 0],
                errorRate: errorRate,
                medianCPUTimeMS: cpuMS
            )
        }
    }

    private func fetchWorkerMetricsSummaries(
        accountID: String,
        workerName: String,
        timeframe: DashboardMetricsTimeframe,
        scriptVersions: [String]?
    ) async throws -> [DashboardMetricsSummaryCardData] {
        let body: [String: Any] = [
            "operationName": "getWorkerAnalytics",
            "variables": metricsVariables(
                accountID: accountID,
                workerName: workerName,
                timeframe: timeframe,
                scriptVersions: scriptVersions,
                includeLookback: true
            ),
            "query": """
            query getWorkerAnalytics($accountTag: string!, $lookbackTime: Time, $datetimeStart: Time, $datetimeEnd: Time, $scriptName: string, $scriptVersions: [string]) {
              viewer {
                accounts(filter: {accountTag: $accountTag}) {
                  workersSubrequestsAdaptiveGroups(limit: 10000, filter: {scriptName: $scriptName, datetime_geq: $datetimeStart, datetime_leq: $datetimeEnd, scriptVersion_in: $scriptVersions}) {
                    sum {
                      subrequests
                      __typename
                    }
                    dimensions {
                      datetimeFifteenMinutes
                      __typename
                    }
                    __typename
                  }
                  workersInvocationsAdaptive(limit: 10000, filter: {scriptName: $scriptName, datetime_geq: $datetimeStart, datetime_leq: $datetimeEnd, scriptVersion_in: $scriptVersions}) {
                    sum {
                      subrequests
                      requests
                      errors
                      duration
                      __typename
                    }
                    quantiles {
                      cpuTimeP50
                      wallTimeP50
                      durationP50
                      requestDurationP50
                      __typename
                    }
                    dimensions {
                      datetimeFifteenMinutes
                      __typename
                    }
                    __typename
                  }
                  previous: workersInvocationsAdaptive(limit: 10000, filter: {scriptName: $scriptName, datetime_geq: $lookbackTime, datetime_leq: $datetimeStart, scriptVersion_in: $scriptVersions}) {
                    sum {
                      subrequests
                      requests
                      errors
                      duration
                      __typename
                    }
                    quantiles {
                      cpuTimeP50
                      wallTimeP50
                      requestDurationP50
                      __typename
                    }
                    __typename
                  }
                  __typename
                }
                __typename
              }
            }
            """
        ]
        let account = try await graphQLAccount(body: body)
        let currentRows = account["workersInvocationsAdaptive"] as? [[String: Any]] ?? []
        let subrequestRows = account["workersSubrequestsAdaptiveGroups"] as? [[String: Any]] ?? []
        let previousRows = account["previous"] as? [[String: Any]] ?? []

        let requests = currentRows.reduce(0) { $0 + intValue(($1["sum"] as? [String: Any])?["requests"]) }
        let errors = currentRows.reduce(0) { $0 + intValue(($1["sum"] as? [String: Any])?["errors"]) }
        let subrequests = subrequestRows.reduce(0) { $0 + intValue(($1["sum"] as? [String: Any])?["subrequests"]) }
        let cpuTimeMS = weightedQuantileAverage(rows: currentRows, field: "cpuTimeP50")
        let wallTimeMS = weightedQuantileAverage(rows: currentRows, field: "wallTimeP50")
        let requestDurationMS = weightedQuantileAverage(rows: currentRows, field: "requestDurationP50")

        let previous = previousRows.first
        let previousSum = previous?["sum"] as? [String: Any] ?? [:]
        let previousQuantiles = previous?["quantiles"] as? [String: Any] ?? [:]
        let previousRequests = intValue(previousSum["requests"])
        let previousErrors = intValue(previousSum["errors"])
        let previousSubrequests = intValue(previousSum["subrequests"])
        let previousCPU = doubleValue(previousQuantiles["cpuTimeP50"]) / 1000
        let previousWall = doubleValue(previousQuantiles["wallTimeP50"]) / 1000
        let previousRequestDuration = doubleValue(previousQuantiles["requestDurationP50"]) / 1000

        return [
            DashboardMetricsSummaryCardData(
                id: "requests",
                title: "Requests",
                value: Double(requests),
                unit: .count,
                deltaRatio: deltaRatio(current: Double(requests), previous: Double(previousRequests))
            ),
            DashboardMetricsSummaryCardData(
                id: "subrequests",
                title: "Subrequests",
                value: Double(subrequests),
                unit: .count,
                deltaRatio: deltaRatio(current: Double(subrequests), previous: Double(previousSubrequests))
            ),
            DashboardMetricsSummaryCardData(
                id: "errors",
                title: "Errors",
                value: Double(errors),
                unit: .count,
                deltaRatio: deltaRatio(current: Double(errors), previous: Double(previousErrors))
            ),
            DashboardMetricsSummaryCardData(
                id: "cpu",
                title: "CPU Time",
                value: cpuTimeMS,
                unit: .milliseconds,
                deltaRatio: deltaRatio(current: cpuTimeMS, previous: previousCPU)
            ),
            DashboardMetricsSummaryCardData(
                id: "wall",
                title: "Wall Time",
                value: wallTimeMS,
                unit: .milliseconds,
                deltaRatio: deltaRatio(current: wallTimeMS, previous: previousWall)
            ),
            DashboardMetricsSummaryCardData(
                id: "request-duration",
                title: "Request duration",
                value: requestDurationMS,
                unit: .milliseconds,
                deltaRatio: deltaRatio(current: requestDurationMS, previous: previousRequestDuration)
            ),
        ]
    }

    private func fetchWorkerRequestsChart(
        accountID: String,
        workerName: String,
        timeframe: DashboardMetricsTimeframe,
        scriptVersions: [String]?
    ) async throws -> DashboardMetricsChartData {
        let rows = try await graphQLRows(body: [
            "operationName": "GetWorkerRequests",
            "variables": metricsVariables(accountID: accountID, workerName: workerName, timeframe: timeframe, scriptVersions: scriptVersions),
            "query": """
            query GetWorkerRequests($accountTag: string!, $datetimeStart: Time, $datetimeEnd: Time, $scriptName: string, $scriptVersions: [string]) {
              viewer {
                accounts(filter: {accountTag: $accountTag}) {
                  workersInvocationsAdaptive(limit: 10000, filter: {scriptName: $scriptName, datetime_geq: $datetimeStart, datetime_leq: $datetimeEnd, scriptVersion_in: $scriptVersions, scriptVersion_neq: ""}, orderBy: [datetimeFifteenMinutes_ASC]) {
                    sum {
                      requests
                      __typename
                    }
                    dimensions {
                      datetimeFifteenMinutes
                      scriptVersion
                      __typename
                    }
                    __typename
                  }
                  __typename
                }
                __typename
              }
            }
            """
        ], field: "workersInvocationsAdaptive")
        return makeGroupedInvocationChart(
            title: "Requests",
            unit: .count,
            valueField: "requests",
            groupField: "scriptVersion",
            rows: rows,
            emptyMessage: "No requests"
        )
    }

    private func fetchWorkerErrorsByVersionChart(
        accountID: String,
        workerName: String,
        timeframe: DashboardMetricsTimeframe,
        scriptVersions: [String]?
    ) async throws -> DashboardMetricsChartData {
        let rows = try await graphQLRows(body: [
            "operationName": "GetWorkerRequests",
            "variables": metricsVariables(accountID: accountID, workerName: workerName, timeframe: timeframe, scriptVersions: scriptVersions),
            "query": """
            query GetWorkerRequests($accountTag: string!, $datetimeStart: Time, $datetimeEnd: Time, $scriptName: string, $scriptVersions: [string]) {
              viewer {
                accounts(filter: {accountTag: $accountTag}) {
                  workersInvocationsAdaptive(limit: 10000, filter: {scriptName: $scriptName, datetime_geq: $datetimeStart, datetime_leq: $datetimeEnd, scriptVersion_in: $scriptVersions}, orderBy: [datetimeFifteenMinutes_ASC]) {
                    sum {
                      errors
                      __typename
                    }
                    dimensions {
                      datetimeFifteenMinutes
                      scriptVersion
                      __typename
                    }
                    __typename
                  }
                  __typename
                }
                __typename
              }
            }
            """
        ], field: "workersInvocationsAdaptive")
        return makeGroupedInvocationChart(
            title: "Errors by version",
            unit: .count,
            valueField: "errors",
            groupField: "scriptVersion",
            rows: rows,
            emptyMessage: "No errors"
        )
    }

    private func fetchWorkerErrorsByStatusChart(
        accountID: String,
        workerName: String,
        timeframe: DashboardMetricsTimeframe,
        scriptVersions: [String]?
    ) async throws -> DashboardMetricsChartData {
        let rows = try await graphQLRows(body: [
            "operationName": "GetWorkerRequests",
            "variables": metricsVariables(accountID: accountID, workerName: workerName, timeframe: timeframe, scriptVersions: scriptVersions),
            "query": """
            query GetWorkerRequests($accountTag: string!, $datetimeStart: Time, $datetimeEnd: Time, $scriptName: string, $scriptVersions: [string]) {
              viewer {
                accounts(filter: {accountTag: $accountTag}) {
                  workersInvocationsAdaptive(limit: 10000, filter: {scriptName: $scriptName, status_notin: ["success", "clientDisconnected", "responseStreamDisconnected"], datetime_geq: $datetimeStart, datetime_leq: $datetimeEnd, scriptVersion_in: $scriptVersions}, orderBy: [datetimeFifteenMinutes_ASC]) {
                    sum {
                      errors
                      __typename
                    }
                    dimensions {
                      datetimeFifteenMinutes
                      status
                      __typename
                    }
                    __typename
                  }
                  __typename
                }
                __typename
              }
            }
            """
        ], field: "workersInvocationsAdaptive")
        return makeGroupedInvocationChart(
            title: "Errors by invocation status",
            unit: .count,
            valueField: "errors",
            groupField: "status",
            rows: rows,
            emptyMessage: "No errors"
        )
    }

    private func fetchWorkerClientDisconnectedByVersionChart(
        accountID: String,
        workerName: String,
        timeframe: DashboardMetricsTimeframe,
        scriptVersions: [String]?
    ) async throws -> DashboardMetricsChartData {
        let rows = try await graphQLRows(body: [
            "operationName": "GetWorkerRequests",
            "variables": metricsVariables(accountID: accountID, workerName: workerName, timeframe: timeframe, scriptVersions: scriptVersions),
            "query": """
            query GetWorkerRequests($accountTag: string!, $datetimeStart: Time, $datetimeEnd: Time, $scriptName: string, $scriptVersions: [string]) {
              viewer {
                accounts(filter: {accountTag: $accountTag}) {
                  workersInvocationsAdaptive(limit: 10000, filter: {scriptName: $scriptName, status_in: ["clientDisconnected", "responseStreamDisconnected"], datetime_geq: $datetimeStart, datetime_leq: $datetimeEnd, scriptVersion_in: $scriptVersions}, orderBy: [datetimeFifteenMinutes_ASC]) {
                    sum {
                      clientDisconnects
                      __typename
                    }
                    dimensions {
                      datetimeFifteenMinutes
                      scriptVersion
                      __typename
                    }
                    __typename
                  }
                  __typename
                }
                __typename
              }
            }
            """
        ], field: "workersInvocationsAdaptive")
        return makeGroupedInvocationChart(
            title: "Client disconnected by version",
            unit: .count,
            valueField: "clientDisconnects",
            groupField: "scriptVersion",
            rows: rows,
            emptyMessage: "No client disconnects"
        )
    }

    private func fetchWorkerClientDisconnectedByTypeChart(
        accountID: String,
        workerName: String,
        timeframe: DashboardMetricsTimeframe,
        scriptVersions: [String]?
    ) async throws -> DashboardMetricsChartData {
        let rows = try await graphQLRows(body: [
            "operationName": "GetWorkerRequests",
            "variables": metricsVariables(accountID: accountID, workerName: workerName, timeframe: timeframe, scriptVersions: scriptVersions),
            "query": """
            query GetWorkerRequests($accountTag: string!, $datetimeStart: Time, $datetimeEnd: Time, $scriptName: string, $scriptVersions: [string]) {
              viewer {
                accounts(filter: {accountTag: $accountTag}) {
                  workersInvocationsAdaptive(limit: 10000, filter: {scriptName: $scriptName, status_in: ["clientDisconnected", "responseStreamDisconnected"], datetime_geq: $datetimeStart, datetime_leq: $datetimeEnd, scriptVersion_in: $scriptVersions}, orderBy: [datetimeFifteenMinutes_ASC]) {
                    sum {
                      clientDisconnects
                      __typename
                    }
                    dimensions {
                      datetimeFifteenMinutes
                      status
                      __typename
                    }
                    __typename
                  }
                  __typename
                }
                __typename
              }
            }
            """
        ], field: "workersInvocationsAdaptive")
        return makeGroupedInvocationChart(
            title: "Client disconnected by type",
            unit: .count,
            valueField: "clientDisconnects",
            groupField: "status",
            rows: rows,
            emptyMessage: "No client disconnects"
        )
    }

    private func fetchWorkerSubrequests(
        accountID: String,
        workerName: String,
        timeframe: DashboardMetricsTimeframe,
        scriptVersions: [String]?
    ) async throws -> [DashboardWorkerSubrequestRow] {
        let rows = try await graphQLRows(body: [
            "operationName": "GetWorkerSubRequests",
            "variables": metricsVariables(accountID: accountID, workerName: workerName, timeframe: timeframe, scriptVersions: scriptVersions),
            "query": """
            query GetWorkerSubRequests($accountTag: string!, $datetimeStart: Time, $datetimeEnd: Time, $scriptName: string, $scriptVersions: [string]) {
              viewer {
                accounts(filter: {accountTag: $accountTag}) {
                  workersSubrequestsAdaptiveGroups(limit: 10000, filter: {scriptName: $scriptName, datetime_geq: $datetimeStart, datetime_leq: $datetimeEnd, scriptVersion_in: $scriptVersions}, orderBy: [sum_subrequests_DESC]) {
                    quantiles {
                      timeToResponseUsP50
                      timeToResponseDrainedUsP50
                      __typename
                    }
                    sum {
                      subrequests
                      __typename
                    }
                    dimensions {
                      httpResponseStatus
                      hostname
                      cacheStatus
                      __typename
                    }
                    __typename
                  }
                  __typename
                }
                __typename
              }
            }
            """
        ], field: "workersSubrequestsAdaptiveGroups")

        struct PartialRow {
            var counts: [String: Int] = [:]
            var weightedDuration = 0.0
            var totalRequests = 0
        }

        var grouped: [String: PartialRow] = [:]
        for row in rows {
            let dimensions = row["dimensions"] as? [String: Any] ?? [:]
            let quantiles = row["quantiles"] as? [String: Any] ?? [:]
            let sum = row["sum"] as? [String: Any] ?? [:]

            let hostname = ((dimensions["hostname"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
                ? "Unknown"
                : (dimensions["hostname"] as? String ?? "Unknown")
            let requests = intValue(sum["subrequests"])
            let statusCode = intValue(dimensions["httpResponseStatus"])
            let statusClass = subrequestStatusClass(statusCode: statusCode)
            let durationMS = max(
                doubleValue(quantiles["timeToResponseDrainedUsP50"]),
                doubleValue(quantiles["timeToResponseUsP50"])
            ) / 1000

            grouped[hostname, default: PartialRow()].counts[statusClass, default: 0] += requests
            grouped[hostname, default: PartialRow()].weightedDuration += durationMS * Double(requests)
            grouped[hostname, default: PartialRow()].totalRequests += requests
        }

        return grouped.map { host, partial in
            DashboardWorkerSubrequestRow(
                id: host,
                host: DashboardDemoMode.displayObservabilityText(host),
                countsByStatusClass: partial.counts,
                averageDurationMS: partial.totalRequests > 0 ? partial.weightedDuration / Double(partial.totalRequests) : 0
            )
        }
        .sorted { lhs, rhs in
            lhs.totalRequests > rhs.totalRequests
        }
    }

    private func fetchWorkerRequestDistribution(
        accountID: String,
        workerName: String,
        timeframe: DashboardMetricsTimeframe,
        scriptVersions: [String]?
    ) async throws -> [DashboardRequestDistributionRow] {
        let rows = try await graphQLRows(body: [
            "operationName": "GetWorkerRequestDistribution",
            "variables": metricsVariables(accountID: accountID, workerName: workerName, timeframe: timeframe, scriptVersions: scriptVersions),
            "query": """
            query GetWorkerRequestDistribution($accountTag: string!, $datetimeStart: Time, $datetimeEnd: Time, $scriptName: string, $scriptVersions: [string]) {
              viewer {
                accounts(filter: {accountTag: $accountTag}) {
                  workersInvocationsAdaptive(limit: 10000, filter: {scriptName: $scriptName, datetime_geq: $datetimeStart, datetime_leq: $datetimeEnd, scriptVersion_in: $scriptVersions}) {
                    sum {
                      requests
                      __typename
                    }
                    dimensions {
                      coloCode
                      __typename
                    }
                    __typename
                  }
                  __typename
                }
                __typename
              }
            }
            """
        ], field: "workersInvocationsAdaptive")

        return rows.compactMap { row in
            let dimensions = row["dimensions"] as? [String: Any] ?? [:]
            guard let coloCode = dimensions["coloCode"] as? String, !coloCode.isEmpty else {
                return nil
            }
            let sum = row["sum"] as? [String: Any] ?? [:]
            return DashboardRequestDistributionRow(
                id: coloCode,
                coloCode: coloCode,
                requests: intValue(sum["requests"])
            )
        }
        .sorted { lhs, rhs in
            lhs.requests > rhs.requests
        }
    }

    private func fetchWorkerPercentileChart(
        accountID: String,
        workerName: String,
        timeframe: DashboardMetricsTimeframe,
        scriptVersions: [String]?,
        title: String,
        unit: DashboardMetricsValueUnit,
        operationName: String,
        quantileFields: [String]
    ) async throws -> DashboardMetricsChartData {
        let quantileSelection = quantileFields
            .map { "\($0)\n" }
            .joined()
        let rows = try await graphQLRows(body: [
            "operationName": operationName,
            "variables": metricsVariables(accountID: accountID, workerName: workerName, timeframe: timeframe, scriptVersions: scriptVersions),
            "query": """
            query \(operationName)($accountTag: string!, $datetimeStart: Time, $datetimeEnd: Time, $scriptName: string, $scriptVersions: [string]) {
              viewer {
                accounts(filter: {accountTag: $accountTag}) {
                  workersInvocationsAdaptive(limit: 10000, filter: {scriptName: $scriptName, datetime_geq: $datetimeStart, datetime_leq: $datetimeEnd, scriptVersion_in: $scriptVersions}, orderBy: [datetimeFifteenMinutes_ASC]) {
                    quantiles {
                        \(quantileSelection)          
                        __typename
                    }
                    dimensions {
                      datetimeFifteenMinutes
                      __typename
                    }
                    __typename
                  }
                  __typename
                }
                __typename
              }
            }
            """
        ], field: "workersInvocationsAdaptive")

        let labels = ["P50", "P90", "P99", "P999"]
        let series = zip(labels, quantileFields).map { label, field in
            DashboardMetricsSeries(
                id: field,
                title: label,
                points: rows.compactMap { row in
                    let dimensions = row["dimensions"] as? [String: Any] ?? [:]
                    let quantiles = row["quantiles"] as? [String: Any] ?? [:]
                    guard let date = parseDate(dimensions["datetimeFifteenMinutes"] as? String) else {
                        return nil
                    }
                    let value = doubleValue(quantiles[field]) / 1000
                    return DashboardMetricsPoint(id: "\(field)-\(date.timeIntervalSince1970)", date: date, value: value)
                }
            )
        }
        .filter { !$0.points.isEmpty }

        return DashboardMetricsChartData(
            title: title,
            unit: unit,
            style: .line,
            series: series,
            emptyMessage: "No data"
        )
    }

    private func fetchWorkerPlacementPerformance(
        accountID: String,
        workerName: String,
        timeframe: DashboardMetricsTimeframe,
        scriptVersions: [String]?
    ) async throws -> [DashboardPlacementPerformanceRow] {
        let rows = try await graphQLRows(body: [
            "operationName": "GetWorkerPlacementPerformance",
            "variables": metricsVariables(accountID: accountID, workerName: workerName, timeframe: timeframe, scriptVersions: scriptVersions),
            "query": """
            query GetWorkerPlacementPerformance($accountTag: string!, $datetimeStart: Time, $datetimeEnd: Time, $scriptName: string, $scriptVersions: [string]) {
              viewer {
                accounts(filter: {accountTag: $accountTag}) {
                  workerPlacementAdaptiveGroups(limit: 10000, filter: {scriptName: $scriptName, datetime_geq: $datetimeStart, datetime_leq: $datetimeEnd, scriptVersion_in: $scriptVersions}) {
                    quantiles {
                      requestDurationP90
                      __typename
                    }
                    dimensions {
                      placementUsed
                      clientColoCode
                      __typename
                    }
                    __typename
                  }
                  __typename
                }
                __typename
              }
            }
            """
        ], field: "workerPlacementAdaptiveGroups")

        return rows.compactMap { row in
            let dimensions = row["dimensions"] as? [String: Any] ?? [:]
            let quantiles = row["quantiles"] as? [String: Any] ?? [:]
            let placementUsed = dimensions["placementUsed"] as? String ?? "unknown"
            let coloCode = dimensions["clientColoCode"] as? String ?? "Unknown"
            return DashboardPlacementPerformanceRow(
                id: "\(placementUsed)-\(coloCode)",
                placementUsed: placementUsed,
                coloCode: coloCode,
                p90DurationMS: doubleValue(quantiles["requestDurationP90"]) / 1000
            )
        }
        .sorted { lhs, rhs in
            lhs.p90DurationMS > rhs.p90DurationMS
        }
    }

    private func makeGroupedInvocationChart(
        title: String,
        unit: DashboardMetricsValueUnit,
        valueField: String,
        groupField: String,
        rows: [[String: Any]],
        emptyMessage: String
    ) -> DashboardMetricsChartData {
        var grouped: [String: [DashboardMetricsPoint]] = [:]
        for row in rows {
            let dimensions = row["dimensions"] as? [String: Any] ?? [:]
            let sum = row["sum"] as? [String: Any] ?? [:]
            guard let date = parseDate(dimensions["datetimeFifteenMinutes"] as? String) else {
                continue
            }
            let rawGroup = dimensions[groupField] as? String ?? "Unknown"
            let group = prettifyMetricsGroup(rawGroup, field: groupField)
            let value = doubleValue(sum[valueField])
            grouped[group, default: []].append(DashboardMetricsPoint(
                id: "\(group)-\(date.timeIntervalSince1970)",
                date: date,
                value: value
            ))
        }

        let series = grouped.map { key, points in
            DashboardMetricsSeries(
                id: key,
                title: key,
                points: points.sorted { $0.date < $1.date }
            )
        }
        .sorted { lhs, rhs in
            lhs.total > rhs.total
        }

        return DashboardMetricsChartData(
            title: title,
            unit: unit,
            style: .bar,
            series: compactMetricsSeries(series),
            emptyMessage: emptyMessage
        )
    }

    private func compactMetricsSeries(_ series: [DashboardMetricsSeries], maxVisibleSeries: Int = 5) -> [DashboardMetricsSeries] {
        guard series.count > maxVisibleSeries else {
            return series
        }
        let visible = Array(series.prefix(maxVisibleSeries))
        let hidden = series.dropFirst(maxVisibleSeries)
        let allDates = Set(hidden.flatMap { $0.points.map(\.date) }).sorted()
        let groupedPoints = allDates.map { date in
            DashboardMetricsPoint(
                id: "other-\(date.timeIntervalSince1970)",
                date: date,
                value: hidden.reduce(0) { partial, series in
                    partial + (series.points.first(where: { $0.date == date })?.value ?? 0)
                }
            )
        }
        .filter { $0.value > 0 }
        guard !groupedPoints.isEmpty else {
            return visible
        }
        return visible + [
            DashboardMetricsSeries(
                id: "other",
                title: "Other",
                points: groupedPoints
            )
        ]
    }

    private func graphQLAccount(body: [String: Any]) async throws -> [String: Any] {
        let data = try await sendGraphQL(body: body)
        let object = try parseJSON(data)
        guard let dataObject = object["data"] as? [String: Any],
              let viewer = dataObject["viewer"] as? [String: Any],
              let accounts = viewer["accounts"] as? [[String: Any]],
              let account = accounts.first
        else {
            throw DashboardError.invalidResponse
        }
        return account
    }

    private func graphQLRows(body: [String: Any], field: String) async throws -> [[String: Any]] {
        let account = try await graphQLAccount(body: body)
        guard let rows = account[field] as? [[String: Any]] else {
            throw DashboardError.invalidResponse
        }
        return rows
    }

    private func metricsVariables(
        accountID: String,
        workerName: String,
        timeframe: DashboardMetricsTimeframe,
        scriptVersions: [String]?,
        includeLookback: Bool = false
    ) -> [String: Any] {
        var variables: [String: Any] = [
            "accountTag": accountID,
            "datetimeStart": makePlainDateFormatter().string(from: timeframe.start),
            "datetimeEnd": makePlainDateFormatter().string(from: timeframe.end),
            "scriptName": workerName,
        ]
        if let scriptVersions, !scriptVersions.isEmpty {
            variables["scriptVersions"] = scriptVersions
        }
        if includeLookback {
            variables["lookbackTime"] = makePlainDateFormatter().string(from: timeframe.start.addingTimeInterval(-timeframe.duration))
        }
        return variables
    }

    private func weightedQuantileAverage(rows: [[String: Any]], field: String) -> Double {
        let totalRequests = rows.reduce(0) { $0 + intValue(($1["sum"] as? [String: Any])?["requests"]) }
        guard totalRequests > 0 else {
            return 0
        }
        let weightedTotal = rows.reduce(0.0) { partial, row in
            let sum = row["sum"] as? [String: Any] ?? [:]
            let quantiles = row["quantiles"] as? [String: Any] ?? [:]
            let requests = intValue(sum["requests"])
            return partial + (doubleValue(quantiles[field]) / 1000) * Double(requests)
        }
        return weightedTotal / Double(totalRequests)
    }

    private func deltaRatio(current: Double, previous: Double) -> Double? {
        guard previous != 0 else {
            return current == 0 ? 0 : nil
        }
        return (current - previous) / previous
    }

    private func intValue(_ value: Any?) -> Int {
        value as? Int ?? Int(value as? Double ?? 0)
    }

    private func doubleValue(_ value: Any?) -> Double {
        value as? Double ?? Double(value as? Int ?? 0)
    }

    private func prettifyMetricsGroup(_ value: String, field: String) -> String {
        if field == "scriptVersion" {
            return String(value.prefix(8))
        }
        switch value {
        case "clientDisconnected":
            return "Cancelled"
        case "responseStreamDisconnected":
            return "Response stream disconnected"
        case "internal":
            return "Internal"
        case "exceededMemory":
            return "Exceeded Memory"
        case "exceededCpu":
            return "Exceeded CPU Time Limits"
        case "exceededCpuTime":
            return "Exceeded CPU Time Limits"
        case "loadShed":
            return "Load Shed"
        case "uncaughtException":
            return "Uncaught Exception"
        default:
            return value.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func subrequestStatusClass(statusCode: Int) -> String {
        switch statusCode {
        case 200 ..< 300: "2xx"
        case 300 ..< 400: "3xx"
        case 400 ..< 500: "4xx"
        case 500 ..< 600: "5xx"
        default: "Other"
        }
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
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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

    private func observabilityFilters(workerName: String) -> [[String: Any]] {
        [[
            "key": "$metadata.service",
            "type": "string",
            "value": workerName,
            "operation": "eq",
        ]]
    }

    private func parseObservabilityFields(from value: Any?) -> [DashboardObservabilityField] {
        guard let fields = value as? [[String: Any]] else {
            return []
        }
        return fields.compactMap { item in
            guard let key = item["key"] as? String,
                  let type = item["type"] as? String,
                  !key.isEmpty
            else {
                return nil
            }
            let lastSeenAt = item["lastSeenAt"] as? Double ?? Double(item["lastSeenAt"] as? Int64 ?? 0)
            return DashboardObservabilityField(
                key: key,
                type: type,
                lastSeenAt: lastSeenAt > 0 ? Date(timeIntervalSince1970: lastSeenAt / 1000) : nil
            )
        }
    }

    private func parseObservabilityRows(from container: [String: Any], view: DashboardObservabilityView) -> [DashboardObservabilityRow] {
        guard view != .visualizations else {
            return []
        }
        let rowArrays: [[[String: Any]]] = [
            container[view.apiView] as? [[String: Any]] ?? [],
            container["events"] as? [[String: Any]] ?? [],
            container["invocations"] as? [[String: Any]] ?? [],
            container["traces"] as? [[String: Any]] ?? [],
            container["results"] as? [[String: Any]] ?? [],
        ]

        let rows = rowArrays.first(where: { !$0.isEmpty }) ?? []
        return rows.enumerated().map { index, row in
            let flattened = flattenObservabilityRow(row)
            let timestampValue = flattened["timestamp"] ?? flattened["datetime"] ?? flattened["time"]
            let timestamp = timestampValue.flatMap(parseDate)
            return DashboardObservabilityRow(
                id: flattened["$metadata.id"] ?? flattened["trace.id"] ?? flattened["span.id"] ?? "\(index)-\(flattened["timestamp"] ?? "")",
                timestamp: timestamp,
                values: flattened
            )
        }
    }

    private func parseObservabilityChartPoints(from value: Any?) -> [DashboardObservabilityChartPoint] {
        let rows: [[String: Any]]
        if let typed = value as? [[String: Any]] {
            rows = typed
        } else if let containers = value as? [[[String: Any]]] {
            rows = containers.flatMap { $0 }
        } else {
            rows = []
        }

        return rows.enumerated().compactMap { index, row in
            if let bucketPoint = parseObservabilityBucketChartPoint(row: row, index: index) {
                return bucketPoint
            }
            let flattened = flattenObservabilityRow(row)
            let date = observabilityChartDate(from: row, flattened: flattened)
            let value = observabilityChartValue(from: row, flattened: flattened)
            guard let value else {
                return nil
            }
            let label = observabilityChartLabel(from: row, flattened: flattened, fallback: date.map(chartAxisLabel) ?? "Point \(index + 1)")
            return DashboardObservabilityChartPoint(
                id: flattened["id"] ?? flattened["key"] ?? "\(index)-\(label)",
                date: date,
                label: label,
                value: value,
                segments: [DashboardObservabilityChartSegment(id: "\(index)-total", kind: .info, value: value)]
            )
        }
    }

    private func parseObservabilityBucketChartPoint(row: [String: Any], index: Int) -> DashboardObservabilityChartPoint? {
        guard let data = row["data"] as? [[String: Any]], !data.isEmpty else {
            return nil
        }

        let totalValue = data.reduce(0.0) { partial, item in
            partial + (observabilityChartValue(from: item, flattened: flattenObservabilityRow(item)) ?? 0)
        }
        let errorValue = data.reduce(0.0) { partial, item in
            partial + observabilityErrorValue(from: item)
        }
        let infoValue = max(0, totalValue - errorValue)
        let segments = [
            infoValue > 0 ? DashboardObservabilityChartSegment(id: "\(index)-info", kind: .info, value: infoValue) : nil,
            errorValue > 0 ? DashboardObservabilityChartSegment(id: "\(index)-error", kind: .error, value: errorValue) : nil,
        ].compactMap { $0 }
        guard totalValue > 0 else {
            return nil
        }

        let flattened = flattenObservabilityRow(row)
        let date = observabilityChartDate(from: row, flattened: flattened)
        let label = observabilityChartLabel(from: row, flattened: flattened, fallback: date.map(chartAxisLabel) ?? "Point \(index + 1)")
        return DashboardObservabilityChartPoint(
            id: flattened["id"] ?? flattened["time"] ?? "\(index)-\(label)",
            date: date,
            label: label,
            value: totalValue,
            segments: segments
        )
    }

    private func flattenObservabilityRow(_ row: [String: Any]) -> [String: String] {
        var flattened: [String: String] = [:]
        flattenObservabilityValue(row, prefix: nil, into: &flattened)
        return flattened
    }

    private func flattenObservabilityValue(_ value: Any, prefix: String?, into result: inout [String: String]) {
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() {
                let nextPrefix = prefix.map { "\($0).\(key)" } ?? key
                flattenObservabilityValue(dictionary[key] as Any, prefix: nextPrefix, into: &result)
            }
            return
        }

        if let array = value as? [Any] {
            if array.allSatisfy({ !($0 is [String: Any]) && !($0 is [Any]) }) {
                let scalarValues = array.compactMap(stringifyObservabilityValue)
                if !scalarValues.isEmpty, let prefix {
                    result[prefix] = scalarValues.joined(separator: ", ")
                }
                return
            }
            if let prefix,
               let data = try? JSONSerialization.data(withJSONObject: array),
               let string = String(data: data, encoding: .utf8)
            {
                result[prefix] = string
            }
            return
        }

        guard let prefix, let string = stringifyObservabilityValue(value) else {
            return
        }
        result[prefix] = string
    }

    private func stringifyObservabilityValue(_ value: Any) -> String? {
        switch value {
        case let string as String:
            return DashboardDemoMode.displayObservabilityText(string)
        case let number as NSNumber:
            return number.stringValue
        case let bool as Bool:
            return bool ? "true" : "false"
        case _ as NSNull:
            return nil
        default:
            return "\(value)"
        }
    }

    private func observabilityChartDate(from row: [String: Any], flattened: [String: String]) -> Date? {
        if let timestamp = flattened["timestamp"] ?? flattened["datetime"] ?? flattened["time"] {
            if let parsed = parseDate(timestamp) {
                return parsed
            }
            if let doubleValue = Double(timestamp), doubleValue > 1_000_000 {
                return Date(timeIntervalSince1970: doubleValue / 1000)
            }
        }

        for key in ["from", "start", "bucket", "ts"] {
            if let raw = row[key] {
                if let parsed = observabilityDateValue(raw) {
                    return parsed
                }
            }
        }
        return nil
    }

    private func observabilityChartValue(from row: [String: Any], flattened: [String: String]) -> Double? {
        for key in ["value", "count", "sum", "y"] {
            if let value = flattened[key].flatMap(Double.init) {
                return value
            }
        }

        for (key, value) in flattened where key != "timestamp" && key != "datetime" && key != "time" {
            if let parsed = Double(value) {
                return parsed
            }
        }
        return nil
    }

    private func observabilityErrorValue(from row: [String: Any]) -> Double {
        let flattened = flattenObservabilityRow(row)
        for key in ["errors", "_countErrors", "aggregates._countErrors", "errorCount"] {
            if let value = flattened[key].flatMap(Double.init) {
                return value
            }
        }
        return 0
    }

    private func observabilityChartLabel(from row: [String: Any], flattened: [String: String], fallback: String) -> String {
        for key in ["label", "name", "group", "key"] {
            if let value = flattened[key], !value.isEmpty {
                return value
            }
        }

        if let dimensions = row["dimensions"] as? [String: Any] {
            for key in dimensions.keys.sorted() {
                if let value = stringifyObservabilityValue(dimensions[key] as Any), !value.isEmpty {
                    return value
                }
            }
        }

        return fallback
    }

    private func observabilityDateValue(_ value: Any) -> Date? {
        if let string = stringifyObservabilityValue(value) {
            if let parsed = parseDate(string) {
                return parsed
            }
            if let doubleValue = Double(string), doubleValue > 1_000_000 {
                return Date(timeIntervalSince1970: doubleValue / 1000)
            }
        }
        return nil
    }

    private func chartAxisLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func makeLiveTailSocketURL(
        from result: [String: Any],
        accountID: String,
        workerName: String
    ) -> URL? {
        if let urlString = result["url"] as? String {
            return URL(string: urlString)
        }
        if let websocket = result["websocket"] as? [String: Any],
           let urlString = websocket["url"] as? String {
            return URL(string: urlString)
        }

        let userID = (result["userId"] as? String) ?? (result["user_id"] as? String)
        let key = result["key"] as? String
        let serviceID = (result["serviceId"] as? String) ?? (result["service_id"] as? String) ?? workerName
        guard let userID, let key else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "wss"
        components.host = "live-tail.observability.cloudflare.com"
        components.path = "/connect"
        components.queryItems = [
            URLQueryItem(name: "accountId", value: accountID),
            URLQueryItem(name: "userId", value: userID),
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "serviceId", value: serviceID),
        ]
        return components.url
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else {
            return nil
        }
        return DashboardDateParser.parse(value)
    }

    private func makeAvatarURL(email: String) -> String? {
        let normalized = email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else {
            return nil
        }
        let digest = Insecure.MD5.hash(data: Data(normalized.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return "https://www.gravatar.com/avatar/\(hash)?s=128&d=identicon"
    }

    private func resolveAccountID(from recentsByAccount: [String: [[String: Any]]]) throws -> String {
        if let accountID = recentsByAccount
            .compactMap({ accountID, items -> (String, Date)? in
                items
                    .filter { (($0["url"] as? String) ?? "").contains("/workers-and-pages") }
                    .compactMap { parseDate($0["timestamp"] as? String) }
                    .max()
                    .map { (accountID, $0) }
            })
            .max(by: { $0.1 < $1.1 })?.0
        {
            return accountID
        }

        if let accountID = recentsByAccount
            .compactMap({ accountID, items in
                items.map { (accountID, lastTimestamp(in: $0)) }.max(by: { $0.1 < $1.1 })
            })
            .max(by: { $0.1 < $1.1 })?.0
        {
            return accountID
        }

        throw DashboardError.missingAccountContext
    }

    private func lastTimestamp(in item: [String: Any]) -> Date {
        parseDate(item["timestamp"] as? String) ?? .distantPast
    }

    private func makePlainDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    private func workerDeploymentsURL(accountID: String, workerName: String) -> URL? {
        guard let escapedWorkerName = workerName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "https://dash.cloudflare.com/\(accountID)/workers/services/view/\(escapedWorkerName)/production/deployments")
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
            versionIDs: versionIDs,
            destinationURL: nil
        )
    }
}

private struct DashboardWorkerDeploymentRecord {
    let id: String
    let createdOn: Date?
    let versions: [DashboardWorkerDeploymentVersionRecord]
}

private struct DashboardWorkerDeploymentVersionRecord {
    let versionID: String
    let percentage: Double
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
