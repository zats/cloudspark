import AppKit
import Foundation
import SwiftUI

@MainActor
final class MetricsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    var onClose: (() -> Void)?

    private let viewModel: WorkerMetricsViewModel
    private let workerControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let versionModeControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let specificVersionControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let timeframeControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let toolbar = NSToolbar(identifier: "metrics.window.toolbar")
    private var isSelectingWorker = false

    init(project: DashboardProject, session: DashboardSession, workers: [DashboardProject], sessions: [DashboardSession]) {
        self.viewModel = WorkerMetricsViewModel(project: project, session: session, workers: workers, sessions: sessions)

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

        let hostingView = NSHostingView(rootView: WorkerMetricsWindowView(viewModel: viewModel))
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

    func updateWorkers(_ workers: [DashboardProject], sessions: [DashboardSession], selectedProjectID: String? = nil) {
        viewModel.updateWorkers(workers, sessions: sessions, selectedProjectID: selectedProjectID)
        rebuildWorkerControl()
        rebuildVersionControls()
        syncTimeframeSelection()
        syncWindowTitle()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    private func syncWindowTitle() {
        window?.title = viewModel.selectedProject.displayName
    }

    private enum ToolbarItemID {
        static let worker = NSToolbarItem.Identifier("metrics.worker")
        static let versionMode = NSToolbarItem.Identifier("metrics.version-mode")
        static let specificVersion = NSToolbarItem.Identifier("metrics.specific-version")
        static let timeframe = NSToolbarItem.Identifier("metrics.timeframe")
        static let refresh = NSToolbarItem.Identifier("metrics.refresh")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarItemID.worker,
            ToolbarItemID.versionMode,
            ToolbarItemID.specificVersion,
            ToolbarItemID.timeframe,
            .space,
            ToolbarItemID.refresh,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarItemID.worker,
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
        case ToolbarItemID.worker:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Worker"
            item.paletteLabel = "Worker"
            item.view = workerControl
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
        workerControl.target = self
        workerControl.action = #selector(changeWorker)
        workerControl.toolTip = "Worker"

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

        NSLayoutConstraint.activate([
            workerControl.widthAnchor.constraint(equalToConstant: 220),
            versionModeControl.widthAnchor.constraint(equalToConstant: 190),
            specificVersionControl.widthAnchor.constraint(equalToConstant: 140),
            timeframeControl.widthAnchor.constraint(equalToConstant: 84),
        ])

        DashboardMetricsVersionFilterMode.allCases.forEach { versionModeControl.addItem(withTitle: $0.title) }
        viewModel.onStateChange = { [weak self] in
            self?.syncFromViewModel()
        }
        rebuildWorkerControl()
        rebuildVersionControls()
        syncTimeframeSelection()
    }

    private func syncFromViewModel() {
        syncWindowTitle()
        rebuildWorkerControl()
        rebuildVersionControls()
        syncTimeframeSelection()
    }

    private func rebuildWorkerControl() {
        isSelectingWorker = true
        defer { isSelectingWorker = false }
        workerControl.removeAllItems()
        for worker in viewModel.workers {
            workerControl.addItem(withTitle: worker.displayName)
            workerControl.lastItem?.representedObject = worker.id
        }
        if let index = viewModel.workers.firstIndex(where: { $0.id == viewModel.selectedWorkerID }) {
            workerControl.selectItem(at: index)
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
        specificVersionControl.isEnabled = viewModel.selectedVersionMode == .specific
        specificVersionControl.alphaValue = viewModel.selectedVersionMode == .specific ? 1 : 0.55
    }

    private func syncTimeframeSelection() {
        if let index = DashboardMetricsRangePreset.allCases.firstIndex(of: viewModel.selectedRangePreset) {
            timeframeControl.selectItem(at: index)
        }
    }

    @objc
    private func changeWorker() {
        guard !isSelectingWorker,
              let projectID = workerControl.selectedItem?.representedObject as? String
        else {
            return
        }
        viewModel.selectWorker(projectID)
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
final class WorkerMetricsViewModel: ObservableObject {
    @Published var workers: [DashboardProject]
    @Published var selectedWorkerID: String
    @Published var selectedRangePreset: DashboardMetricsRangePreset = .last24Hours
    @Published var selectedVersionMode: DashboardMetricsVersionFilterMode = .allDeployed
    @Published var selectedSpecificVersionID: String?
    @Published var snapshot: DashboardWorkerMetricsSnapshot?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var subrequestStatusFilter: DashboardSubrequestStatusFilter = .all
    @Published var subrequestSearch = ""
    @Published var subrequestPage = 0
    var onStateChange: (() -> Void)?

    private var sessionsByAccountID: [String: DashboardSession]
    private var loadTask: Task<Void, Never>?

    init(project: DashboardProject, session: DashboardSession, workers: [DashboardProject], sessions: [DashboardSession]) {
        self.workers = workers.filter { $0.kind == .worker }
        self.selectedWorkerID = project.id
        self.sessionsByAccountID = Dictionary(uniqueKeysWithValues: sessions.compactMap {
            guard let accountID = $0.accountID else { return nil }
            return (accountID, $0)
        })
        if self.sessionsByAccountID[project.accountID] == nil {
            self.sessionsByAccountID[project.accountID] = session
        }
    }

    var selectedProject: DashboardProject {
        workers.first(where: { $0.id == selectedWorkerID }) ?? workers[0]
    }

    private var selectedSession: DashboardSession? {
        sessionsByAccountID[selectedProject.accountID]
    }

    var versionOptions: [DashboardWorkerVersionOption] {
        snapshot?.versionOptions ?? []
    }

    var activeVersionOptions: [DashboardWorkerVersionOption] {
        snapshot?.activeVersionOptions ?? []
    }

    private var selectedVersionIDs: [String]? {
        switch selectedVersionMode {
        case .allDeployed:
            nil
        case .activeDeployed:
            activeVersionOptions.map(\.id)
        case .specific:
            selectedSpecificVersionID.map { [$0] } ?? []
        }
    }

    var visibleSubrequests: [DashboardWorkerSubrequestRow] {
        guard let snapshot else { return [] }
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

    func updateWorkers(_ workers: [DashboardProject], sessions: [DashboardSession], selectedProjectID: String?) {
        self.workers = workers.filter { $0.kind == .worker }
        self.sessionsByAccountID = Dictionary(uniqueKeysWithValues: sessions.compactMap {
            guard let accountID = $0.accountID else { return nil }
            return (accountID, $0)
        })

        if let selectedProjectID,
           self.workers.contains(where: { $0.id == selectedProjectID }) {
            selectedWorkerID = selectedProjectID
        } else if !self.workers.contains(where: { $0.id == selectedWorkerID }),
                  let first = self.workers.first {
            selectedWorkerID = first.id
        }
        onStateChange?()
    }

    func selectWorker(_ workerID: String) {
        guard selectedWorkerID != workerID else { return }
        selectedWorkerID = workerID
        selectedVersionMode = .allDeployed
        selectedSpecificVersionID = nil
        snapshot = nil
        onStateChange?()
        reload()
    }

    func selectRange(_ preset: DashboardMetricsRangePreset) {
        guard selectedRangePreset != preset else { return }
        selectedRangePreset = preset
        onStateChange?()
        reload()
    }

    func selectVersionMode(_ mode: DashboardMetricsVersionFilterMode) {
        guard selectedVersionMode != mode else { return }
        selectedVersionMode = mode
        if mode == .specific, selectedSpecificVersionID == nil {
            selectedSpecificVersionID = versionOptions.first?.id
        }
        onStateChange?()
        reload()
    }

    func selectSpecificVersion(_ versionID: String) {
        guard selectedSpecificVersionID != versionID || selectedVersionMode != .specific else { return }
        selectedVersionMode = .specific
        selectedSpecificVersionID = versionID
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
        isLoading = true
        errorMessage = nil
        onStateChange?()
        let worker = selectedProject
        let timeframe = selectedRangePreset.timeframe()
        let selectedVersionIDs = selectedVersionIDs

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = DashboardAPIClient(session: session)
                let snapshot = try await client.fetchWorkerMetrics(
                    accountID: worker.accountID,
                    workerName: worker.name,
                    timeframe: timeframe,
                    selectedVersionIDs: selectedVersionIDs
                )
                guard !Task.isCancelled else { return }
                self.snapshot = snapshot
                if self.selectedVersionMode == .specific,
                   let selectedSpecificVersionID = self.selectedSpecificVersionID,
                   !snapshot.versionOptions.contains(where: { $0.id == selectedSpecificVersionID }) {
                    self.selectedSpecificVersionID = snapshot.versionOptions.first?.id
                }
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
}
