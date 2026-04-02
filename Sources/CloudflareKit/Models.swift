import Foundation

public struct WorkerIdentity: Codable, Equatable, Sendable {
    public let scriptName: String

    public init(scriptName: String) {
        self.scriptName = scriptName
    }
}

public struct WorkerScript: Codable, Equatable, Sendable {
    public let id: String
    public let tag: String?

    public var identity: WorkerIdentity? {
        WorkerIdentity(scriptName: id)
    }
}

public struct DeploymentVersionTraffic: Codable, Equatable, Sendable {
    public let percentage: Double
    public let versionID: String

    enum CodingKeys: String, CodingKey {
        case percentage
        case versionID = "version_id"
    }
}

public struct DeploymentAnnotations: Codable, Equatable, Sendable {
    public let message: String?
    public let triggeredBy: String?

    enum CodingKeys: String, CodingKey {
        case message = "workers/message"
        case triggeredBy = "workers/triggered_by"
    }

    public init(message: String? = nil, triggeredBy: String? = nil) {
        self.message = message
        self.triggeredBy = triggeredBy
    }
}

public struct Deployment: Codable, Equatable, Sendable {
    public let id: String
    public let createdOn: Date
    public let source: String?
    public let strategy: String?
    public let versions: [DeploymentVersionTraffic]
    public let annotations: DeploymentAnnotations?
    public let authorEmail: String?

    enum CodingKeys: String, CodingKey {
        case id
        case createdOn = "created_on"
        case source
        case strategy
        case versions
        case annotations
        case authorEmail = "author_email"
    }
}

public struct VersionMetadata: Codable, Equatable, Sendable {
    public let authorEmail: String?
    public let authorID: String?
    public let createdOn: Date?
    public let hasPreview: Bool?
    public let modifiedOn: Date?
    public let source: String?

    enum CodingKeys: String, CodingKey {
        case authorEmail = "author_email"
        case authorID = "author_id"
        case createdOn = "created_on"
        case hasPreview = "has_preview"
        case modifiedOn = "modified_on"
        case source
    }
}

public struct WorkerVersion: Codable, Equatable, Sendable {
    public let id: String?
    public let metadata: VersionMetadata?
    public let number: Int?

    public init(id: String?, metadata: VersionMetadata?, number: Int?) {
        self.id = id
        self.metadata = metadata
        self.number = number
    }
}

public struct WorkerDeploymentSnapshot: Encodable, Equatable, Sendable {
    public let worker: WorkerIdentity
    public let activeDeployment: Deployment?
    public let deployments: [Deployment]
    public let versions: [WorkerVersion]

    public init(
        worker: WorkerIdentity,
        activeDeployment: Deployment?,
        deployments: [Deployment],
        versions: [WorkerVersion]
    ) {
        self.worker = worker
        self.activeDeployment = activeDeployment
        self.deployments = deployments
        self.versions = versions
    }
}

struct CloudflareEnvelope<Result: Decodable>: Decodable {
    let result: Result
    let success: Bool
    let errors: [CloudflareAPIMessage]?
    let messages: [CloudflareAPIMessage]?
}

struct CloudflareAPIMessage: Codable, Error, Equatable {
    let code: Int
    let message: String
}

struct DeploymentListResult: Codable {
    let deployments: [Deployment]
}

struct VersionListResult: Codable {
    let items: [WorkerVersion]
}

struct ActivationRequestBody: Encodable {
    let strategy: String = "percentage"
    let versions: [DeploymentVersionTraffic]
    let annotations: DeploymentAnnotations?
}

public struct TokenVerificationResult: Codable, Equatable, Sendable {
    public let id: String
    public let status: String
    public let expiresOn: Date?
    public let notBefore: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case expiresOn = "expires_on"
        case notBefore = "not_before"
    }
}

public enum TokenOwnerType: String, Codable, Equatable, Sendable {
    case user
    case account
}
