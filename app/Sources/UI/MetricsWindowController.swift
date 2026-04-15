import AppKit
import Foundation
import SwiftUI

@MainActor
final class MetricsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    var onClose: (() -> Void)?

    private let viewModel: MetricsViewModel
    private let projectControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let versionModeControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let specificVersionControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let timeframeControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let toolbar = NSToolbar(identifier: "metrics.window.toolbar")
    private var projectWidthConstraint: NSLayoutConstraint?
    private var versionModeWidthConstraint: NSLayoutConstraint?
    private var specificVersionWidthConstraint: NSLayoutConstraint?
    private var timeframeWidthConstraint: NSLayoutConstraint?
    private var isSelectingProject = false

    init(project: DashboardProject, session: DashboardSession, projects: [DashboardProject], sessions: [DashboardSession]) {
        self.viewModel = MetricsViewModel(project: project, session: session, projects: projects, sessions: sessions)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .unifiedTitleAndToolbar],
            backing: .buffered,
            defer: false
        )
        window.title = project.displayName
        window.minSize = NSSize(width: 980, height: 720)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.toolbarStyle = .unified
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        super.init(window: window)

        let hostingView = NSHostingView(rootView: MetricsWindowView(viewModel: viewModel))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView?.addSubview(hostingView)
        if let contentView = window.contentView {
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }
        toolbar.delegate = self
        window.toolbar = toolbar
        window.delegate = self
        configure()
        syncWindowTitle()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func showAndActivate() {
        showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.orderFrontRegardless()
        window?.makeKey()
        syncWindowTitle()
        viewModel.reloadIfNeeded()
    }

    func updateProjects(_ projects: [DashboardProject], sessions: [DashboardSession], selectedProjectID: String? = nil) {
        viewModel.updateProjects(projects, sessions: sessions, selectedProjectID: selectedProjectID)
        rebuildProjectControl()
        rebuildVersionControls()
        syncTimeframeSelection()
        syncToolbarForProjectKind()
        syncWindowTitle()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    private func syncWindowTitle() {
        window?.title = viewModel.selectedProject.displayName
    }

    private enum ToolbarItemID {
        static let project = NSToolbarItem.Identifier("metrics.project")
        static let versionMode = NSToolbarItem.Identifier("metrics.version-mode")
        static let specificVersion = NSToolbarItem.Identifier("metrics.specific-version")
        static let timeframe = NSToolbarItem.Identifier("metrics.timeframe")
        static let refresh = NSToolbarItem.Identifier("metrics.refresh")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarItemID.project,
            ToolbarItemID.versionMode,
            ToolbarItemID.specificVersion,
            ToolbarItemID.timeframe,
            .space,
            ToolbarItemID.refresh,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarItemID.project,
            ToolbarItemID.versionMode,
            ToolbarItemID.specificVersion,
            ToolbarItemID.timeframe,
            ToolbarItemID.refresh,
            .space,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarItemID.project:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Project"
            item.paletteLabel = "Project"
            item.view = projectControl
            return item
        case ToolbarItemID.versionMode:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Version mode"
            item.paletteLabel = "Version mode"
            item.view = versionModeControl
            return item
        case ToolbarItemID.specificVersion:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Versions"
            item.paletteLabel = "Versions"
            item.view = specificVersionControl
            return item
        case ToolbarItemID.timeframe:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Timeframe"
            item.paletteLabel = "Timeframe"
            item.view = timeframeControl
            return item
        case ToolbarItemID.refresh:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Refresh"
            item.paletteLabel = "Refresh"
            item.toolTip = "Refresh"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
            item.target = self
            item.action = #selector(refreshNow)
            return item
        default:
            return nil
        }
    }

    private func configure() {
        projectControl.target = self
        projectControl.action = #selector(changeProject)
        projectControl.toolTip = "Project"

        versionModeControl.target = self
        versionModeControl.action = #selector(changeVersionMode)
        versionModeControl.toolTip = "Version filter"

        specificVersionControl.target = self
        specificVersionControl.action = #selector(changeSpecificVersion)
        specificVersionControl.toolTip = "Versions"

        DashboardMetricsRangePreset.allCases.forEach { timeframeControl.addItem(withTitle: $0.shortTitle) }
        timeframeControl.target = self
        timeframeControl.action = #selector(changeTimeframe)
        timeframeControl.toolTip = "Timeframe"

        projectWidthConstraint = projectControl.widthAnchor.constraint(equalToConstant: 220)
        versionModeWidthConstraint = versionModeControl.widthAnchor.constraint(equalToConstant: 190)
        specificVersionWidthConstraint = specificVersionControl.widthAnchor.constraint(equalToConstant: 140)
        timeframeWidthConstraint = timeframeControl.widthAnchor.constraint(equalToConstant: 84)
        NSLayoutConstraint.activate([
            projectWidthConstraint!,
            versionModeWidthConstraint!,
            specificVersionWidthConstraint!,
            timeframeWidthConstraint!,
        ])

        DashboardMetricsVersionFilterMode.allCases.forEach { versionModeControl.addItem(withTitle: $0.title) }
        viewModel.onStateChange = { [weak self] in
            self?.syncFromViewModel()
        }
        rebuildProjectControl()
        rebuildVersionControls()
        syncTimeframeSelection()
        syncToolbarForProjectKind()
    }

    private func syncFromViewModel() {
        syncWindowTitle()
        rebuildProjectControl()
        rebuildVersionControls()
        syncTimeframeSelection()
        syncToolbarForProjectKind()
    }

    private func rebuildProjectControl() {
        isSelectingProject = true
        defer { isSelectingProject = false }
        projectControl.removeAllItems()
        for project in viewModel.projects {
            projectControl.addItem(withTitle: project.displayName)
            projectControl.lastItem?.representedObject = project.id
        }
        if let index = viewModel.projects.firstIndex(where: { $0.id == viewModel.selectedProjectID }) {
            projectControl.selectItem(at: index)
        }
    }

    private func rebuildVersionControls() {
        if let index = DashboardMetricsVersionFilterMode.allCases.firstIndex(of: viewModel.selectedVersionMode) {
            versionModeControl.selectItem(at: index)
        }

        specificVersionControl.removeAllItems()
        specificVersionControl.addItem(withTitle: "Versions")
        specificVersionControl.lastItem?.representedObject = nil
        for option in viewModel.versionOptions {
            specificVersionControl.addItem(withTitle: option.title)
            specificVersionControl.lastItem?.representedObject = option.id
        }
        if let selectedSpecificVersionID = viewModel.selectedSpecificVersionID,
           let index = specificVersionControl.itemArray.firstIndex(where: {
               ($0.representedObject as? String) == selectedSpecificVersionID
           })
        {
            specificVersionControl.selectItem(at: index)
        } else {
            specificVersionControl.selectItem(at: 0)
        }

        let showWorkerVersionControls = viewModel.selectedProject.kind == .worker
        versionModeControl.isEnabled = showWorkerVersionControls
        specificVersionControl.isEnabled = showWorkerVersionControls && viewModel.selectedVersionMode == .specific
        versionModeControl.alphaValue = showWorkerVersionControls ? 1 : 0
        specificVersionControl.alphaValue = (showWorkerVersionControls && viewModel.selectedVersionMode == .specific) ? 1 : 0
    }

    private func syncToolbarForProjectKind() {
        let isWorker = viewModel.selectedProject.kind == .worker
        versionModeControl.isHidden = !isWorker
        specificVersionControl.isHidden = !isWorker || viewModel.selectedVersionMode != .specific
        versionModeWidthConstraint?.constant = isWorker ? 190 : 0
        specificVersionWidthConstraint?.constant = (isWorker && viewModel.selectedVersionMode == .specific) ? 140 : 0
    }

    private func syncTimeframeSelection() {
        if let index = DashboardMetricsRangePreset.allCases.firstIndex(of: viewModel.selectedRangePreset) {
            timeframeControl.selectItem(at: index)
        }
    }

    @objc
    private func changeProject() {
        guard !isSelectingProject,
              let projectID = projectControl.selectedItem?.representedObject as? String
        else {
            return
        }
        viewModel.selectProject(projectID)
    }

    @objc
    private func changeVersionMode() {
        let selectedIndex = versionModeControl.indexOfSelectedItem
        guard DashboardMetricsVersionFilterMode.allCases.indices.contains(selectedIndex) else {
            return
        }
        viewModel.selectVersionMode(DashboardMetricsVersionFilterMode.allCases[selectedIndex])
    }

    @objc
    private func changeSpecificVersion() {
        guard let versionID = specificVersionControl.selectedItem?.representedObject as? String else {
            return
        }
        viewModel.selectSpecificVersion(versionID)
    }

    @objc
    private func changeTimeframe() {
        let selectedIndex = timeframeControl.indexOfSelectedItem
        guard DashboardMetricsRangePreset.allCases.indices.contains(selectedIndex) else {
            return
        }
        viewModel.selectRange(DashboardMetricsRangePreset.allCases[selectedIndex])
    }

    @objc
    private func refreshNow() {
        viewModel.reload()
    }
}

@MainActor
final class MetricsViewModel: ObservableObject {
    @Published var projects: [DashboardProject]
    @Published var selectedProjectID: String
    @Published var selectedRangePreset: DashboardMetricsRangePreset = .last24Hours
    @Published var selectedVersionMode: DashboardMetricsVersionFilterMode = .allDeployed
    @Published var selectedSpecificVersionID: String?
    @Published var snapshot: DashboardMetricsSnapshot?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var subrequestStatusFilter: DashboardSubrequestStatusFilter = .all
    @Published var subrequestSearch = ""
    @Published var subrequestPage = 0
    var onStateChange: (() -> Void)?

    private var sessionsByAccountID: [String: DashboardSession]
    private var loadTask: Task<Void, Never>?
    private var cachedVersionOptions: [DashboardWorkerVersionOption] = []
    private var cachedActiveVersionOptions: [DashboardWorkerVersionOption] = []

    init(project: DashboardProject, session: DashboardSession, projects: [DashboardProject], sessions: [DashboardSession]) {
        self.projects = projects.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        self.selectedProjectID = project.id
        self.sessionsByAccountID = Dictionary(uniqueKeysWithValues: sessions.compactMap {
            guard let accountID = $0.accountID else { return nil }
            return (accountID, $0)
        })
        if self.sessionsByAccountID[project.accountID] == nil {
            self.sessionsByAccountID[project.accountID] = session
        }
    }

    var selectedProject: DashboardProject {
        projects.first(where: { $0.id == selectedProjectID }) ?? projects[0]
    }

    private var selectedSession: DashboardSession? {
        sessionsByAccountID[selectedProject.accountID]
    }

    var versionOptions: [DashboardWorkerVersionOption] {
        cachedWorkerSnapshot?.versionOptions ?? cachedVersionOptions
    }

    var activeVersionOptions: [DashboardWorkerVersionOption] {
        cachedWorkerSnapshot?.activeVersionOptions ?? cachedActiveVersionOptions
    }

    private var cachedWorkerSnapshot: DashboardWorkerMetricsSnapshot? {
        guard case let .worker(snapshot)? = snapshot else { return nil }
        return snapshot
    }

    private var selectedVersionIDs: [String]? {
        guard selectedProject.kind == .worker else { return nil }
        switch selectedVersionMode {
        case .allDeployed:
            return nil
        case .activeDeployed:
            return activeVersionOptions.map(\.id)
        case .specific:
            return selectedSpecificVersionID.map { [$0] } ?? []
        }
    }

    var visibleSubrequests: [DashboardWorkerSubrequestRow] {
        guard let snapshot = cachedWorkerSnapshot else { return [] }
        let trimmedQuery = subrequestSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot.subrequests.filter { row in
            let matchesSearch = trimmedQuery.isEmpty || row.host.localizedCaseInsensitiveContains(trimmedQuery)
            guard matchesSearch else { return false }
            guard let key = subrequestStatusFilter.statusClassKey else { return true }
            return (row.countsByStatusClass[key] ?? 0) > 0
        }
    }

    var pagedSubrequests: [DashboardWorkerSubrequestRow] {
        let rows = visibleSubrequests
        let pageSize = 12
        let start = min(subrequestPage * pageSize, max(rows.count - 1, 0))
        let end = min(start + pageSize, rows.count)
        guard start < end else { return [] }
        return Array(rows[start ..< end])
    }

    var subrequestPageCount: Int {
        max(1, Int(ceil(Double(visibleSubrequests.count) / 12.0)))
    }

    func updateProjects(_ projects: [DashboardProject], sessions: [DashboardSession], selectedProjectID: String?) {
        self.projects = projects.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        self.sessionsByAccountID = Dictionary(uniqueKeysWithValues: sessions.compactMap {
            guard let accountID = $0.accountID else { return nil }
            return (accountID, $0)
        })

        if let selectedProjectID,
           self.projects.contains(where: { $0.id == selectedProjectID }) {
            self.selectedProjectID = selectedProjectID
        } else if !self.projects.contains(where: { $0.id == self.selectedProjectID }),
                  let first = self.projects.first {
            self.selectedProjectID = first.id
        }
        onStateChange?()
    }

    func selectProject(_ projectID: String) {
        guard selectedProjectID != projectID else { return }
        selectedProjectID = projectID
        selectedVersionMode = .allDeployed
        selectedSpecificVersionID = nil
        beginReload()
        onStateChange?()
        reload()
    }

    func selectRange(_ preset: DashboardMetricsRangePreset) {
        guard selectedRangePreset != preset else { return }
        selectedRangePreset = preset
        beginReload()
        onStateChange?()
        reload()
    }

    func selectVersionMode(_ mode: DashboardMetricsVersionFilterMode) {
        guard selectedProject.kind == .worker, selectedVersionMode != mode else { return }
        selectedVersionMode = mode
        if mode == .specific, selectedSpecificVersionID == nil {
            selectedSpecificVersionID = versionOptions.first?.id
        }
        beginReload()
        onStateChange?()
        reload()
    }

    func selectSpecificVersion(_ versionID: String) {
        guard selectedProject.kind == .worker,
              selectedSpecificVersionID != versionID || selectedVersionMode != .specific
        else {
            return
        }
        selectedVersionMode = .specific
        selectedSpecificVersionID = versionID
        beginReload()
        onStateChange?()
        reload()
    }

    func updateSubrequestSearch(_ value: String) {
        subrequestSearch = value
        subrequestPage = 0
    }

    func updateSubrequestStatus(_ filter: DashboardSubrequestStatusFilter) {
        subrequestStatusFilter = filter
        subrequestPage = 0
    }

    func previousSubrequestPage() {
        subrequestPage = max(0, subrequestPage - 1)
    }

    func nextSubrequestPage() {
        subrequestPage = min(subrequestPageCount - 1, subrequestPage + 1)
    }

    func reloadIfNeeded() {
        guard snapshot == nil, !isLoading else { return }
        reload()
    }

    func reload() {
        guard let session = selectedSession else { return }
        loadTask?.cancel()
        beginReload()
        onStateChange?()
        let project = selectedProject
        let timeframe = selectedRangePreset.timeframe()
        let selectedVersionIDs = selectedVersionIDs

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = DashboardAPIClient(session: session)
                let nextSnapshot: DashboardMetricsSnapshot
                switch project.kind {
                case .worker:
                    let workerSnapshot = try await client.fetchWorkerMetrics(
                        accountID: project.accountID,
                        workerName: project.name,
                        timeframe: timeframe,
                        selectedVersionIDs: selectedVersionIDs
                    )
                    self.cachedVersionOptions = workerSnapshot.versionOptions
                    self.cachedActiveVersionOptions = workerSnapshot.activeVersionOptions
                    if self.selectedVersionMode == .specific,
                       let selectedSpecificVersionID = self.selectedSpecificVersionID,
                       !workerSnapshot.versionOptions.contains(where: { $0.id == selectedSpecificVersionID }) {
                        self.selectedSpecificVersionID = workerSnapshot.versionOptions.first?.id
                    }
                    nextSnapshot = .worker(workerSnapshot)
                case .page:
                    let pageSnapshot = try await client.fetchPageMetrics(
                        accountID: project.accountID,
                        projectName: project.name,
                        timeframe: timeframe
                    )
                    nextSnapshot = .page(pageSnapshot)
                }
                guard !Task.isCancelled else { return }
                self.snapshot = nextSnapshot
                self.subrequestPage = 0
                self.isLoading = false
                self.onStateChange?()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.isLoading = false
                self.onStateChange?()
            }
        }
    }

    private func beginReload() {
        snapshot = nil
        isLoading = true
        errorMessage = nil
        subrequestPage = 0
    }
}
