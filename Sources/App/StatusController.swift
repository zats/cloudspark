import AppKit
import Foundation

@MainActor
final class StatusController: NSObject, NSMenuDelegate {
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
    private let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
    private let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")

    private var projects: [DashboardProject] = []
    private var authenticator: DashboardAuthenticator?
    private lazy var settingsController = SettingsWindowController()
    private var endpointTimers: [Endpoint: Timer] = [:]
    private var endpointTasks: [Endpoint: Task<Void, Never>] = [:]
    private weak var highlightedWorkersPagesItem: NSMenuItem?

    private var overviewProjectsByID: [String: DashboardProject] = [:]
    private var latestBuildsByID: [String: DashboardBuild] = [:]
    private var workerMetricsByID: [String: DashboardProjectMetrics] = [:]
    private var pageDeploymentsByID: [String: DashboardPageDeployment] = [:]

    private var hasLoadedOverview = false
    private var hasLoadedLatestBuilds = false
    private var hasLoadedWorkerMetrics = false
    private var hasLoadedPageDeployments = false
    private var sessions: [DashboardSession] = []
    private var sessionTask: Task<DashboardSession, Error>?
    private var didRequestStartupLogin = false

    func start() {
        sessions = (try? DashboardSessionStore.loadAll()) ?? []
        configureMenu()
        statusItem.menu = menu
        updateSummary("Idle")
        scheduleRefresh()
        if sessions.isEmpty {
            presentSettings(selectedTab: .accounts, triggerLogin: true)
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

        for item in [refreshItem, settingsItem] {
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        quitItem.target = self
        menu.addItem(quitItem)
        syncMenuState()
    }

    private func syncMenuState() {
        let hasSession = !sessions.isEmpty || !((try? DashboardSessionStore.loadAll()) ?? []).isEmpty
        workersPagesItem.isEnabled = hasSession
        refreshItem.isEnabled = hasSession
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

        guard let refreshInterval = AppPreferences.refreshInterval.timeInterval else {
            return
        }

        for endpoint in Endpoint.allCases {
            let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
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
        projects = []
        overviewProjectsByID = [:]
        latestBuildsByID = [:]
        workerMetricsByID = [:]
        pageDeploymentsByID = [:]
        hasLoadedOverview = false
        hasLoadedLatestBuilds = false
        hasLoadedWorkerMetrics = false
        hasLoadedPageDeployments = false
        highlightedWorkersPagesItem = nil
        rebuildWorkersPagesMenu()
        setStatusCount(nil)
        updateSummary(sessions.isEmpty ? "Not logged in" : "Refreshing…")
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppBundle.name
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
        if !forceLogin, sessions.isEmpty, ((try? DashboardSessionStore.loadAll()) ?? []).isEmpty {
            syncMenuState()
            updateSummary("Not logged in")
            rebuildWorkersPagesMenu()
            return
        }

        if forceLogin {
            do {
                _ = try await ensureSessions(forceLogin: true)
                syncMenuState()
                settingsController.refresh(sessions: sessions)
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
        guard endpointTasks[endpoint] == nil else {
            return
        }

        let task = Task { @MainActor in
            defer { endpointTasks[endpoint] = nil }

            do {
                let sessions = try await ensureSessions(forceLogin: false)

                switch endpoint {
                case .overview:
                    var nextOverviewProjectsByID: [String: DashboardProject] = [:]
                    for session in sessions {
                        let client = DashboardAPIClient(session: session)
                        let overviewProjects = try await client.listOverviewProjects(accountID: session.accountID ?? "")
                        for project in overviewProjects {
                            nextOverviewProjectsByID[project.id] = project
                        }
                    }
                    overviewProjectsByID = nextOverviewProjectsByID
                    hasLoadedOverview = true
                    rebuildProjectsFromSnapshots()

                    Task { @MainActor in
                        await self.refresh(endpoint: .latestBuilds, silent: true)
                    }
                    Task { @MainActor in
                        await self.refresh(endpoint: .pageDeployments, silent: true)
                    }

                case .latestBuilds:
                    let previousBuilds = latestBuildsByID
                    var nextBuilds: [String: DashboardBuild] = [:]
                    for session in sessions {
                        let externalScriptIDs = overviewProjectsByID.values
                            .filter { $0.accountID == session.accountID && $0.kind == .worker }
                            .compactMap(\.externalScriptID)
                        guard !externalScriptIDs.isEmpty else { continue }
                        let client = DashboardAPIClient(session: session)
                        let latestBuilds = try await client.listLatestBuilds(
                            accountID: session.accountID ?? "",
                            externalScriptIDs: externalScriptIDs
                        )
                        for build in latestBuilds {
                            for versionID in build.versionIDs {
                                nextBuilds["\(session.accountID ?? ""):\(versionID)"] = build
                            }
                        }
                    }
                    notifyAboutBuildChanges(from: previousBuilds, to: nextBuilds)
                    latestBuildsByID = nextBuilds
                    hasLoadedLatestBuilds = true
                    rebuildProjectsFromSnapshots()

                case .workerMetrics:
                    var nextWorkerMetricsByID: [String: DashboardProjectMetrics] = [:]
                    for session in sessions {
                        let client = DashboardAPIClient(session: session)
                        let metrics = try await client.listWorkerMetrics(accountID: session.accountID ?? "")
                        for (scriptName, metric) in metrics {
                            nextWorkerMetricsByID["\(session.accountID ?? ""):worker:\(scriptName)"] = metric
                        }
                    }
                    workerMetricsByID = nextWorkerMetricsByID
                    hasLoadedWorkerMetrics = true
                    rebuildProjectsFromSnapshots()

                case .pageDeployments:
                    var nextPageDeploymentsByID: [String: DashboardPageDeployment] = [:]
                    for session in sessions {
                        let projectNames = overviewProjectsByID.values
                            .filter { $0.accountID == session.accountID && $0.kind == .page }
                            .map(\.name)
                        guard !projectNames.isEmpty else { continue }
                        let client = DashboardAPIClient(session: session)
                        let deployments = try await client.listPageDeployments(
                            accountID: session.accountID ?? "",
                            projectNames: projectNames
                        )
                        for (projectName, deployment) in deployments {
                            nextPageDeploymentsByID["\(session.accountID ?? ""):page:\(projectName)"] = deployment
                        }
                    }
                    pageDeploymentsByID = nextPageDeploymentsByID
                    hasLoadedPageDeployments = true
                    rebuildProjectsFromSnapshots()
                }
            } catch {
                if case DashboardError.userNotLoggedIn = error {
                    updateSummary("Not logged in")
                    syncMenuState()
                    rebuildWorkersPagesMenu()
                    return
                }
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

    private func ensureSessions(forceLogin: Bool) async throws -> [DashboardSession] {
        if forceLogin {
            _ = try await ensureSession(forceLogin: true)
        }

        let storedSessions = try DashboardSessionStore.loadAll()
        guard !storedSessions.isEmpty else {
            throw DashboardError.userNotLoggedIn
        }

        var hydratedSessions: [DashboardSession] = []
        for session in storedSessions {
            hydratedSessions.append(try await hydrateSessionIfNeeded(session))
        }
        sessions = hydratedSessions.sorted { $0.capturedAt > $1.capturedAt }
        return sessions
    }

    private func ensureSession(forceLogin: Bool) async throws -> DashboardSession {
        if !forceLogin {
            let sessions = try await ensureSessions(forceLogin: false)
            guard let session = sessions.first else {
                throw DashboardError.userNotLoggedIn
            }
            return session
        }
        if let sessionTask {
            return try await sessionTask.value
        }

        let task = Task<DashboardSession, Error> { @MainActor [weak self] in
            defer { self?.sessionTask = nil }
            return try await withCheckedThrowingContinuation { continuation in
                let authenticator = DashboardAuthenticator()
                self?.authenticator = authenticator
                authenticator.present(parentWindow: self?.settingsController.hostWindow) { [weak self] result in
                    self?.authenticator = nil
                    switch result {
                    case let .success(session):
                        Task { @MainActor in
                            do {
                                let hydratedSession = try await self?.hydrateSessionIfNeeded(session) ?? session
                                self?.sessions = ((try? DashboardSessionStore.loadAll()) ?? [hydratedSession]).sorted { $0.capturedAt > $1.capturedAt }
                                continuation.resume(returning: hydratedSession)
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        }
                    case let .failure(error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        sessionTask = task
        return try await task.value
    }

    private func hydrateSessionIfNeeded(_ session: DashboardSession) async throws -> DashboardSession {
        if let accountID = session.accountID,
           !accountID.isEmpty,
           session.workerName != nil,
           session.userEmail != nil,
           session.userAvatarURL != nil
        {
            return session
        }

        let client = DashboardAPIClient(session: session)
        let context = try await client.resolveSessionContext()
        let profile = try await client.fetchCurrentUserProfile()
        let accountID = session.accountID ?? context.accountID
        var workerName = session.workerName ?? context.workerName

        if workerName == nil {
            workerName = try await client
                .listOverviewProjects(accountID: accountID)
                .first(where: { $0.kind == .worker })?.name
        }

        let hydratedSession = DashboardSession(
            capturedAt: session.capturedAt,
            xAtok: session.xAtok,
            cookies: session.cookies,
            accountID: accountID,
            workerName: workerName,
            userEmail: profile.email ?? session.userEmail,
            userDisplayName: profile.displayName ?? session.userDisplayName,
            userAvatarURL: profile.avatarURL ?? session.userAvatarURL
        )
        try DashboardSessionStore.save(hydratedSession)
        return hydratedSession
    }

    @objc
    private func openSettings() {
        presentSettings(selectedTab: .general, triggerLogin: false)
    }

    private func presentSettings(selectedTab: SettingsWindowController.Tab, triggerLogin: Bool) {
        settingsController.show(
            sessions: sessions,
            selectedTab: selectedTab,
            onLogin: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    do {
                        _ = try await self.ensureSessions(forceLogin: true)
                        self.syncMenuState()
                        self.scheduleRefresh()
                        self.settingsController.refresh(sessions: self.sessions)
                    } catch {
                        self.presentError(error)
                    }
                }
            },
            onLogout: { [weak self] targetSession in
                self?.logout(targetSession)
            },
            onSetLaunchAtLogin: { [weak self] enabled in
                do {
                    try LaunchAtLoginManager.setEnabled(enabled)
                    self?.settingsController.refresh(sessions: self?.sessions ?? [])
                } catch {
                    self?.presentError(error)
                    self?.settingsController.refresh(sessions: self?.sessions ?? [])
                }
            },
            onSetNotificationsEnabled: { [weak self] enabled in
                Task { @MainActor in
                    guard let self else { return }
                    do {
                        if enabled {
                            try await BuildNotificationManager.requestAuthorization()
                        }
                        AppPreferences.setNotificationsEnabled(enabled)
                    } catch {
                        AppPreferences.setNotificationsEnabled(false)
                        self.presentError(error)
                    }
                    self.settingsController.refresh(sessions: self.sessions)
                }
            },
            onSetRefreshInterval: { [weak self] interval in
                AppPreferences.setRefreshInterval(interval)
                self?.scheduleRefresh()
                self?.settingsController.refresh(sessions: self?.sessions ?? [])
            }
        )
        if triggerLogin, sessions.isEmpty, sessionTask == nil, !didRequestStartupLogin {
            didRequestStartupLogin = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.didRequestStartupLogin = false }
                do {
                    _ = try await self.ensureSessions(forceLogin: true)
                    self.syncMenuState()
                    self.scheduleRefresh()
                    self.settingsController.refresh(sessions: self.sessions)
                } catch {
                    if case DashboardError.userCancelledLogin = error {
                        return
                    }
                    self.presentError(error)
                }
            }
        }
    }

    private func logout(_ targetSession: DashboardSession) {
        do {
            try DashboardSessionStore.clear(storageKey: targetSession.storageKey)
            sessions.removeAll { $0.storageKey == targetSession.storageKey }
            sessionTask?.cancel()
            sessionTask = nil
            stopRefresh()
            projects = []
            overviewProjectsByID = [:]
            latestBuildsByID = [:]
            workerMetricsByID = [:]
            pageDeploymentsByID = [:]
            hasLoadedOverview = false
            hasLoadedLatestBuilds = false
            hasLoadedWorkerMetrics = false
            hasLoadedPageDeployments = false
            rebuildWorkersPagesMenu()
            settingsController.refresh(sessions: sessions)
            syncMenuState()
            setStatusCount(nil)
            updateSummary("Logged out")
            scheduleRefresh()
        } catch {
            presentError(error)
        }
    }

    @objc
    private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func rebuildProjectsFromSnapshots() {
        guard !overviewProjectsByID.isEmpty else {
            return
        }

        projects = overviewProjectsByID.values
            .map { baseProject in
                switch baseProject.kind {
                case .worker:
                    let latestBuild = baseProject.buildID.flatMap { latestBuildsByID[$0] }
                    return DashboardProject(
                        accountID: baseProject.accountID,
                        kind: .worker,
                        name: baseProject.name,
                        subtitle: latestBuild?.branch ?? baseProject.subtitle,
                        externalScriptID: baseProject.externalScriptID,
                        latestStatus: latestBuild.map(displayStatus(for:)),
                        latestBranch: latestBuild?.branch,
                        lastReleaseAt: baseProject.lastReleaseAt,
                        metrics: workerMetricsByID[baseProject.id]
                    )

                case .page:
                    let deployment = pageDeploymentsByID[baseProject.id]
                    return DashboardProject(
                        accountID: baseProject.accountID,
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
        let running = latestBuildsByID.values.filter(\.isInProgress)
        setStatusCount(running.isEmpty ? nil : running.count)

        if !running.isEmpty {
            updateSummary("\(running.count) active build(s)")
        } else if !hasLoadedOverview || !hasLoadedLatestBuilds {
            updateSummary("Refreshing…")
        } else if let preferredSession = sessions.first(where: { $0.workerName != nil }),
                  let workerName = preferredSession.workerName,
                  let selectedProject = projects.first(where: { $0.accountID == preferredSession.accountID && $0.kind == .worker && $0.name == workerName }),
                  let buildID = selectedProject.buildID,
                  let latest = latestBuildsByID[buildID] {
            let status = latest.status ?? "unknown"
            let branch = latest.branch ?? "-"
            updateSummary("Latest: \(status) (\(branch))")
        } else if projects.isEmpty {
            updateSummary("No projects found")
        } else {
            updateSummary("Monitoring \(projects.count) project(s)")
        }
    }

    private func rebuildWorkersPagesMenu() {
        workersPagesMenu.removeAllItems()
        highlightedWorkersPagesItem = nil
        if projects.isEmpty {
            let emptyItem = NSMenuItem(title: sessions.isEmpty ? "Log in from Settings" : "No workers or pages", action: nil, keyEquivalent: "")
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

    private func notifyAboutBuildChanges(
        from previousBuilds: [String: DashboardBuild],
        to nextBuilds: [String: DashboardBuild]
    ) {
        guard AppPreferences.notificationsEnabled, hasLoadedLatestBuilds else {
            return
        }

        for (externalScriptID, build) in nextBuilds {
            let previousBuild = previousBuilds[externalScriptID]
            guard shouldNotify(for: build, previous: previousBuild) else {
                continue
            }

            let projectName = overviewProjectsByID.values.first(where: { $0.buildID == externalScriptID })?.name ?? "Worker"
            let branch = build.branch ?? "main"

            if build.isInProgress {
                BuildNotificationManager.notify(title: "\(projectName) build started", body: branch)
            } else if build.isSuccessful {
                BuildNotificationManager.notify(title: "\(projectName) deployed", body: branch)
            } else if build.isFailed {
                BuildNotificationManager.notify(title: "\(projectName) build failed", body: branch)
            }
        }
    }

    private func shouldNotify(for build: DashboardBuild, previous: DashboardBuild?) -> Bool {
        guard let previous else {
            return false
        }
        if previous.id != build.id {
            return build.isInProgress || build.isSuccessful || build.isFailed
        }
        if previous.isInProgress != build.isInProgress, build.isInProgress {
            return true
        }
        if !previous.isSuccessful, build.isSuccessful {
            return true
        }
        if !previous.isFailed, build.isFailed {
            return true
        }
        return false
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
