import ArgumentParser
import CloudflareKit
import Foundation

@main
struct CloudflareCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cloudflare",
        abstract: "Inspect Cloudflare Worker deployments and versions."
    )

    @Option(name: .long, help: "Cloudflare account ID. Falls back to CLOUDFLARE_ACCOUNT_ID.")
    var accountID: String?

    @Option(name: .long, help: "Cloudflare API token. Falls back to CLOUDFLARE_API_TOKEN.")
    var apiToken: String?

    @Option(name: .long, help: "Worker script name. Falls back to CLOUDFLARE_WORKER_NAME.")
    var worker: String?

    @Option(name: .long, help: "Output format.")
    var format: OutputFormat = .text

    @Flag(name: .long, help: "Verify that the Cloudflare API token is active.")
    var authCheck = false

    @Option(name: .long, help: "Promote a saved Worker version to the active deployment.")
    var activate: String?

    @Option(name: .long, help: "Optional deployment message for activation.")
    var message: String?

    @Flag(name: .long, help: "Send `force=true` to Cloudflare during activation.")
    var force = false

    mutating func validate() throws {
        if authCheck && activate != nil {
            throw ValidationError("Use either `--auth-check` or `--activate`.")
        }
        if message != nil && activate == nil {
            throw ValidationError("`--message` requires `--activate`.")
        }
        if force && activate == nil {
            throw ValidationError("`--force` requires `--activate`.")
        }
    }

    mutating func run() async throws {
        let environment = ProcessInfo.processInfo.environment

        guard let accountID = accountID ?? environment["CLOUDFLARE_ACCOUNT_ID"], !accountID.isEmpty else {
            throw ValidationError("Missing `--account-id` and `CLOUDFLARE_ACCOUNT_ID`.")
        }

        guard let apiToken = apiToken ?? environment["CLOUDFLARE_API_TOKEN"], !apiToken.isEmpty else {
            throw ValidationError("Missing `--api-token` and `CLOUDFLARE_API_TOKEN`.")
        }

        let client = CloudflareAPIClient(
            configuration: CloudflareAPIConfiguration(accountID: accountID, apiToken: apiToken)
        )

        if authCheck {
            let verification = try await client.verifyAPIToken()
            try renderAuthCheck(ownerType: verification.ownerType, result: verification.result)
            return
        }

        let workerName = worker ?? environment["CLOUDFLARE_WORKER_NAME"]
        guard let workerName, !workerName.isEmpty else {
            throw ValidationError("Missing `--worker` and `CLOUDFLARE_WORKER_NAME`.")
        }

        if let versionID = activate {
            let deployment = try await client.activateVersion(
                workerName: workerName,
                versionID: versionID,
                message: message,
                force: force
            )
            try renderActivation(deployment)
            return
        }

        let snapshot = try await client.getSnapshot(workerName: workerName)
        try renderSnapshot(snapshot)
    }

    private func renderAuthCheck(ownerType: TokenOwnerType, result: TokenVerificationResult) throws {
        switch format {
        case .json:
            try printJSON(AuthCheckOutput(ownerType: ownerType, result: result))
        case .text:
            print("Token type: \(ownerType.rawValue)")
            print("Token status: \(result.status)")
            print("Token ID: \(result.id)")
            if let expiresOn = result.expiresOn {
                print("Expires: \(expiresOn.ISO8601Format())")
            }
            if let notBefore = result.notBefore {
                print("Not before: \(notBefore.ISO8601Format())")
            }
        }
    }

    private func renderActivation(_ deployment: Deployment) throws {
        switch format {
        case .json:
            try printJSON(deployment)
        case .text:
            TextRenderer.printActivationResult(deployment)
        }
    }

    private func renderSnapshot(_ snapshot: WorkerDeploymentSnapshot) throws {
        switch format {
        case .json:
            try printJSON(snapshot)
        case .text:
            TextRenderer.printSnapshot(snapshot)
        }
    }
}

enum OutputFormat: String, ExpressibleByArgument {
    case text
    case json
}

private struct AuthCheckOutput: Encodable {
    let ownerType: TokenOwnerType
    let result: TokenVerificationResult
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private enum TextRenderer {
    static func printSnapshot(_ snapshot: WorkerDeploymentSnapshot) {
        print("Worker: \(snapshot.worker.scriptName)")
        print("")
        print("Active Deployment")
        printActiveDeployment(snapshot.activeDeployment)
        print("")
        print("Deployment History")
        printDeployments(snapshot.deployments)
        print("")
        print("Version History")
        printVersions(snapshot.versions)
    }

    static func printActiveDeployment(_ deployment: Deployment?) {
        guard let deployment else {
            print("No active deployment.")
            return
        }

        let versions = deployment.versions
            .map { "\($0.versionID) (\(formatPercentage($0.percentage)))" }
            .joined(separator: ", ")
        let message = deployment.annotations?.message ?? "-"
        let author = deployment.authorEmail ?? "-"

        print("ID: \(deployment.id)")
        print("Created: \(relativeString(for: deployment.createdOn))")
        print("Author: \(author)")
        print("Message: \(message)")
        print("Versions: \(versions)")
    }

    static func printDeployments(_ deployments: [Deployment]) {
        guard !deployments.isEmpty else {
            print("No deployments found.")
            return
        }

        for deployment in deployments {
            let versions = deployment.versions
                .map { "\($0.versionID) \(formatPercentage($0.percentage))" }
                .joined(separator: ", ")
            let message = deployment.annotations?.message ?? "-"
            print("\(deployment.id) | \(relativeString(for: deployment.createdOn)) | \(message) | \(versions)")
        }
    }

    static func printVersions(_ versions: [WorkerVersion]) {
        guard !versions.isEmpty else {
            print("No version history found.")
            return
        }

        for version in versions {
            let versionID = version.id ?? "-"
            let number = version.number.map(String.init) ?? "-"
            let created = version.metadata?.createdOn.map(relativeString(for:)) ?? "-"
            let author = version.metadata?.authorEmail ?? "-"
            let source = version.metadata?.source ?? "-"
            print("version | \(versionID) | #\(number) | \(created) | \(author) | \(source)")
        }
    }

    static func printActivationResult(_ deployment: Deployment) {
        let versionList = deployment.versions.map(\.versionID).joined(separator: ", ")
        print("Activated deployment \(deployment.id)")
        print("Versions: \(versionList)")
        if let message = deployment.annotations?.message {
            print("Message: \(message)")
        }
    }

    private static func relativeString(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private static func formatPercentage(_ value: Double) -> String {
        if value.rounded() == value {
            return "\(Int(value))%"
        }
        return "\(value)%"
    }
}
