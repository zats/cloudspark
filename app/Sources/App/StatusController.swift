import AppKit
import Foundation

@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    private static let inProgressStatusSymbolName = "arrow.2.circlepath"
    private static let inProgressStatusSymbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)

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

    private enum ProjectSubmenuAction {
        case openInBrowser
        case metrics
        case observability
        case toggleFavorite
        case hide
    }

    private struct ProjectSubmenuContext {
        let project: DashboardProject
        let action: ProjectSubmenuAction
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusIconView = NSImageView()
    private let menu = NSMenu()
    private let workersPagesMenu = NSMenu()
    private let summaryItem = NSMenuItem(title: "Cloudflare", action: nil, keyEquivalent: "")
    private let summarySectionSeparatorItem = NSMenuItem.separator()
    private let workersPagesItem = NSMenuItem(title: "Workers", action: nil, keyEquivalent: "")
    private let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshBuilds), keyEquivalent: "r")
    private let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
    private let checkForUpdatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
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
    private var hiddenProjects = AppPreferences.hiddenProjects
    private var metricsWindow: MetricsWindowController?
    private var observabilityWindow: ObservabilityWindowController?
    private let updateController: UpdateControlling
    private var currentStatusIconSymbolName: String?
    private var isStatusIconAnimating = false

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
        configureStatusButton()
        let initialSymbolName = statusIconSymbolName(
            activeRecentChanges: [],
            hasInProgressBuild: false
        )
        statusIconView.image = statusIconImage(symbolName: initialSymbolName, shouldAnimate: false)
        currentStatusIconSymbolName = initialSymbolName
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
        checkForUpdatesItem.isEnabled = updateController.isAvailable
    }

    private func updateSummary(_ text: String) {
        summaryItem.title = text
        rebuildRecentBuildsMenu()
    }

    private func updateStatusIcon() {
        let referenceDate = Date()
        let activeRecentChanges = activeRecentBuildChanges(referenceDate: referenceDate)
        let hasInProgressBuild = hasInProgressStatuses(referenceDate: referenceDate)
        let symbolName = statusIconSymbolName(
            activeRecentChanges: activeRecentChanges,
            hasInProgressBuild: hasInProgressBuild
        )
        let shouldAnimate = symbolName == Self.inProgressStatusSymbolName
        if currentStatusIconSymbolName != symbolName || isStatusIconAnimating != shouldAnimate {
            statusIconView.image = statusIconImage(
                symbolName: symbolName,
                shouldAnimate: shouldAnimate
            )
            updateStatusIconEffect(shouldAnimate: shouldAnimate)
            currentStatusIconSymbolName = symbolName
            isStatusIconAnimating = shouldAnimate
        }
        statusItem.button?.title = ""
        statusItem.button?.toolTip = statusTooltip(activeRecentChanges: activeRecentChanges)
    }

    private func statusIconSymbolName(
        activeRecentChanges: [RecentBuildChange],
        hasInProgressBuild: Bool
    ) -> String {
        if activeRecentChanges.contains(where: { $0.statusKind == .failure }) {
            return "exclamationmark.icloud.fill"
        } else if hasInProgressBuild {
            return Self.inProgressStatusSymbolName
        } else if let latestChange = activeRecentChanges.first {
            return latestChange.symbolName
        } else {
            return "icloud.fill"
        }
    }

    private func statusIconImage(
        symbolName: String,
        shouldAnimate: Bool
    ) -> NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: AppBundle.name)
        if shouldAnimate {
            return image?.withSymbolConfiguration(Self.inProgressStatusSymbolConfiguration)
        }
        return image
    }

    private func updateStatusIconEffect(shouldAnimate: Bool) {
        statusIconView.removeAllSymbolEffects(animated: false)
        guard shouldAnimate else {
            return
        }
        statusIconView.addSymbolEffect(.rotate.byLayer, options: .repeat(.continuous))
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else {
            return
        }
        button.image = nil
        button.imagePosition = .imageOnly
        button.title = ""

        guard statusIconView.superview !== button else {
            return
        }

        statusIconView.translatesAutoresizingMaskIntoConstraints = false
        statusIconView.imageScaling = .scaleProportionallyUpOrDown
        statusIconView.contentTintColor = .labelColor
        button.addSubview(statusIconView)
        NSLayoutConstraint.activate([
            statusIconView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            statusIconView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            statusIconView.widthAnchor.constraint(greaterThanOrEqualToConstant: 14),
            statusIconView.heightAnchor.constraint(greaterThanOrEqualToConstant: 14),
        ])
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
        return recentBuildChangesByKey.values
            .filter { !isHidden($0.project) }
            .sorted { lhs, rhs in
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
                settingsController.refresh(sessions: sessions, hiddenProjects: hiddenProjects)
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
                        let workerProjects = refreshableProjects(
                            accountID: session.accountID ?? "",
                            kind: .worker
                        )
                        guard !workerProjects.isEmpty else { continue }
                        let client = DashboardAPIClient(session: session)
                        let latestBuilds = try await client.listLatestWorkerReleases(
                            accountID: session.accountID ?? "",
                            workers: workerProjects
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
                            let projectID = "\(session.accountID ?? ""):worker:\(scriptName)"
                            guard let project = overviewProjectsByID[projectID], !isHidden(project) else {
                                continue
                            }
                            nextWorkerMetricsByID[projectID] = metric
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
                        let projectNames = refreshableProjects(
                            accountID: session.accountID ?? "",
                            kind: .page
                        ).map(\.name)
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
            hiddenProjects: hiddenProjects,
            selectedTab: selectedTab,
            onLogin: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    do {
                        _ = try await self.ensureSessions(forceLogin: true)
                        self.syncMenuState()
                        self.scheduleRefresh()
                        self.settingsController.refresh(sessions: self.sessions, hiddenProjects: self.hiddenProjects)
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
            onUnhideProject: { [weak self] hiddenProject in
                self?.unhideProject(hiddenProject)
            },
            onSetLaunchAtLogin: { [weak self] enabled in
                do {
                    try LaunchAtLoginManager.setEnabled(enabled)
                    self?.settingsController.refresh(sessions: self?.sessions ?? [], hiddenProjects: self?.hiddenProjects ?? [])
                } catch {
                    self?.presentError(error)
                    self?.settingsController.refresh(sessions: self?.sessions ?? [], hiddenProjects: self?.hiddenProjects ?? [])
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
                    self.settingsController.refresh(sessions: self.sessions, hiddenProjects: self.hiddenProjects)
                }
            },
            onSetRefreshInterval: { [weak self] interval in
                AppPreferences.setRefreshInterval(interval)
                self?.scheduleRefresh()
                self?.settingsController.refresh(sessions: self?.sessions ?? [], hiddenProjects: self?.hiddenProjects ?? [])
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
                    self.settingsController.refresh(sessions: self.sessions, hiddenProjects: self.hiddenProjects)
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
            closeObservabilityWindows()
            rebuildWorkersPagesMenu()
            settingsController.refresh(sessions: sessions, hiddenProjects: hiddenProjects)
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
                            destinationURL(for: $0, workerName: baseProject.name, accountID: baseProject.accountID)
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
            .filter { !isHidden($0) }
            .sorted {
                if isFavorite($0) != isFavorite($1) {
                    return isFavorite($0)
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }

        rebuildWorkersPagesMenu()
        syncMenuState()
        syncObservabilityWindow()
        updateBuildSelectionAndSummary()
    }

    private func updateBuildSelectionAndSummary() {
        let referenceDate = Date()
        let running = inProgressRecentBuildMenuEntries(referenceDate: referenceDate).count
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
        RelativeTime.shortString(since: date)
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
        var entriesByProjectID: [String: RecentBuildMenuEntry] = [:]

        for entry in currentRecentBuildMenuEntries(referenceDate: referenceDate) {
            mergeRecentBuildMenuEntry(entry, into: &entriesByProjectID)
        }

        for entry in overviewInProgressMenuEntries() {
            mergeRecentBuildMenuEntry(entry, into: &entriesByProjectID)
        }

        for change in activeRecentBuildChanges(referenceDate: referenceDate) {
            mergeRecentBuildMenuEntry(
                RecentBuildMenuEntry(
                    id: change.project.id,
                    project: change.project,
                    isInProgress: change.isInProgress,
                    changedAt: change.changedAt
                ),
                into: &entriesByProjectID
            )
        }

        return entriesByProjectID.values
            .sorted { lhs, rhs in
                if isFavorite(lhs.project) != isFavorite(rhs.project) {
                    return isFavorite(lhs.project)
                }
                let lhsDate = lhs.changedAt ?? .distantPast
                let rhsDate = rhs.changedAt ?? .distantPast
                if abs(lhsDate.timeIntervalSince(rhsDate)) <= 2 {
                    let nameOrder = lhs.project.displayName.localizedCaseInsensitiveCompare(rhs.project.displayName)
                    if nameOrder != .orderedSame {
                        return nameOrder == .orderedAscending
                    }
                    return lhs.project.id < rhs.project.id
                }
                return lhsDate > rhsDate
            }
    }

    private func mergeRecentBuildMenuEntry(
        _ entry: RecentBuildMenuEntry,
        into entriesByProjectID: inout [String: RecentBuildMenuEntry]
    ) {
        let projectID = entry.project.id
        guard let existingEntry = entriesByProjectID[projectID] else {
            entriesByProjectID[projectID] = RecentBuildMenuEntry(
                id: projectID,
                project: entry.project,
                isInProgress: entry.isInProgress,
                changedAt: entry.changedAt
            )
            return
        }

        entriesByProjectID[projectID] = RecentBuildMenuEntry(
            id: projectID,
            project: entry.project,
            isInProgress: existingEntry.isInProgress || entry.isInProgress,
            changedAt: newestRecentBuildDate(existingEntry.changedAt, entry.changedAt)
        )
    }

    private func newestRecentBuildDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            max(lhs, rhs)
        case let (lhs?, nil):
            lhs
        case let (nil, rhs?):
            rhs
        case (nil, nil):
            nil
            }
    }

    private func overviewInProgressMenuEntries() -> [RecentBuildMenuEntry] {
        projects
            .filter { $0.statusKind == .inProgress && !isHidden($0) }
            .map {
                RecentBuildMenuEntry(
                    id: $0.id,
                    project: $0,
                    isInProgress: true,
                    changedAt: $0.lastReleaseAt
                )
            }
    }

    private func inProgressRecentBuildMenuEntries(referenceDate: Date) -> [RecentBuildMenuEntry] {
        recentBuildMenuEntries(referenceDate: referenceDate)
            .filter(\.isInProgress)
    }

    private func currentRecentBuildMenuEntries(referenceDate: Date) -> [RecentBuildMenuEntry] {
        var entries: [RecentBuildMenuEntry] = []

        for (buildKey, build) in uniqueBuildEntries(latestBuildsByID) {
            let statusKind = buildStatusKind(for: build)
            let project = recentBuildProject(for: buildKey, build: build)
            guard !isHidden(project) else {
                continue
            }
            guard statusKind == .inProgress
                || ((statusKind == .success || statusKind == .failure)
                    && isWithinRecentBuildWindow(buildCreatedAt(build), referenceDate: referenceDate))
            else {
                continue
            }
            entries.append(
                RecentBuildMenuEntry(
                    id: project.id,
                    project: project,
                    isInProgress: statusKind == .inProgress,
                    changedAt: buildCreatedAt(build)
                )
            )
        }

        for (projectID, deployment) in pageDeploymentsByID {
            let statusKind = DashboardStatusKind(status: deployment.latestStatus)
            let project = recentPageProject(for: projectID, deployment: deployment)
            guard !isHidden(project) else {
                continue
            }
            guard statusKind == .inProgress
                || ((statusKind == .success || statusKind == .failure)
                    && isWithinRecentBuildWindow(deployment.lastReleaseAt, referenceDate: referenceDate))
            else {
                continue
            }
            entries.append(
                RecentBuildMenuEntry(
                    id: project.id,
                    project: project,
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
        item.submenu = makeProjectSubmenu(for: project)
        item.view = WorkersPagesMenuItemView(
            project: project,
            isFavorite: isFavorite(project),
            onClick: openURLAction(project.destinationURL),
            onShowObservability: openObservabilityAction(project),
            onToggleFavorite: toggleFavoriteAction(project),
            onHide: hideProjectAction(project)
        )
        return item
    }

    private func makeRecentBuildMenuItem(entry: RecentBuildMenuEntry) -> NSMenuItem {
        let item = NSMenuItem(title: entry.project.displayName, action: nil, keyEquivalent: "")
        item.representedObject = entry
        item.submenu = makeProjectSubmenu(for: entry.project)
        item.view = WorkersPagesMenuItemView(
            project: entry.project,
            isFavorite: isFavorite(entry.project),
            onClick: openURLAction(entry.project.destinationURL),
            onShowObservability: openObservabilityAction(entry.project),
            onToggleFavorite: toggleFavoriteAction(entry.project),
            onHide: hideProjectAction(entry.project)
        )
        return item
    }

    private func updateWorkersPagesMenuItem(item: NSMenuItem, project: DashboardProject) {
        item.representedObject = project
        item.title = project.displayName
        item.submenu = makeProjectSubmenu(for: project)
        (item.view as? WorkersPagesMenuItemView)?.update(
            project: project,
            isFavorite: isFavorite(project),
            onClick: openURLAction(project.destinationURL),
            onShowObservability: openObservabilityAction(project),
            onToggleFavorite: toggleFavoriteAction(project),
            onHide: hideProjectAction(project)
        )
        (item.view as? WorkersPagesMenuItemView)?.syncPointerHoverState()
    }

    private func updateRecentBuildMenuItem(item: NSMenuItem, entry: RecentBuildMenuEntry) {
        item.representedObject = entry
        item.title = entry.project.displayName
        item.submenu = makeProjectSubmenu(for: entry.project)
        (item.view as? WorkersPagesMenuItemView)?.update(
            project: entry.project,
            isFavorite: isFavorite(entry.project),
            onClick: openURLAction(entry.project.destinationURL),
            onShowObservability: openObservabilityAction(entry.project),
            onToggleFavorite: toggleFavoriteAction(entry.project),
            onHide: hideProjectAction(entry.project)
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
            destinationURL: destinationURL(for: build, workerName: projectName, accountID: accountID)
        )
    }

    private func destinationURL(for build: DashboardBuild, workerName: String, accountID: String) -> URL? {
        build.destinationURL ?? workerBuildURL(accountID: accountID, workerName: workerName, buildID: build.id)
    }

    private func makeProjectSubmenu(for project: DashboardProject) -> NSMenu {
        let menu = NSMenu(title: project.displayName)
        menu.addItem(makeProjectSubmenuItem(
            title: "Open in Browser",
            symbolName: "globe",
            project: project,
            action: .openInBrowser,
            enabled: project.destinationURL != nil
        ))
        menu.addItem(makeProjectSubmenuItem(
            title: "Metrics",
            symbolName: "chart.xyaxis.line",
            project: project,
            action: .metrics,
            enabled: true
        ))
        menu.addItem(makeProjectSubmenuItem(
            title: "Observability",
            symbolName: "chart.line.text.clipboard",
            project: project,
            action: .observability,
            enabled: project.kind == .worker
        ))
        menu.addItem(.separator())
        menu.addItem(makeProjectSubmenuItem(
            title: isFavorite(project) ? "Unfavorite" : "Favorite",
            symbolName: isFavorite(project) ? "star.slash" : "star",
            project: project,
            action: .toggleFavorite,
            enabled: true
        ))
        menu.addItem(makeProjectSubmenuItem(
            title: project.kind == .worker ? "Hide Worker" : "Hide Page",
            symbolName: "eye.slash",
            project: project,
            action: .hide,
            enabled: true
        ))
        return menu
    }

    private func makeProjectSubmenuItem(
        title: String,
        symbolName: String,
        project: DashboardProject,
        action: ProjectSubmenuAction,
        enabled: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(handleProjectSubmenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        item.representedObject = ProjectSubmenuContext(project: project, action: action)
        item.image = submenuSymbolImage(symbolName)
        return item
    }

    private func submenuSymbolImage(_ symbolName: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
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

    private func hideProjectAction(_ project: DashboardProject) -> (() -> Void) {
        { [weak self] in
            self?.hideProject(project)
        }
    }

    private func openObservabilityAction(_ project: DashboardProject) -> (() -> Void)? {
        guard project.kind == .worker else {
            return nil
        }
        return { [weak self] in
            self?.openObservability(for: project)
        }
    }

    private func openMetricsAction(_ project: DashboardProject) -> (() -> Void)? {
        return { [weak self] in
            self?.openMetrics(for: project)
        }
    }

    @objc
    private func handleProjectSubmenuAction(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? ProjectSubmenuContext else {
            return
        }

        switch context.action {
        case .openInBrowser:
            openURLAction(context.project.destinationURL)?()
        case .metrics:
            openMetricsAction(context.project)?()
        case .observability:
            openObservabilityAction(context.project)?()
        case .toggleFavorite:
            toggleFavorite(for: context.project)
        case .hide:
            hideProject(context.project)
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

    private func hideProject(_ project: DashboardProject) {
        hiddenProjects.removeAll { $0.id == project.id }
        hiddenProjects.append(DashboardHiddenProject(project: project))
        AppPreferences.setHiddenProjects(hiddenProjects)
        favoriteProjectIDs.remove(project.id)
        AppPreferences.setFavoriteProjectIDs(favoriteProjectIDs)
        recentBuildChangesByKey = recentBuildChangesByKey.filter { $0.value.project.id != project.id }
        clearMenuInteractionState()
        rebuildProjectsFromSnapshots()
        rebuildRecentBuildsMenu()
        settingsController.refresh(sessions: sessions, hiddenProjects: hiddenProjects)
        updateBuildSelectionAndSummary()
    }

    private func unhideProject(_ hiddenProject: DashboardHiddenProject) {
        hiddenProjects.removeAll { $0.id == hiddenProject.id }
        AppPreferences.setHiddenProjects(hiddenProjects)
        rebuildProjectsFromSnapshots()
        rebuildRecentBuildsMenu()
        settingsController.refresh(sessions: sessions, hiddenProjects: hiddenProjects)
        updateBuildSelectionAndSummary()
    }

    private func isFavorite(_ project: DashboardProject) -> Bool {
        favoriteProjectIDs.contains(project.id)
    }

    private func openObservability(for project: DashboardProject) {
        let workers = observabilityWorkerProjects()
        guard let session = sessions.first(where: { $0.accountID == project.accountID }) else {
            return
        }

        if let existing = observabilityWindow {
            existing.updateWorkers(workers, sessions: sessions, selectedProjectID: project.id)
            existing.showAndActivate()
            return
        }

        let controller = ObservabilityWindowController(project: project, session: session, workers: workers, sessions: sessions)
        controller.onClose = { [weak self] in
            self?.observabilityWindow = nil
        }
        observabilityWindow = controller
        menu.cancelTracking()
        workersPagesMenu.cancelTracking()
        controller.showAndActivate()
    }

    private func openMetrics(for project: DashboardProject) {
        let metricsProjects = projects
        guard let session = sessions.first(where: { $0.accountID == project.accountID }) else {
            return
        }

        if let existing = metricsWindow {
            existing.updateProjects(metricsProjects, sessions: sessions, selectedProjectID: project.id)
            existing.showAndActivate()
            return
        }

        let controller = MetricsWindowController(project: project, session: session, projects: metricsProjects, sessions: sessions)
        controller.onClose = { [weak self] in
            self?.metricsWindow = nil
        }
        metricsWindow = controller
        menu.cancelTracking()
        workersPagesMenu.cancelTracking()
        controller.showAndActivate()
    }

    @objc
    private func openMetricsFromMenu() {
        guard let project = projects.first else {
            return
        }
        openMetrics(for: project)
    }

    @objc
    private func openObservabilityFromMenu() {
        guard let project = observabilityWorkerProjects().first else {
            return
        }
        openObservability(for: project)
    }

    private func closeObservabilityWindow() {
        guard let controller = observabilityWindow else {
            return
        }
        observabilityWindow = nil
        controller.onClose = nil
        controller.close()
    }

    private func closeMetricsWindow() {
        guard let controller = metricsWindow else {
            return
        }
        metricsWindow = nil
        controller.onClose = nil
        controller.close()
    }

    private func closeObservabilityWindows() {
        closeMetricsWindow()
        closeObservabilityWindow()
    }

    private func isHidden(_ project: DashboardProject) -> Bool {
        hiddenProjects.contains { $0.id == project.id }
    }

    private func clearMenuInteractionState() {
        for item in workersPagesMenu.items {
            (item.view as? WorkersPagesMenuItemView)?.resetInteractionState()
        }
        for item in recentBuildMenuItems {
            (item.view as? WorkersPagesMenuItemView)?.resetInteractionState()
        }
    }

    private func observabilityWorkerProjects() -> [DashboardProject] {
        projects.filter { $0.kind == .worker }
    }

    private func syncObservabilityWindow(selectedProjectID: String? = nil) {
        if let controller = metricsWindow {
            controller.updateProjects(projects, sessions: sessions, selectedProjectID: selectedProjectID)
            if projects.isEmpty {
                metricsWindow = nil
            }
        }

        guard let controller = observabilityWindow else {
            return
        }
        controller.updateWorkers(observabilityWorkerProjects(), sessions: sessions, selectedProjectID: selectedProjectID)
        if observabilityWorkerProjects().isEmpty {
            observabilityWindow = nil
        }
    }

    private func refreshVisibleMenuItems() {
        for item in workersPagesMenu.items {
            (item.view as? WorkersPagesMenuItemView)?.syncPointerHoverState()
        }
        for item in recentBuildMenuItems {
            (item.view as? WorkersPagesMenuItemView)?.syncPointerHoverState()
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

    private func refreshableProjects(accountID: String, kind: DashboardProjectKind) -> [DashboardProject] {
        overviewProjectsByID.values.filter {
            $0.accountID == accountID && $0.kind == kind && !isHidden($0)
        }
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
            guard !isHidden(project) else {
                continue
            }
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
            let project = recentPageProject(for: projectID, deployment: deployment)
            guard !isHidden(project) else {
                continue
            }
            let status = deployment.latestStatus?.lowercased() ?? "unknown"
            let statusKind = DashboardStatusKind(status: deployment.latestStatus)
            let changeID = recentDeploymentKey(projectID: projectID, deployment: deployment)
            recentBuildChangesByKey[changeID] = RecentBuildChange(
                id: changeID,
                project: project,
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
            let project = recentBuildProject(for: buildKey, build: build)
            guard !isHidden(project) else {
                continue
            }

            let projectName = project.displayName
            let status = displayStatus(for: build)
            let body = DashboardDemoMode.displaySecondaryText(build.branch).map { "\(status) • \($0)" } ?? status

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
            let project = recentPageProject(for: projectID, deployment: deployment)
            guard !isHidden(project) else {
                continue
            }

            let status = deployment.latestStatus?.lowercased() ?? "unknown"
            let body = DashboardDemoMode.displaySecondaryText(deployment.latestBranch).map { "\(status) • \($0)" } ?? status
            let statusKind = DashboardStatusKind(status: deployment.latestStatus)
            if statusKind == .inProgress || statusKind == .success || statusKind == .failure {
                BuildNotificationManager.notify(title: project.displayName, body: body)
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
            return "arrow.2.circlepath"
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
            "arrow.2.circlepath"
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

    private func hasInProgressStatuses(referenceDate: Date = Date()) -> Bool {
        !inProgressRecentBuildMenuEntries(referenceDate: referenceDate).isEmpty
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
