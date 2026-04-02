import Foundation

public struct CloudflareAPIConfiguration: Sendable {
    public let accountID: String
    public let apiToken: String
    public let baseURL: URL

    public init(accountID: String, apiToken: String, baseURL: URL = CloudflareKit.apiBaseURL) {
        self.accountID = accountID
        self.apiToken = apiToken
        self.baseURL = baseURL
    }
}

public enum CloudflareAPIError: Error, LocalizedError, Equatable {
    case invalidResponse
    case invalidToken
    case workerNotFound(String)
    case duplicateWorkerName(String)
    case requestFailed(statusCode: Int, message: String)
    case apiErrors([String])

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Cloudflare returned an invalid response."
        case .invalidToken:
            return "Cloudflare rejected the API token. Create a new token, verify it is active, and ensure the token can access the target account."
        case let .workerNotFound(worker):
            return "Worker '\(worker)' was not found."
        case let .duplicateWorkerName(worker):
            return "Multiple Workers matched '\(worker)'. Use an exact script name."
        case let .requestFailed(statusCode, message):
            return "Cloudflare API request failed with status \(statusCode): \(message)"
        case let .apiErrors(errors):
            return errors.joined(separator: "\n")
        }
    }
}

public final class CloudflareAPIClient: @unchecked Sendable {
    private let configuration: CloudflareAPIConfiguration
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(configuration: CloudflareAPIConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
        self.decoder = JSONDecoder.cloudflare
        self.encoder = JSONEncoder.cloudflare
    }

    public func listWorkers() async throws -> [WorkerScript] {
        try await send("/accounts/\(configuration.accountID)/workers/scripts", method: "GET", expecting: [WorkerScript].self)
    }

    public func verifyUserAPIToken() async throws -> TokenVerificationResult {
        try await send("/user/tokens/verify", method: "GET", expecting: TokenVerificationResult.self)
    }

    public func verifyAccountAPIToken() async throws -> TokenVerificationResult {
        try await send("/accounts/\(configuration.accountID)/tokens/verify", method: "GET", expecting: TokenVerificationResult.self)
    }

    public func verifyAPIToken() async throws -> (ownerType: TokenOwnerType, result: TokenVerificationResult) {
        if let result = try? await verifyAccountAPIToken() {
            return (.account, result)
        }
        let result = try await verifyUserAPIToken()
        return (.user, result)
    }

    public func resolveWorkerIdentity(named workerName: String) async throws -> WorkerIdentity {
        let workers = try await listWorkers()
        let exactMatches = workers.filter { $0.id == workerName }

        guard !exactMatches.isEmpty else {
            throw CloudflareAPIError.workerNotFound(workerName)
        }

        guard exactMatches.count == 1 else {
            throw CloudflareAPIError.duplicateWorkerName(workerName)
        }

        return exactMatches[0].identity ?? WorkerIdentity(scriptName: workerName)
    }

    public func listDeployments(workerName: String) async throws -> [Deployment] {
        let result = try await send(
            "/accounts/\(configuration.accountID)/workers/scripts/\(workerName)/deployments",
            method: "GET",
            expecting: DeploymentListResult.self
        )
        return result.deployments
    }

    public func listVersions(
        workerName: String,
        deployableOnly: Bool = false,
        page: Int? = nil,
        perPage: Int? = nil
    ) async throws -> [WorkerVersion] {
        var queryItems: [URLQueryItem] = []
        if deployableOnly {
            queryItems.append(URLQueryItem(name: "deployable", value: "true"))
        }
        if let page {
            queryItems.append(URLQueryItem(name: "page", value: String(page)))
        }
        if let perPage {
            queryItems.append(URLQueryItem(name: "per_page", value: String(perPage)))
        }

        let result = try await send(
            "/accounts/\(configuration.accountID)/workers/scripts/\(workerName)/versions",
            method: "GET",
            queryItems: queryItems,
            expecting: VersionListResult.self
        )
        return result.items
    }

    public func getSnapshot(workerName: String) async throws -> WorkerDeploymentSnapshot {
        let worker = try await resolveWorkerIdentity(named: workerName)

        async let deploymentsTask = listDeployments(workerName: worker.scriptName)
        async let versionsTask = listVersions(workerName: worker.scriptName)

        let deployments = try await deploymentsTask
        let versions = try await versionsTask

        return WorkerDeploymentSnapshot(
            worker: worker,
            activeDeployment: deployments.first,
            deployments: deployments,
            versions: versions
        )
    }

    public func activateVersion(
        workerName: String,
        versionID: String,
        message: String? = nil,
        force: Bool = false,
        triggeredBy: String = "rollback"
    ) async throws -> Deployment {
        var queryItems: [URLQueryItem] = []
        if force {
            queryItems.append(URLQueryItem(name: "force", value: "true"))
        }

        let body = ActivationRequestBody(
            versions: [DeploymentVersionTraffic(percentage: 100, versionID: versionID)],
            annotations: DeploymentAnnotations(message: message, triggeredBy: triggeredBy)
        )

        return try await send(
            "/accounts/\(configuration.accountID)/workers/scripts/\(workerName)/deployments",
            method: "POST",
            queryItems: queryItems,
            body: body,
            expecting: Deployment.self
        )
    }

    private func send<Result: Decodable, Body: Encodable>(
        _ path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        body: Body? = nil,
        expecting type: Result.Type
    ) async throws -> Result {
        let data = try await sendData(path, method: method, queryItems: queryItems, body: body)
        let envelope = try decoder.decode(CloudflareEnvelope<Result>.self, from: data)
        guard envelope.success else {
            throw CloudflareAPIError.apiErrors((envelope.errors ?? []).map(\.message))
        }
        return envelope.result
    }

    private func send<Result: Decodable>(
        _ path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        expecting type: Result.Type
    ) async throws -> Result {
        let data = try await sendData(path, method: method, queryItems: queryItems)
        let envelope = try decoder.decode(CloudflareEnvelope<Result>.self, from: data)
        guard envelope.success else {
            throw CloudflareAPIError.apiErrors((envelope.errors ?? []).map(\.message))
        }
        return envelope.result
    }

    private func sendData<Body: Encodable>(
        _ path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        body: Body? = nil
    ) async throws -> Data {
        var components = URLComponents(url: configuration.baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }

        guard let url = components?.url else {
            throw CloudflareAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(configuration.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudflareAPIError.invalidResponse
        }

        guard 200 ..< 300 ~= httpResponse.statusCode else {
            if let envelope = try? decoder.decode(CloudflareEnvelope<EmptyPayload>.self, from: data),
               let firstError = envelope.errors?.first {
                if httpResponse.statusCode == 401,
                   firstError.message.localizedCaseInsensitiveContains("invalid token") {
                    throw CloudflareAPIError.invalidToken
                }
                throw CloudflareAPIError.requestFailed(statusCode: httpResponse.statusCode, message: firstError.message)
            }

            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            if httpResponse.statusCode == 401,
               message.localizedCaseInsensitiveContains("invalid token") {
                throw CloudflareAPIError.invalidToken
            }
            throw CloudflareAPIError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }

        return data
    }

    private func sendData(
        _ path: String,
        method: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> Data {
        try await sendData(path, method: method, queryItems: queryItems, body: Optional<String>.none)
    }

    private struct EmptyPayload: Codable {}
}

private extension JSONDecoder {
    static let cloudflare: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)

            if let date = makeISO8601Formatter(fractionalSeconds: true).date(from: string) {
                return date
            }
            if let date = makeISO8601Formatter(fractionalSeconds: false).date(from: string) {
                return date
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported date: \(string)")
        }
        return decoder
    }()
}

private extension JSONEncoder {
    static let cloudflare: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

private func makeISO8601Formatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = fractionalSeconds
        ? [.withInternetDateTime, .withFractionalSeconds]
        : [.withInternetDateTime]
    return formatter
}
