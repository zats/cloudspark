import AppKit
import Foundation

@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    private static let refreshInterval: TimeInterval = 10

    private enum Endpoint: CaseIterable, Hashable {
        case overview
        case latestBuilds
        case workerMetrics
        case pageDeployments
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let workersPagesMenu = NSMenu()
    private let summaryItem = NSMenuItem(title: "Cloudflare", action: nil, keyEquivalent: "")
    private let workersPagesItem = NSMenuItem(title: "Workers & Pages", action: nil, keyEquivalent: "")
    private let refreshItem = NSMenuItem(title: "Refresh Data", action: #selector(refreshBuilds), keyEquivalent: "r")
    private let showBuildsItem = NSMenuItem(title: "Show Builds", action: #selector(showBuilds), keyEquivalent: "b")
    private let loginItem = NSMenuItem(title: "Login", action: #selector(login), keyEquivalent: "l")
    private let preferencesItem = NSMenuItem(title: "Preferences", action: #selector(openPreferences), keyEquivalent: ",")
    private let logoutItem = NSMenuItem(title: "Logout", action: #selector(logout), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")

    private var settings: AppSettings?
    private var builds: [DashboardBuild] = []
    private var projects: [DashboardProject] = []
    private var authenticator: DashboardAuthenticator?
    private lazy var preferencesController = PreferencesWindowController()
    private lazy var buildsController = BuildsWindowController()
    private var endpointTimers: [Endpoint: Timer] = [:]
    private var endpointTasks: [Endpoint: Task<Void, Never>] = [:]
    private weak var highlightedWorkersPagesItem: NSMenuItem?

    private var overviewProjectsByName: [String: DashboardProject] = [:]
    private var latestBuildsByExternalScriptID: [String: DashboardBuild] = [:]
    private var workerMetricsByName: [String: DashboardProjectMetrics] = [:]
    private var pageDeploymentsByName: [String: DashboardPageDeployment] = [:]

    private var hasLoadedOverview = false
    private var hasLoadedLatestBuilds = false
    private var hasLoadedWorkerMetrics = false
    private var hasLoadedPageDeployments = false

    func start() {
        settings = AppSettingsStore.load()
        configureMenu()
        statusItem.menu = menu
        updateSummary("Idle")

        if settings == nil {
            openPreferences()
        } else {
            scheduleRefresh()
        }
    }

    private func configureMenu() {
        statusItem.button?.title = "CF"

        summaryItem.isEnabled = false
        menu.addItem(summaryItem)
        menu.addItem(NSMenuItem.separator())

        workersPagesItem.submenu = workersPagesMenu
        workersPagesMenu.delegate = self
        menu.addItem(workersPagesItem)

        for item in [refreshItem, showBuildsItem, loginItem, preferencesItem, logoutItem] {
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        quitItem.target = self
        menu.addItem(quitItem)
        syncMenuState()
    }

    private func syncMenuState() {
        let hasSettings = settings != nil
        workersPagesItem.isEnabled = hasSettings
        refreshItem.isEnabled = hasSettings
        showBuildsItem.isEnabled = hasSettings
        logoutItem.isEnabled = (try? DashboardSessionStore.load()) != nil
    }

    private func updateSummary(_ text: String) {
        summaryItem.title = text
    }

    private func setStatusCount(_ count: Int?) {
        statusItem.button?.title = count.map { "CF \($0)" } ?? "CF"
    }

    private func scheduleRefresh() {
        stopRefresh()
        resetRefreshState()

        for endpoint in Endpoint.allCases {
            let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.refresh(endpoint: endpoint, silent: true)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            endpointTimers[endpoint] = timer
        }

        Task { @MainActor in
            await refreshAllEndpoints(silent: true)
        }
    }

    private func stopRefresh() {
        endpointTimers.values.forEach { $0.invalidate() }
        endpointTimers.removeAll()
        endpointTasks.values.forEach { $0.cancel() }
        endpointTasks.removeAll()
    }

    private func resetRefreshState() {
        builds = []
        projects = []
        overviewProjectsByName = [:]
        latestBuildsByExternalScriptID = [:]
        workerMetricsByName = [:]
        pageDeploymentsByName = [:]
        hasLoadedOverview = false
        hasLoadedLatestBuilds = false
        hasLoadedWorkerMetrics = false
        hasLoadedPageDeployments = false
        highlightedWorkersPagesItem = nil
        buildsController.update(workerName: settings?.workerName ?? "-", builds: [])
        rebuildWorkersPagesMenu()
        setStatusCount(nil)
        updateSummary("Refreshing…")
    }

    private func requireSettings() -> AppSettings? {
        if let settings {
            return settings
        }
        openPreferences()
        return nil
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Cloudflare2"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    @objc
    private func refreshBuilds() {
        Task { @MainActor in
            await refreshAllEndpoints(silent: false)
        }
    }

    private func refreshAllEndpoints(forceLogin: Bool = false, silent: Bool) async {
        guard let settings = requireSettings() else {
            return
        }

        if forceLogin {
            do {
                _ = try await ensureSession(accountID: settings.accountID, forceLogin: true)
                syncMenuState()
            } catch {
                if !silent {
                    presentError(error)
                }
                return
            }
        }

        for endpoint in Endpoint.allCases {
            Task { @MainActor in
                await self.refresh(endpoint: endpoint, silent: silent)
            }
        }
    }

    private func refresh(endpoint: Endpoint, silent: Bool) async {
        guard let settings = requireSettings() else {
            return
        }
        guard endpointTasks[endpoint] == nil else {
            return
        }

        let task = Task { @MainActor in
            defer { endpointTasks[endpoint] = nil }

            do {
                let session = try await ensureSession(accountID: settings.accountID, forceLogin: false)
                let client = DashboardAPIClient(session: session)

                switch endpoint {
                case .overview:
                    let overviewProjects = try await client.listOverviewProjects(accountID: settings.accountID)
                    overviewProjectsByName = Dictionary(uniqueKeysWithValues: overviewProjects.map { ($0.name, $0) })
                    hasLoadedOverview = true
                    rebuildProjectsFromSnapshots()

                    Task { @MainActor in
                        await self.refresh(endpoint: .latestBuilds, silent: true)
                    }
                    Task { @MainActor in
                        await self.refresh(endpoint: .pageDeployments, silent: true)
                    }

                case .latestBuilds:
                    let externalScriptIDs = overviewProjectsByName.values
                        .filter { $0.kind == .worker }
                        .compactMap(\.externalScriptID)
                    if externalScriptIDs.isEmpty {
                        latestBuildsByExternalScriptID = [:]
                        hasLoadedLatestBuilds = true
                        rebuildProjectsFromSnapshots()
                        return
                    }

                    let latestBuilds = try await client.listLatestBuilds(
                        accountID: settings.accountID,
                        externalScriptIDs: externalScriptIDs
                    )
                    latestBuildsByExternalScriptID = Dictionary(
                        uniqueKeysWithValues: latestBuilds.compactMap { build in
                            build.versionIDs.first.map { ($0, build) }
                        }
                    )
                    hasLoadedLatestBuilds = true
                    rebuildProjectsFromSnapshots()

                case .workerMetrics:
                    workerMetricsByName = try await client.listWorkerMetrics(accountID: settings.accountID)
                    hasLoadedWorkerMetrics = true
                    rebuildProjectsFromSnapshots()

                case .pageDeployments:
                    let projectNames = overviewProjectsByName.values
                        .filter { $0.kind == .page }
                        .map(\.name)
                    if projectNames.isEmpty {
                        pageDeploymentsByName = [:]
                        hasLoadedPageDeployments = true
                        rebuildProjectsFromSnapshots()
                        return
                    }

                    pageDeploymentsByName = try await client.listPageDeployments(
                        accountID: settings.accountID,
                        projectNames: projectNames
                    )
                    hasLoadedPageDeployments = true
                    rebuildProjectsFromSnapshots()
                }
            } catch {
                if !silent {
                    presentError(error)
                }
                if endpoint == .overview, !hasLoadedOverview {
                    updateSummary("Refresh failed")
                }
            }

            syncMenuState()
        }

        endpointTasks[endpoint] = task
        await task.value
    }

    private func ensureSession(accountID: String, forceLogin: Bool) async throws -> DashboardSession {
        if !forceLogin, let session = try DashboardSessionStore.load() {
            return session
        }
        return try await withCheckedThrowingContinuation { continuation in
            let authenticator = DashboardAuthenticator()
            self.authenticator = authenticator
            authenticator.present(accountID: accountID) { [weak self] result in
                self?.authenticator = nil
                continuation.resume(with: result)
            }
        }
    }

    @objc
    private func showBuilds() {
        guard let settings = requireSettings() else {
            return
        }
        buildsController.show(workerName: settings.workerName, builds: builds)
    }

    @objc
    private func login() {
        Task { @MainActor in
            await refreshAllEndpoints(forceLogin: true, silent: false)
        }
    }

    @objc
    private func openPreferences() {
        preferencesController.show(current: settings) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(settings):
                self.settings = settings
                do {
                    try AppSettingsStore.save(settings)
                    self.syncMenuState()
                    self.scheduleRefresh()
                } catch {
                    self.presentError(error)
                }
            case let .failure(error):
                self.presentError(error)
            }
        }
    }

    @objc
    private func logout() {
        do {
            try DashboardSessionStore.clear()
            stopRefresh()
            builds = []
            projects = []
            overviewProjectsByName = [:]
            latestBuildsByExternalScriptID = [:]
            workerMetricsByName = [:]
            pageDeploymentsByName = [:]
            hasLoadedOverview = false
            hasLoadedLatestBuilds = false
            hasLoadedWorkerMetrics = false
            hasLoadedPageDeployments = false
            buildsController.update(workerName: settings?.workerName ?? "-", builds: [])
            rebuildWorkersPagesMenu()
            syncMenuState()
            setStatusCount(nil)
            updateSummary("Logged out")
        } catch {
            presentError(error)
        }
    }

    @objc
    private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func rebuildProjectsFromSnapshots() {
        guard !overviewProjectsByName.isEmpty else {
            return
        }

        projects = overviewProjectsByName.values
            .map { baseProject in
                switch baseProject.kind {
                case .worker:
                    let latestBuild = baseProject.externalScriptID.flatMap { latestBuildsByExternalScriptID[$0] }
                    return DashboardProject(
                        kind: .worker,
                        name: baseProject.name,
                        subtitle: latestBuild?.branch ?? baseProject.subtitle,
                        externalScriptID: baseProject.externalScriptID,
                        latestStatus: latestBuild.map(displayStatus(for:)),
                        latestBranch: latestBuild?.branch,
                        lastReleaseAt: baseProject.lastReleaseAt,
                        metrics: workerMetricsByName[baseProject.name]
                    )

                case .page:
                    let deployment = pageDeploymentsByName[baseProject.name]
                    return DashboardProject(
                        kind: .page,
                        name: baseProject.name,
                        subtitle: baseProject.subtitle,
                        externalScriptID: nil,
                        latestStatus: deployment?.latestStatus ?? baseProject.latestStatus,
                        latestBranch: deployment?.latestBranch ?? baseProject.latestBranch,
                        lastReleaseAt: deployment?.lastReleaseAt ?? baseProject.lastReleaseAt,
                        metrics: nil
                    )
                }
            }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

        rebuildWorkersPagesMenu()
        updateBuildSelectionAndSummary()
    }

    private func updateBuildSelectionAndSummary() {
        if let settings,
           let selectedProject = projects.first(where: { $0.kind == .worker && $0.name == settings.workerName }),
           let externalScriptID = selectedProject.externalScriptID,
           let build = latestBuildsByExternalScriptID[externalScriptID] {
            builds = [build]
        } else {
            builds = []
        }

        buildsController.update(workerName: settings?.workerName ?? "-", builds: builds)

        let running = latestBuildsByExternalScriptID.values.filter(\.isInProgress)
        setStatusCount(running.isEmpty ? nil : running.count)

        if !running.isEmpty {
            updateSummary("\(running.count) active build(s)")
        } else if !hasLoadedOverview || !hasLoadedLatestBuilds {
            updateSummary("Refreshing…")
        } else if let latest = builds.first {
            let status = latest.status ?? "unknown"
            let branch = latest.branch ?? "-"
            updateSummary("Latest: \(status) (\(branch))")
        } else if projects.isEmpty {
            updateSummary("No projects found")
        } else {
            updateSummary("No builds found")
        }
    }

    private func rebuildWorkersPagesMenu() {
        workersPagesMenu.removeAllItems()
        highlightedWorkersPagesItem = nil
        if projects.isEmpty {
            let emptyItem = NSMenuItem(title: "No workers or pages", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            workersPagesMenu.addItem(emptyItem)
            return
        }

        for project in projects {
            let item = NSMenuItem(title: project.name, action: nil, keyEquivalent: "")
            item.view = WorkersPagesMenuItemView(project: project)
            workersPagesMenu.addItem(item)
        }
    }

    private func displayStatus(for build: DashboardBuild) -> String {
        if build.isInProgress {
            return build.status?.lowercased() ?? "running"
        }
        if let outcome = build.buildOutcome?.lowercased(), !outcome.isEmpty {
            return outcome
        }
        return build.status?.lowercased() ?? "unknown"
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard menu === workersPagesMenu else {
            return
        }
        if highlightedWorkersPagesItem === item {
            return
        }
        (highlightedWorkersPagesItem?.view as? WorkersPagesMenuItemView)?.refreshHighlight(isHighlighted: false)
        (item?.view as? WorkersPagesMenuItemView)?.refreshHighlight(isHighlighted: true)
        highlightedWorkersPagesItem = item
    }
}
