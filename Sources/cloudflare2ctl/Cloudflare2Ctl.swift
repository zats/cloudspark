import ArgumentParser
import Foundation

@main
struct Cloudflare2Ctl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cloudflare2ctl",
        abstract: "Inspect Cloudflare2 app state and call dashboard build endpoints.",
        subcommands: [
            Session.self,
            Settings.self,
            Latest.self,
            ByVersion.self,
            ClearSession.self,
        ]
    )
}

struct Session: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show whether the app has a stored dashboard session."
    )

    @Flag(name: .long, help: "Output JSON.")
    var json = false

    func run() throws {
        let session = try DashboardSessionStore.load()
        if json {
            try printJSON(SessionOutput(session: session))
            return
        }

        guard let session else {
            print("No stored session.")
            return
        }

        print("Captured: \(session.capturedAt.ISO8601Format())")
        print("Cookies: \(session.cookies.count)")
        print("x-atok: present")
    }
}

struct Settings: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the app's saved account/worker settings."
    )

    @Flag(name: .long, help: "Output JSON.")
    var json = false

    func run() throws {
        let settings = AppSettingsStore.load()
        if json {
            try printJSON(settings)
            return
        }

        guard let settings else {
            print("No saved settings.")
            return
        }

        print("Account ID: \(settings.accountID)")
        print("Worker: \(settings.workerName)")
    }
}

struct Latest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Call the dashboard latest-builds endpoint."
    )

    @Option(name: .long, help: "Cloudflare account ID.")
    var accountID: String

    @Option(name: .long, parsing: .upToNextOption, help: "External script IDs.")
    var externalScriptID: [String]

    @Flag(name: .long, help: "Output JSON.")
    var json = false

    func run() async throws {
        let session = try requireSession()
        let client = DashboardAPIClient(session: session)
        let builds = try await client.listLatestBuilds(
            accountID: accountID,
            externalScriptIDs: externalScriptID
        )

        if json {
            try printJSON(builds)
            return
        }

        printBuilds(builds)
    }
}

struct ByVersion: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "builds",
        abstract: "Call the dashboard builds endpoint with version IDs."
    )

    @Option(name: .long, help: "Cloudflare account ID.")
    var accountID: String

    @Option(name: .long, parsing: .upToNextOption, help: "Version IDs.")
    var versionID: [String]

    @Flag(name: .long, help: "Output JSON.")
    var json = false

    func run() async throws {
        let session = try requireSession()
        let client = DashboardAPIClient(session: session)
        let builds = try await client.listBuilds(accountID: accountID, versionIDs: versionID)

        if json {
            try printJSON(builds)
            return
        }

        printBuilds(builds)
    }
}

struct ClearSession: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete the stored dashboard session."
    )

    func run() throws {
        try DashboardSessionStore.clear()
        print("Cleared stored session.")
    }
}

private struct SessionOutput: Encodable {
    let hasSession: Bool
    let capturedAt: Date?
    let cookieCount: Int?
    let hasAtok: Bool

    init(session: DashboardSession?) {
        hasSession = session != nil
        capturedAt = session?.capturedAt
        cookieCount = session?.cookies.count
        hasAtok = session?.xAtok.isEmpty == false
    }
}

struct CLIError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private func requireSession() throws -> DashboardSession {
    guard let session = try DashboardSessionStore.load() else {
        throw ValidationError("No stored session. Log in with the Cloudflare2 app first.")
    }
    return session
}

private func printBuilds(_ builds: [DashboardBuild]) {
    if builds.isEmpty {
        print("No builds found.")
        return
    }

    for build in builds {
        let status = build.status ?? "-"
        let branch = build.branch ?? "-"
        let created = build.createdOn ?? "-"
        let versions = build.versionIDs.isEmpty ? "-" : build.versionIDs.joined(separator: ",")
        print("\(build.id) | \(status) | \(branch) | \(created) | \(versions)")
    }
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
