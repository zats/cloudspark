import AppKit
import Foundation

@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    private static let inProgressStatusImageName = NSImage.Name("BuildInProgress")

    private enum Endpoint: CaseIterable, Hashable {
        case overview
        case latestBuilds
        case workerMetrics
        case pageDeployments
    }

    private struct RecentBuildChange {
        let id: String
        let project: DashboardProject
        let projectName: String
        let status: String
        let statusKind: DashboardStatusKind
        let symbolName: String
        let changedAt: Date
        let isInProgress: Bool
    }

    private struct RecentBuildMenuEntry: Equatable {
        let id: String
        let project: DashboardProject
        let isInProgress: Bool
        let changedAt: Date?
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let workersPagesMenu = NSMenu()
    private let summaryItem = NSMenuItem(title: "Cloudflare", action: nil, keyEquivalent: "")
    private let summarySectionSeparatorItem = NSMenuItem.separator()
    private let workersPagesItem = NSMenuItem(title: "Workers", action: nil, keyEquivalent: "")
    private let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshBuilds), keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
    private let checkForUpdatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "")
    private let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let plainDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private var projects: [DashboardProject] = []
    private var authenticator: DashboardAuthenticator?
    private lazy var settingsController = SettingsWindowController()
    private var endpointTimers: [Endpoint: Timer] = [:]
    private var endpointTasks: [Endpoint: Task<Void, Never>] = [:]
    private var summaryTimer: Timer?
    private var overviewProjectsByID: [String: DashboardProject] = [:]
    private var latestBuildsByID: [String: DashboardBuild] = [:]
    private var workerMetricsByID: [String: DashboardProjectMetrics] = [:]
    private var pageDeploymentsByID: [String: DashboardPageDeployment] = [:]

    private var hasLoadedOverview = false
    private var hasLoadedLatestBuilds = false
    private var hasLoadedWorkerMetrics = false
    private var hasLoadedPageDeployments = false
    private var lastRefreshedAt: Date?
    private var sessions: [DashboardSession] = []
    private var sessionTask: Task<DashboardSession, Error>?
    private var didRequestStartupLogin = false
    private var recentBuildChangesByKey: [String: RecentBuildChange] = [:]
    private var recentBuildMenuItems: [NSMenuItem] = []
    private var favoriteProjectIDs = AppPreferences.favoriteProjectIDs
    private let updateController: UpdateControlling

    init(updateController: UpdateControlling) {
        self.updateController = updateController
        super.init()
    }

    func start() {
        sessions = (try? DashboardSessionStore.loadAll()) ?? []
        configureMenu()
        statusItem.menu = menu
        updateSummary("Idle")
        startSummaryTimer()
        scheduleRefresh()
        if sessions.isEmpty {
            presentSettings(selectedTab: .accounts, triggerLogin: true)
        }
    }

    private func configureMenu() {
        statusItem.button?.image = NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: AppBundle.name)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = nil

        summaryItem.isEnabled = false
        menu.addItem(summaryItem)
        menu.addItem(summarySectionSeparatorItem)
        menu.delegate = self

        workersPagesItem.submenu = workersPagesMenu
        workersPagesMenu.delegate = self
        menu.addItem(workersPagesItem)

        for item in [refreshItem, checkForUpdatesItem, settingsItem] {
            item.target = self
            menu.addItem(item)
        }

        checkForUpdatesItem.isEnabled = updateController.isAvailable

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
        rebuildRecentBuildsMenu()
    }

    private func updateStatusIcon() {
        let referenceDate = Date()
        let activeRecentChanges = activeRecentBuildChanges(referenceDate: referenceDate)
        statusItem.button?.image = statusIconImage(
            activeRecentChanges: activeRecentChanges,
            hasInProgressBuild: hasInProgressStatuses()
        )
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.title = ""
        statusItem.button?.toolTip = statusTooltip(activeRecentChanges: activeRecentChanges)
    }

    private func statusIconImage(
        activeRecentChanges: [RecentBuildChange],
        hasInProgressBuild: Bool
    ) -> NSImage? {
        let symbolName: String

        if activeRecentChanges.contains(where: { $0.statusKind == .failure }) {
            symbolName = "exclamationmark.icloud.fill"
        } else if hasInProgressBuild {
            symbolName = Self.inProgressStatusImageName
        } else if let latestChange = activeRecentChanges.first {
            symbolName = latestChange.symbolName
        } else {
            symbolName = "icloud.fill"
        }

        if symbolName == Self.inProgressStatusImageName {
            let image = NSImage(named: Self.inProgressStatusImageName)!
            image.isTemplate = true
            return image
        }
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: AppBundle.name)
    }

    private func statusTooltip(activeRecentChanges: [RecentBuildChange]) -> String? {
        guard !activeRecentChanges.isEmpty else {
            return nil
        }
        return activeRecentChanges
            .map { "\($0.project.displayName): \($0.status)" }
            .joined(separator: "\n")
    }

    private func activeRecentBuildChanges(referenceDate: Date = Date()) -> [RecentBuildChange] {
        pruneRecentBuildChanges(referenceDate: referenceDate)
        return recentBuildChangesByKey.values.sorted { lhs, rhs in
            lhs.changedAt > rhs.changedAt
        }
    }

    private func pruneRecentBuildChanges(referenceDate: Date) {
        recentBuildChangesByKey = recentBuildChangesByKey.filter { _, change in
            referenceDate.timeIntervalSince(change.changedAt) <= recentBuildChangeWindow
        }
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

    private func startSummaryTimer() {
        summaryTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateBuildSelectionAndSummary()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        summaryTimer = timer
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
        lastRefreshedAt = nil
        recentBuildChangesByKey = [:]
        rebuildWorkersPagesMenu()
        updateStatusIcon()
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

    @objc
    private func checkForUpdates() {
        updateController.checkForUpdates(nil)
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
                if case DashboardError.userCancelledLogin = error {
                    return
                }
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
                    lastRefreshedAt = Date()
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
                    recordBuildChanges(from: previousBuilds, to: nextBuilds)
                    notifyAboutBuildChanges(from: previousBuilds, to: nextBuilds)
                    latestBuildsByID = nextBuilds
                    hasLoadedLatestBuilds = true
                    lastRefreshedAt = Date()
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
                    lastRefreshedAt = Date()
                    rebuildProjectsFromSnapshots()

                case .pageDeployments:
                    let previousDeployments = pageDeploymentsByID
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
                    recordPageDeploymentChanges(from: previousDeployments, to: nextPageDeploymentsByID)
                    notifyAboutPageDeploymentChanges(from: previousDeployments, to: nextPageDeploymentsByID)
                    pageDeploymentsByID = nextPageDeploymentsByID
                    hasLoadedPageDeployments = true
                    lastRefreshedAt = Date()
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
                        if case DashboardError.userCancelledLogin = error {
                            return
                        }
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
            recentBuildChangesByKey = [:]
            rebuildWorkersPagesMenu()
            settingsController.refresh(sessions: sessions)
            syncMenuState()
            updateStatusIcon()
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

        let shouldShowAccountEmail = Set(
            overviewProjectsByID.values
                .filter { $0.kind == .worker }
                .map(\.accountID)
        ).count > 1

        projects = overviewProjectsByID.values
            .map { baseProject in
                switch baseProject.kind {
                case .worker:
                    let latestBuild = baseProject.buildID.flatMap { latestBuildsByID[$0] }
                    return DashboardProject(
                        accountID: baseProject.accountID,
                        accountEmail: shouldShowAccountEmail ? accountEmail(for: baseProject.accountID) : nil,
                        kind: .worker,
                        name: baseProject.name,
                        subtitle: latestBuild?.branch ?? baseProject.subtitle,
                        externalScriptID: baseProject.externalScriptID,
                        latestStatus: latestBuild.map(displayStatus(for:)),
                        latestBranch: latestBuild?.branch,
                        lastReleaseAt: baseProject.lastReleaseAt,
                        metrics: workerMetricsByID[baseProject.id],
                        destinationURL: latestBuild.flatMap {
                            workerBuildURL(accountID: baseProject.accountID, workerName: baseProject.name, buildID: $0.id)
                        }
                    )

                case .page:
                    let deployment = pageDeploymentsByID[baseProject.id]
                    return DashboardProject(
                        accountID: baseProject.accountID,
                        accountEmail: shouldShowAccountEmail ? accountEmail(for: baseProject.accountID) : nil,
                        kind: .page,
                        name: baseProject.name,
                        subtitle: baseProject.subtitle,
                        externalScriptID: nil,
                        latestStatus: deployment?.latestStatus ?? baseProject.latestStatus,
                        latestBranch: deployment?.latestBranch ?? baseProject.latestBranch,
                        lastReleaseAt: deployment?.lastReleaseAt ?? baseProject.lastReleaseAt,
                        metrics: nil,
                        destinationURL: nil
                    )
                }
            }
            .sorted {
                if isFavorite($0) != isFavorite($1) {
                    return isFavorite($0)
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }

        rebuildWorkersPagesMenu()
        updateBuildSelectionAndSummary()
    }

    private func updateBuildSelectionAndSummary() {
        let running = latestBuildsByID.values.filter(\.isInProgress).count
            + pageDeploymentsByID.values.filter { DashboardStatusKind(status: $0.latestStatus) == .inProgress }.count
        updateStatusIcon()

        if running > 0 {
            updateSummary("\(running) active build(s)")
        } else if !hasLoadedOverview || !hasLoadedLatestBuilds {
            updateSummary("Refreshing…")
        } else if projects.isEmpty {
            updateSummary("No projects found")
        } else if let lastRefreshedAt {
            updateSummary("Refreshed: \(relativeRefreshString(since: lastRefreshedAt))")
        } else {
            updateSummary("Refreshed: now")
        }
    }

    private func relativeRefreshString(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 5 {
            return "now"
        }
        if seconds < 60 {
            return "\(seconds)s ago"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h ago"
        }
        let days = hours / 24
        return "\(days)d ago"
    }

    private func rebuildWorkersPagesMenu() {
        if projects.isEmpty {
            applyWorkersPagesPlaceholder(title: sessions.isEmpty ? "Log in from Settings" : "No workers or pages")
            return
        }
        applyWorkersPagesItems(projects)
    }

    private func rebuildRecentBuildsMenu(referenceDate: Date = Date()) {
        let entries = recentBuildMenuEntries(referenceDate: referenceDate)
        recentBuildMenuItems = applyDiff(
            in: menu,
            currentItems: recentBuildMenuItems,
            at: 1,
            desired: entries,
            key: \.id,
            makeItem: makeRecentBuildMenuItem(entry:),
            updateItem: updateRecentBuildMenuItem(item:entry:)
        )
    }

    private func recentBuildMenuEntries(referenceDate: Date) -> [RecentBuildMenuEntry] {
        var entriesByID: [String: RecentBuildMenuEntry] = [:]

        for entry in currentRecentBuildMenuEntries(referenceDate: referenceDate) {
            entriesByID[entry.id] = entry
        }

        for change in activeRecentBuildChanges(referenceDate: referenceDate) {
            if let existingEntry = entriesByID[change.id] {
                entriesByID[change.id] = RecentBuildMenuEntry(
                    id: change.id,
                    project: change.project,
                    isInProgress: existingEntry.isInProgress || change.isInProgress,
                    changedAt: max(existingEntry.changedAt ?? .distantPast, change.changedAt)
                )
                continue
            }
            entriesByID[change.id] = RecentBuildMenuEntry(
                id: change.id,
                project: change.project,
                isInProgress: change.isInProgress,
                changedAt: change.changedAt
            )
        }

        return entriesByID.values
            .sorted { lhs, rhs in
                if isFavorite(lhs.project) != isFavorite(rhs.project) {
                    return isFavorite(lhs.project)
                }
                return (lhs.changedAt ?? .distantPast) > (rhs.changedAt ?? .distantPast)
            }
    }

    private func currentRecentBuildMenuEntries(referenceDate: Date) -> [RecentBuildMenuEntry] {
        var entries: [RecentBuildMenuEntry] = []

        for (buildKey, build) in uniqueBuildEntries(latestBuildsByID) {
            let statusKind = buildStatusKind(for: build)
            guard statusKind == .inProgress
                || ((statusKind == .success || statusKind == .failure)
                    && isWithinRecentBuildWindow(buildCreatedAt(build), referenceDate: referenceDate))
            else {
                continue
            }
            entries.append(
                RecentBuildMenuEntry(
                    id: build.id,
                    project: recentBuildProject(for: buildKey, build: build),
                    isInProgress: statusKind == .inProgress,
                    changedAt: buildCreatedAt(build)
                )
            )
        }

        for (projectID, deployment) in pageDeploymentsByID {
            let statusKind = DashboardStatusKind(status: deployment.latestStatus)
            guard statusKind == .inProgress
                || ((statusKind == .success || statusKind == .failure)
                    && isWithinRecentBuildWindow(deployment.lastReleaseAt, referenceDate: referenceDate))
            else {
                continue
            }
            entries.append(
                RecentBuildMenuEntry(
                    id: recentDeploymentKey(projectID: projectID, deployment: deployment),
                    project: recentPageProject(for: projectID, deployment: deployment),
                    isInProgress: statusKind == .inProgress,
                    changedAt: deployment.lastReleaseAt
                )
            )
        }

        return entries
    }

    private func isWithinRecentBuildWindow(_ date: Date?, referenceDate: Date) -> Bool {
        guard let date else {
            return false
        }
        return referenceDate.timeIntervalSince(date) <= recentBuildChangeWindow
    }

    private func applyWorkersPagesPlaceholder(title: String) {
        let currentItems = workersPagesMenu.items
        if currentItems.count == 1,
           currentItems[0].representedObject as? String == title
        {
            return
        }
        workersPagesMenu.removeAllItems()
        let emptyItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        emptyItem.isEnabled = false
        emptyItem.representedObject = title
        workersPagesMenu.addItem(emptyItem)
    }

    private func applyWorkersPagesItems(_ projects: [DashboardProject]) {
        let currentItems = workersPagesMenu.items
        _ = applyDiff(
            in: workersPagesMenu,
            currentItems: currentItems,
            at: 0,
            desired: projects,
            key: \.id,
            makeItem: makeWorkersPagesMenuItem(project:),
            updateItem: updateWorkersPagesMenuItem(item:project:)
        )
    }

    private func makeWorkersPagesMenuItem(project: DashboardProject) -> NSMenuItem {
        let item = NSMenuItem(title: project.displayName, action: nil, keyEquivalent: "")
        item.representedObject = project
        item.view = WorkersPagesMenuItemView(
            project: project,
            isFavorite: isFavorite(project),
            onClick: openURLAction(project.destinationURL),
            onToggleFavorite: toggleFavoriteAction(project)
        )
        return item
    }

    private func makeRecentBuildMenuItem(entry: RecentBuildMenuEntry) -> NSMenuItem {
        let item = NSMenuItem(title: entry.project.displayName, action: nil, keyEquivalent: "")
        item.representedObject = entry
        item.view = WorkersPagesMenuItemView(
            project: entry.project,
            isFavorite: isFavorite(entry.project),
            onClick: openURLAction(entry.project.destinationURL),
            onToggleFavorite: toggleFavoriteAction(entry.project)
        )
        return item
    }

    private func updateWorkersPagesMenuItem(item: NSMenuItem, project: DashboardProject) {
        item.representedObject = project
        item.title = project.displayName
        (item.view as? WorkersPagesMenuItemView)?.update(
            project: project,
            isFavorite: isFavorite(project),
            onClick: openURLAction(project.destinationURL),
            onToggleFavorite: toggleFavoriteAction(project)
        )
        (item.view as? WorkersPagesMenuItemView)?.syncPointerHoverState()
    }

    private func updateRecentBuildMenuItem(item: NSMenuItem, entry: RecentBuildMenuEntry) {
        item.representedObject = entry
        item.title = entry.project.displayName
        (item.view as? WorkersPagesMenuItemView)?.update(
            project: entry.project,
            isFavorite: isFavorite(entry.project),
            onClick: openURLAction(entry.project.destinationURL),
            onToggleFavorite: toggleFavoriteAction(entry.project)
        )
        (item.view as? WorkersPagesMenuItemView)?.syncPointerHoverState()
    }

    @discardableResult
    private func applyDiff<Model: Equatable>(
        in menu: NSMenu,
        currentItems: [NSMenuItem],
        at startIndex: Int,
        desired: [Model],
        key: (Model) -> String,
        makeItem: (Model) -> NSMenuItem,
        updateItem: (NSMenuItem, Model) -> Void
    ) -> [NSMenuItem] {
        var items = currentItems

        for (index, model) in desired.enumerated() {
            let modelKey = key(model)

            if index < items.count,
               let currentModel = items[index].representedObject as? Model,
               key(currentModel) == modelKey
            {
                if currentModel != model {
                    updateItem(items[index], model)
                }
                continue
            }

            if let existingIndex = items[index...].firstIndex(where: {
                guard let existingModel = $0.representedObject as? Model else {
                    return false
                }
                return key(existingModel) == modelKey
            }) {
                let item = items.remove(at: existingIndex)
                menu.removeItem(item)
                menu.insertItem(item, at: startIndex + index)
                items.insert(item, at: index)
                if let currentModel = item.representedObject as? Model, currentModel != model {
                    updateItem(item, model)
                }
                continue
            }

            let item = makeItem(model)
            menu.insertItem(item, at: startIndex + index)
            items.insert(item, at: index)
        }

        while items.count > desired.count {
            let removed = items.removeLast()
            menu.removeItem(removed)
        }

        return items
    }

    private func recentBuildProject(for buildKey: String, build: DashboardBuild) -> DashboardProject {
        let accountID = buildKey.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        let projectName = projectName(for: buildKey, build: build)
        return DashboardProject(
            accountID: accountID,
            accountEmail: accountEmail(for: accountID),
            kind: .worker,
            name: projectName,
            subtitle: build.branch,
            externalScriptID: nil,
            latestStatus: displayStatus(for: build),
            latestBranch: build.branch,
            lastReleaseAt: buildCreatedAt(build),
            metrics: nil,
            destinationURL: workerBuildURL(accountID: accountID, workerName: projectName, buildID: build.id)
        )
    }

    private func workerBuildURL(accountID: String, workerName: String, buildID: String) -> URL? {
        guard let escapedWorkerName = workerName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let escapedBuildID = buildID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else {
            return nil
        }
        return URL(string: "https://dash.cloudflare.com/\(accountID)/workers/services/view/\(escapedWorkerName)/production/builds/\(escapedBuildID)")
    }

    private func openURLAction(_ url: URL?) -> (() -> Void)? {
        guard let url else {
            return nil
        }
        return { [weak self] in
            self?.menu.cancelTracking()
            self?.workersPagesMenu.cancelTracking()
            NSWorkspace.shared.open(url)
        }
    }

    private func toggleFavoriteAction(_ project: DashboardProject) -> (() -> Void) {
        { [weak self] in
            self?.toggleFavorite(for: project)
        }
    }

    private func toggleFavorite(for project: DashboardProject) {
        if favoriteProjectIDs.contains(project.id) {
            favoriteProjectIDs.remove(project.id)
        } else {
            favoriteProjectIDs.insert(project.id)
        }
        AppPreferences.setFavoriteProjectIDs(favoriteProjectIDs)
        clearMenuInteractionState()
        rebuildProjectsFromSnapshots()
        rebuildRecentBuildsMenu()
        refreshVisibleMenuItems()
        DispatchQueue.main.async { [weak self] in
            self?.refreshVisibleMenuItems()
        }
    }

    private func isFavorite(_ project: DashboardProject) -> Bool {
        favoriteProjectIDs.contains(project.id)
    }

    private func clearMenuInteractionState() {
        for item in workersPagesMenu.items {
            (item.view as? WorkersPagesMenuItemView)?.resetInteractionState()
        }
        for item in recentBuildMenuItems {
            (item.view as? WorkersPagesMenuItemView)?.resetInteractionState()
        }
    }

    private func refreshVisibleMenuItems() {
        for item in workersPagesMenu.items {
            guard let project = item.representedObject as? DashboardProject else {
                continue
            }
            updateWorkersPagesMenuItem(item: item, project: project)
        }
        for item in recentBuildMenuItems {
            guard let entry = item.representedObject as? RecentBuildMenuEntry else {
                continue
            }
            updateRecentBuildMenuItem(item: item, entry: entry)
        }
    }

    private func buildCreatedAt(_ build: DashboardBuild) -> Date? {
        guard let createdOn = build.createdOn else {
            return nil
        }
        return parseDate(createdOn)
    }

    private func parseDate(_ value: String) -> Date? {
        if let date = fractionalDateFormatter.date(from: value) {
            return date
        }
        return plainDateFormatter.date(from: value)
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

    private func accountEmail(for accountID: String) -> String? {
        sessions.first(where: { $0.accountID == accountID })?.userEmail
    }

    private func recordBuildChanges(
        from previousBuilds: [String: DashboardBuild],
        to nextBuilds: [String: DashboardBuild]
    ) {
        let now = Date()
        for (buildKey, build) in uniqueBuildEntries(nextBuilds) {
            let previousBuild = previousBuilds[buildKey]
            guard shouldNotify(for: build, previous: previousBuild) else {
                continue
            }
            let status = displayStatus(for: build)
            let project = recentBuildProject(for: buildKey, build: build)
            recentBuildChangesByKey[build.id] = RecentBuildChange(
                id: build.id,
                project: project,
                projectName: projectName(for: buildKey),
                status: status,
                statusKind: buildStatusKind(for: build),
                symbolName: statusIconSymbolName(for: build),
                changedAt: now
                ,
                isInProgress: build.isInProgress
            )
        }
        pruneRecentBuildChanges(referenceDate: now)
    }

    private func recordPageDeploymentChanges(
        from previousDeployments: [String: DashboardPageDeployment],
        to nextDeployments: [String: DashboardPageDeployment]
    ) {
        let now = Date()
        for (projectID, deployment) in nextDeployments {
            let previousDeployment = previousDeployments[projectID]
            guard shouldNotify(for: deployment, previous: previousDeployment) else {
                continue
            }
            let status = deployment.latestStatus?.lowercased() ?? "unknown"
            let statusKind = DashboardStatusKind(status: deployment.latestStatus)
            let changeID = recentDeploymentKey(projectID: projectID, deployment: deployment)
            recentBuildChangesByKey[changeID] = RecentBuildChange(
                id: changeID,
                project: recentPageProject(for: projectID, deployment: deployment),
                projectName: projectName(forPageProjectID: projectID),
                status: status,
                statusKind: statusKind,
                symbolName: statusIconSymbolName(for: statusKind),
                changedAt: statusKind == .inProgress ? now : (deployment.lastReleaseAt ?? now),
                isInProgress: statusKind == .inProgress
            )
        }
        pruneRecentBuildChanges(referenceDate: now)
    }

    private func notifyAboutBuildChanges(
        from previousBuilds: [String: DashboardBuild],
        to nextBuilds: [String: DashboardBuild]
    ) {
        guard AppPreferences.notificationsEnabled, hasLoadedLatestBuilds else {
            return
        }

        for (buildKey, build) in uniqueBuildEntries(nextBuilds) {
            let previousBuild = previousBuilds[buildKey]
            guard shouldNotify(for: build, previous: previousBuild) else {
                continue
            }

            let projectName = DashboardDemoMode.displayProjectName(projectName(for: buildKey))
            let status = displayStatus(for: build)
            let body = build.branch.map { "\(status) • \($0)" } ?? status

            if build.isInProgress {
                BuildNotificationManager.notify(title: projectName, body: body)
            } else if build.isSuccessful {
                BuildNotificationManager.notify(title: projectName, body: body)
            } else if build.isFailed {
                BuildNotificationManager.notify(title: projectName, body: body)
            }
        }
    }

    private func notifyAboutPageDeploymentChanges(
        from previousDeployments: [String: DashboardPageDeployment],
        to nextDeployments: [String: DashboardPageDeployment]
    ) {
        guard AppPreferences.notificationsEnabled, hasLoadedPageDeployments else {
            return
        }

        for (projectID, deployment) in nextDeployments {
            let previousDeployment = previousDeployments[projectID]
            guard shouldNotify(for: deployment, previous: previousDeployment) else {
                continue
            }

            let status = deployment.latestStatus?.lowercased() ?? "unknown"
            let body = deployment.latestBranch.map { "\(status) • \($0)" } ?? status
            let statusKind = DashboardStatusKind(status: deployment.latestStatus)
            if statusKind == .inProgress || statusKind == .success || statusKind == .failure {
                BuildNotificationManager.notify(
                    title: DashboardDemoMode.displayProjectName(projectName(forPageProjectID: projectID)),
                    body: body
                )
            }
        }
    }

    private func uniqueBuildEntries(_ builds: [String: DashboardBuild]) -> [(String, DashboardBuild)] {
        var seenBuildIDs = Set<String>()
        var result: [(String, DashboardBuild)] = []
        for (buildKey, build) in builds {
            guard seenBuildIDs.insert(build.id).inserted else {
                continue
            }
            result.append((buildKey, build))
        }
        return result
    }

    private func projectName(for buildKey: String) -> String {
        overviewProjectsByID.values.first(where: { $0.buildID == buildKey })?.name ?? "Worker"
    }

    private func projectName(forPageProjectID projectID: String) -> String {
        overviewProjectsByID[projectID]?.name ?? projectID.split(separator: ":").last.map(String.init) ?? "Page"
    }

    private func projectName(for buildKey: String, build: DashboardBuild) -> String {
        if let project = overviewProjectsByID.values.first(where: { project in
            guard project.kind == .worker else {
                return false
            }
            if project.buildID == buildKey {
                return true
            }
            return build.versionIDs.contains { versionID in
                project.buildID == "\(project.accountID):\(versionID)" || project.externalScriptID == versionID
            }
        }) {
            return project.name
        }
        return projectName(for: buildKey)
    }

    private func recentDeploymentKey(projectID: String, deployment: DashboardPageDeployment) -> String {
        if let id = deployment.id, !id.isEmpty {
            return id
        }
        let timestamp = deployment.lastReleaseAt?.timeIntervalSince1970 ?? 0
        return "\(projectID):\(timestamp):\(deployment.latestStatus ?? "unknown")"
    }

    private func statusIconSymbolName(for build: DashboardBuild) -> String {
        if build.isInProgress {
            return Self.inProgressStatusImageName
        }
        if build.isFailed {
            return "exclamationmark.icloud.fill"
        }
        if build.isSuccessful {
            return "checkmark.icloud.fill"
        }
        return "icloud.fill"
    }

    private func statusIconSymbolName(for statusKind: DashboardStatusKind) -> String {
        switch statusKind {
        case .inProgress:
            Self.inProgressStatusImageName
        case .failure:
            "exclamationmark.icloud.fill"
        case .success:
            "checkmark.icloud.fill"
        case .neutral:
            "icloud.fill"
        }
    }

    private func buildStatusKind(for build: DashboardBuild) -> DashboardStatusKind {
        if build.isInProgress {
            return .inProgress
        }
        if build.isFailed {
            return .failure
        }
        if build.isSuccessful {
            return .success
        }
        return .neutral
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

    private func shouldNotify(for deployment: DashboardPageDeployment, previous: DashboardPageDeployment?) -> Bool {
        guard let previous else {
            return false
        }
        let statusKind = DashboardStatusKind(status: deployment.latestStatus)
        guard statusKind == .inProgress || statusKind == .success || statusKind == .failure else {
            return false
        }
        if previous.lastReleaseAt != deployment.lastReleaseAt {
            return true
        }
        if previous.latestStatus != deployment.latestStatus {
            return true
        }
        if previous.latestBranch != deployment.latestBranch {
            return true
        }
        return false
    }

    private func recentPageProject(for projectID: String, deployment: DashboardPageDeployment) -> DashboardProject {
        if let baseProject = overviewProjectsByID[projectID] {
            return DashboardProject(
                accountID: baseProject.accountID,
                accountEmail: accountEmail(for: baseProject.accountID),
                kind: .page,
                name: baseProject.name,
                subtitle: baseProject.subtitle,
                externalScriptID: nil,
                latestStatus: deployment.latestStatus,
                latestBranch: deployment.latestBranch,
                lastReleaseAt: deployment.lastReleaseAt,
                metrics: nil,
                destinationURL: nil
            )
        }

        let components = projectID.split(separator: ":", maxSplits: 2).map(String.init)
        let accountID = components.first ?? ""
        let name = components.last ?? "Page"
        return DashboardProject(
            accountID: accountID,
            accountEmail: accountEmail(for: accountID),
            kind: .page,
            name: name,
            subtitle: nil,
            externalScriptID: nil,
            latestStatus: deployment.latestStatus,
            latestBranch: deployment.latestBranch,
            lastReleaseAt: deployment.lastReleaseAt,
            metrics: nil,
            destinationURL: nil
        )
    }

    private func hasInProgressStatuses() -> Bool {
        latestBuildsByID.values.contains(where: \.isInProgress)
            || pageDeploymentsByID.values.contains(where: { DashboardStatusKind(status: $0.latestStatus) == .inProgress })
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard menu === workersPagesMenu || menu === self.menu else {
            return
        }
        refreshVisibleMenuItems()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === workersPagesMenu || menu === self.menu else {
            return
        }
        clearMenuInteractionState()
    }
    private let recentBuildChangeWindow: TimeInterval = 5 * 60
    private let recentBuildMenuWindow: TimeInterval = 5 * 60
}
