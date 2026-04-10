import AppKit
import Charts
import Foundation
import SwiftUI

@MainActor
final class ObservabilityWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSToolbarDelegate {
    var onClose: (() -> Void)?

    private let project: DashboardProject
    private let session: DashboardSession
    private let streamingSession = URLSession(configuration: .ephemeral)

    private let viewControl = NSSegmentedControl(labels: DashboardObservabilityView.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let liveButton = NSButton(title: "Live", target: nil, action: nil)
    private let timeframeControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fieldsButton = NSButton(title: "Fields", target: nil, action: nil)
    private let refreshButton = NSButton()
    private let customRangeStack = NSStackView()
    private let fromDatePicker = NSDatePicker()
    private let toDatePicker = NSDatePicker()
    private let statusLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let chartContainer = NSView()
    private let chartHostingView = NSHostingView(rootView: ObservabilityChartView(points: []))
    private var chartHeightConstraint: NSLayoutConstraint?
    private let toolbar = NSToolbar(identifier: "observability.window.toolbar")

    private var availableFields: [DashboardObservabilityField] = []
    private var selectedFieldKeys: [String] = []
    private var rows: [DashboardObservabilityRow] = []
    private var chartPoints: [DashboardObservabilityChartPoint] = []
    private var currentView: DashboardObservabilityView = .events
    private var currentPreset: DashboardObservabilityRangePreset = .lastHour
    private var liveTailTask: Task<Void, Never>?
    private var queryTask: Task<Void, Never>?
    private var liveTailSocket: URLSessionWebSocketTask?
    private var heartbeatTimer: Timer?
    private var isLive = false

    init(project: DashboardProject, session: DashboardSession) {
        self.project = project
        self.session = session

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .unifiedTitleAndToolbar],
            backing: .buffered,
            defer: false
        )
        window.title = project.displayName
        window.minSize = NSSize(width: 760, height: 420)
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.toolbarStyle = .unified
        toolbar.displayMode = .default
        toolbar.allowsUserCustomization = false
        super.init(window: window)
        toolbar.delegate = self
        window.toolbar = toolbar
        window.delegate = self
        buildUI()
        configure()
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
        if isLive {
            return
        }
        reloadHistoricalData()
    }

    func windowWillClose(_ notification: Notification) {
        stopLiveMode()
        queryTask?.cancel()
        onClose?()
    }

    private func buildUI() {
        guard let window,
              let contentView = window.contentView,
              let contentLayoutGuide = window.contentLayoutGuide as? NSLayoutGuide
        else {
            return
        }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false

        customRangeStack.orientation = .horizontal
        customRangeStack.alignment = .centerY
        customRangeStack.spacing = 8
        customRangeStack.translatesAutoresizingMaskIntoConstraints = false

        let fromLabel = NSTextField(labelWithString: "From")
        let toLabel = NSTextField(labelWithString: "To")
        fromLabel.textColor = .secondaryLabelColor
        toLabel.textColor = .secondaryLabelColor
        customRangeStack.addArrangedSubview(fromLabel)
        customRangeStack.addArrangedSubview(fromDatePicker)
        customRangeStack.addArrangedSubview(toLabel)
        customRangeStack.addArrangedSubview(toDatePicker)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = tableView

        chartContainer.translatesAutoresizingMaskIntoConstraints = false
        chartHostingView.translatesAutoresizingMaskIntoConstraints = false
        chartContainer.addSubview(chartHostingView)

        root.addArrangedSubview(customRangeStack)
        root.addArrangedSubview(statusLabel)
        root.addArrangedSubview(scrollView)
        root.addArrangedSubview(chartContainer)
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
            chartContainer.widthAnchor.constraint(equalTo: root.widthAnchor),

            chartHostingView.leadingAnchor.constraint(equalTo: chartContainer.leadingAnchor),
            chartHostingView.trailingAnchor.constraint(equalTo: chartContainer.trailingAnchor),
            chartHostingView.topAnchor.constraint(equalTo: chartContainer.topAnchor),
            chartHostingView.bottomAnchor.constraint(equalTo: chartContainer.bottomAnchor),

            fromDatePicker.widthAnchor.constraint(equalToConstant: 180),
            toDatePicker.widthAnchor.constraint(equalToConstant: 180),
        ])
        let chartHeightConstraint = chartContainer.heightAnchor.constraint(equalToConstant: 180)
        chartHeightConstraint.isActive = true
        self.chartHeightConstraint = chartHeightConstraint
    }

    private enum ToolbarItemID {
        static let views = NSToolbarItem.Identifier("observability.views")
        static let live = NSToolbarItem.Identifier("observability.live")
        static let timeframe = NSToolbarItem.Identifier("observability.timeframe")
        static let fields = NSToolbarItem.Identifier("observability.fields")
        static let refresh = NSToolbarItem.Identifier("observability.refresh")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarItemID.views,
            ToolbarItemID.live,
            ToolbarItemID.timeframe,
            ToolbarItemID.fields,
            ToolbarItemID.refresh,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarItemID.views,
            ToolbarItemID.live,
            ToolbarItemID.timeframe,
            ToolbarItemID.fields,
            ToolbarItemID.refresh,
            .flexibleSpace,
            .space,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarItemID.views:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Views"
            item.paletteLabel = "Views"
            item.view = viewControl
            return item
        case ToolbarItemID.live:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Live"
            item.paletteLabel = "Live"
            item.view = liveButton
            return item
        case ToolbarItemID.timeframe:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Timeframe"
            item.paletteLabel = "Timeframe"
            item.view = timeframeControl
            return item
        case ToolbarItemID.fields:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Fields"
            item.paletteLabel = "Fields"
            item.view = fieldsButton
            return item
        case ToolbarItemID.refresh:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Refresh"
            item.paletteLabel = "Refresh"
            item.view = refreshButton
            return item
        default:
            return nil
        }
    }

    private func configure() {
        viewControl.target = self
        viewControl.action = #selector(changeView)
        viewControl.selectedSegment = DashboardObservabilityView.allCases.firstIndex(of: currentView) ?? 0
        if let cell = viewControl.cell as? NSSegmentedCell {
            for (index, view) in DashboardObservabilityView.allCases.enumerated() {
                cell.setToolTip(view.title, forSegment: index)
            }
        }

        liveButton.setButtonType(.toggle)
        liveButton.bezelStyle = .rounded
        liveButton.target = self
        liveButton.action = #selector(toggleLive)
        syncLiveButton()

        DashboardObservabilityRangePreset.allCases.forEach { timeframeControl.addItem(withTitle: $0.title) }
        timeframeControl.target = self
        timeframeControl.action = #selector(changeTimeframePreset)
        timeframeControl.selectItem(withTitle: currentPreset.title)
        timeframeControl.toolTip = "Timeframe"

        fieldsButton.bezelStyle = .rounded
        fieldsButton.target = self
        fieldsButton.action = #selector(showFieldsMenu)
        fieldsButton.toolTip = "Fields"

        refreshButton.isBordered = false
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.contentTintColor = .secondaryLabelColor
        refreshButton.target = self
        refreshButton.action = #selector(refreshNow)
        refreshButton.toolTip = "Refresh"

        viewControl.translatesAutoresizingMaskIntoConstraints = false
        liveButton.translatesAutoresizingMaskIntoConstraints = false
        timeframeControl.translatesAutoresizingMaskIntoConstraints = false
        fieldsButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            viewControl.widthAnchor.constraint(equalToConstant: 280),
            liveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
            timeframeControl.widthAnchor.constraint(equalToConstant: 84),
            fieldsButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 68),
            refreshButton.widthAnchor.constraint(equalToConstant: 24),
            refreshButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        [fromDatePicker, toDatePicker].forEach { picker in
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.yearMonthDay, .hourMinute]
            picker.target = self
            picker.action = #selector(changeCustomTimeframe)
        }
        fromDatePicker.toolTip = "From"
        toDatePicker.toolTip = "To"
        let now = Date()
        fromDatePicker.dateValue = now.addingTimeInterval(-(DashboardObservabilityRangePreset.lastHour.interval ?? 3600))
        toDatePicker.dateValue = now

        customRangeStack.isHidden = true

        tableView.delegate = self
        tableView.dataSource = self
        tableView.style = .inset
        tableView.rowHeight = 24
        tableView.intercellSpacing = .zero
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.focusRingType = .none
        tableView.allowsMultipleSelection = false
        tableView.headerView = NSTableHeaderView()
        rebuildColumns()
        updateModeUI()
        updateStatus("Loading…")
    }

    @objc
    private func changeView() {
        currentView = DashboardObservabilityView.allCases[viewControl.selectedSegment]
        if isLive {
            stopLiveMode()
        }
        updateModeUI()
        reloadHistoricalData()
    }

    @objc
    private func toggleLive() {
        if liveButton.state == .on {
            startLiveMode()
            return
        }

        stopLiveMode()
        updateStatus("Paused • \(rows.count) rows")
    }

    @objc
    private func changeTimeframePreset() {
        let selectedIndex = timeframeControl.indexOfSelectedItem
        guard DashboardObservabilityRangePreset.allCases.indices.contains(selectedIndex) else {
            return
        }
        currentPreset = DashboardObservabilityRangePreset.allCases[selectedIndex]
        customRangeStack.isHidden = currentPreset != .custom
        if isLive {
            stopLiveMode()
        }
        reloadHistoricalData()
    }

    @objc
    private func changeCustomTimeframe() {
        guard currentPreset == .custom else {
            return
        }
        if isLive {
            stopLiveMode()
        }
        reloadHistoricalData()
    }

    @objc
    private func refreshNow() {
        if isLive {
            stopLiveMode()
        }
        reloadHistoricalData()
    }

    @objc
    private func showFieldsMenu() {
        let menu = NSMenu()
        for field in availableFields.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
            let item = NSMenuItem(
                title: displayFieldName(field.key),
                action: #selector(toggleFieldSelection(_:)),
                keyEquivalent: ""
            )
            item.state = selectedFieldKeys.contains(field.key) ? .on : .off
            item.representedObject = field.key
            item.target = self
            menu.addItem(item)
        }

        if !menu.items.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }

        let resetItem = NSMenuItem(title: "Reset Fields", action: #selector(resetFieldSelection), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        let point = NSPoint(x: 0, y: fieldsButton.bounds.height + 4)
        menu.popUp(positioning: nil, at: point, in: fieldsButton)
    }

    @objc
    private func toggleFieldSelection(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else {
            return
        }
        if let index = selectedFieldKeys.firstIndex(of: key) {
            if selectedFieldKeys.count == 1 {
                return
            }
            selectedFieldKeys.remove(at: index)
        } else {
            selectedFieldKeys.append(key)
        }
        rebuildColumns()
        tableView.reloadData()
    }

    @objc
    private func resetFieldSelection() {
        selectedFieldKeys = defaultFieldKeys(from: availableFields)
        rebuildColumns()
        tableView.reloadData()
    }

    private func reloadHistoricalData() {
        guard let timeframe = currentTimeframe() else {
            updateStatus("Invalid range")
            return
        }

        queryTask?.cancel()
        queryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = DashboardAPIClient(session: self.session)
                let fields = try await client.listObservabilityFields(
                    accountID: self.project.accountID,
                    workerName: self.project.name,
                    timeframe: timeframe
                )
                let result = try await client.queryObservability(
                    accountID: self.project.accountID,
                    workerName: self.project.name,
                    view: self.currentView,
                    timeframe: timeframe
                )
                await MainActor.run {
                    self.availableFields = fields.isEmpty ? result.fields : fields
                    self.syncSelectedFields()
                    self.rows = result.rows.sorted { lhs, rhs in
                        (lhs.timestamp ?? .distantPast) > (rhs.timestamp ?? .distantPast)
                    }
                    self.chartPoints = result.chartPoints
                    self.rebuildColumns()
                    self.tableView.reloadData()
                    self.chartHostingView.rootView = ObservabilityChartView(points: self.chartPoints)
                    self.updateModeUI()
                    self.updateStatus(self.statusText(rows: self.rows.count, points: self.chartPoints.count))
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    self.updateStatus(error.localizedDescription)
                }
            }
        }
    }

    private func startLiveMode() {
        guard currentView.supportsLive else {
            syncLiveButton()
            return
        }
        currentView = .events
        viewControl.selectedSegment = DashboardObservabilityView.allCases.firstIndex(of: .events) ?? 0
        rows.removeAll(keepingCapacity: true)
        chartPoints.removeAll(keepingCapacity: true)
        tableView.reloadData()
        stopLiveMode()
        isLive = true
        syncLiveButton()
        updateModeUI()
        updateStatus("Connecting live tail…")

        liveTailTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = DashboardAPIClient(session: self.session)
                let fields = try await client.listObservabilityFields(
                    accountID: self.project.accountID,
                    workerName: self.project.name,
                    timeframe: DashboardObservabilityTimeframe(from: Date().addingTimeInterval(-3600), to: Date())
                )
                let liveTail = try await client.createObservabilityLiveTailSession(
                    accountID: self.project.accountID,
                    workerName: self.project.name
                )
                await MainActor.run {
                    self.availableFields = fields
                    self.syncSelectedFields()
                    self.rebuildColumns()
                    self.chartHostingView.rootView = ObservabilityChartView(points: [])
                    self.updateModeUI()
                }
                let socket = self.streamingSession.webSocketTask(with: liveTail.socketURL)
                socket.resume()
                await MainActor.run {
                    self.liveTailSocket = socket
                    self.startHeartbeat()
                    self.updateStatus("Live • waiting for events")
                }
                await self.receiveLiveMessages(from: socket)
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    self.stopLiveMode()
                    self.updateStatus(error.localizedDescription)
                }
            }
        }
    }

    private func stopLiveMode() {
        isLive = false
        syncLiveButton()
        liveTailTask?.cancel()
        liveTailTask = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        liveTailSocket?.cancel(with: .goingAway, reason: nil)
        liveTailSocket = nil
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isLive else { return }
                do {
                    try await DashboardAPIClient(session: self.session).sendObservabilityLiveTailHeartbeat(
                        accountID: self.project.accountID,
                        workerName: self.project.name
                    )
                } catch {
                    self.updateStatus(error.localizedDescription)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func receiveLiveMessages(from socket: URLSessionWebSocketTask) async {
        while isLive, !Task.isCancelled {
            do {
                let message = try await socket.receive()
                let nextRows = try parseLiveRows(from: message)
                await MainActor.run {
                    self.appendLiveRows(nextRows)
                }
            } catch is CancellationError {
                return
            } catch {
                if !isLive || Task.isCancelled {
                    return
                }
                await MainActor.run {
                    self.stopLiveMode()
                    self.updateStatus(error.localizedDescription)
                }
                return
            }
        }
    }

    private func parseLiveRows(from message: URLSessionWebSocketTask.Message) throws -> [DashboardObservabilityRow] {
        let data: Data
        switch message {
        case let .data(value):
            data = value
        case let .string(value):
            guard let encoded = value.data(using: .utf8) else {
                return []
            }
            data = encoded
        @unknown default:
            return []
        }

        let payload = try JSONSerialization.jsonObject(with: data)
        return extractLiveRowPayloads(payload).enumerated().map { index, row in
            let flattened = flattenLiveRow(row)
            let timestamp = (flattened["timestamp"] ?? flattened["datetime"] ?? flattened["time"]).flatMap(parseLiveTimestamp)
            return DashboardObservabilityRow(
                id: flattened["$metadata.id"] ?? flattened["trace.id"] ?? flattened["span.id"] ?? "live-\(Date().timeIntervalSince1970)-\(index)",
                timestamp: timestamp,
                values: flattened
            )
        }
    }

    private func extractLiveRowPayloads(_ payload: Any) -> [[String: Any]] {
        if let rows = payload as? [[String: Any]] {
            return rows
        }
        if let values = payload as? [Any] {
            return values.compactMap { $0 as? [String: Any] }
        }
        guard let dictionary = payload as? [String: Any] else {
            return []
        }

        for key in ["events", "logs", "entries", "results", "data"] {
            if let rows = dictionary[key] as? [[String: Any]], !rows.isEmpty {
                return rows
            }
        }

        return [dictionary]
    }

    private func flattenLiveRow(_ row: [String: Any]) -> [String: String] {
        var values: [String: String] = [:]
        flattenLiveValue(row, prefix: nil, into: &values)
        return values
    }

    private func flattenLiveValue(_ value: Any, prefix: String?, into result: inout [String: String]) {
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() {
                let nextPrefix = prefix.map { "\($0).\(key)" } ?? key
                flattenLiveValue(dictionary[key] as Any, prefix: nextPrefix, into: &result)
            }
            return
        }

        if let array = value as? [Any] {
            let scalarValues = array.compactMap { liveStringValue($0) }
            if let prefix, !scalarValues.isEmpty {
                result[prefix] = scalarValues.joined(separator: ", ")
            } else if let prefix,
                      let data = try? JSONSerialization.data(withJSONObject: array),
                      let string = String(data: data, encoding: .utf8)
            {
                result[prefix] = string
            }
            return
        }

        guard let prefix, let string = liveStringValue(value) else {
            return
        }
        result[prefix] = string
    }

    private func liveStringValue(_ value: Any) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let bool as Bool:
            return bool ? "true" : "false"
        case _ as NSNull:
            return nil
        default:
            return "\(value)"
        }
    }

    private func appendLiveRows(_ nextRows: [DashboardObservabilityRow]) {
        guard !nextRows.isEmpty else {
            return
        }
        rows.insert(contentsOf: nextRows.reversed(), at: 0)
        if rows.count > 500 {
            rows = Array(rows.prefix(500))
        }
        tableView.reloadData()
        updateStatus("Live • \(rows.count) rows")
    }

    private func currentTimeframe() -> DashboardObservabilityTimeframe? {
        if currentPreset == .custom {
            let from = fromDatePicker.dateValue
            let to = toDatePicker.dateValue
            guard from < to else {
                return nil
            }
            return DashboardObservabilityTimeframe(from: from, to: to)
        }

        let now = Date()
        guard let interval = currentPreset.interval else {
            return nil
        }
        return DashboardObservabilityTimeframe(from: now.addingTimeInterval(-interval), to: now)
    }

    private func syncSelectedFields() {
        if availableFields.isEmpty {
            selectedFieldKeys = ["timestamp", "$metadata.level", "$metadata.message"]
            return
        }

        if selectedFieldKeys.isEmpty {
            selectedFieldKeys = defaultFieldKeys(from: availableFields)
            return
        }

        let availableKeys = Set(availableFields.map(\.key))
        selectedFieldKeys = selectedFieldKeys.filter { availableKeys.contains($0) }
        if selectedFieldKeys.isEmpty {
            selectedFieldKeys = defaultFieldKeys(from: availableFields)
        }
    }

    private func defaultFieldKeys(from fields: [DashboardObservabilityField]) -> [String] {
        let keys = Set(fields.map(\.key))
        let preferred = [
            "timestamp",
            "$metadata.level",
            "$metadata.message",
            "$metadata.service",
            "dataset",
            "source",
        ].filter { keys.contains($0) }

        if !preferred.isEmpty {
            return preferred
        }

        return Array(fields.prefix(4).map(\.key))
    }

    private func rebuildColumns() {
        while !tableView.tableColumns.isEmpty {
            tableView.removeTableColumn(tableView.tableColumns[0])
        }

        let fields = selectedFieldKeys.isEmpty ? ["timestamp", "$metadata.message"] : selectedFieldKeys
        for field in fields {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(field))
            column.title = displayFieldName(field)
            column.resizingMask = .autoresizingMask
            column.width = preferredWidth(for: field)
            tableView.addTableColumn(column)
        }
    }

    private func preferredWidth(for field: String) -> CGFloat {
        switch field {
        case "timestamp":
            180
        case "$metadata.message":
            460
        default:
            160
        }
    }

    private func updateStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    private func syncLiveButton() {
        liveButton.state = isLive ? .on : .off
        liveButton.title = isLive ? "Pause" : "Live"
        liveButton.isEnabled = currentView.supportsLive
        liveButton.toolTip = isLive ? "Pause live tail" : "Start live tail"
    }

    private func updateModeUI() {
        fieldsButton.isHidden = !currentView.showsFields
        let showsChart = shouldShowChart
        scrollView.isHidden = currentView == .visualizations
        chartContainer.isHidden = !showsChart
        chartHeightConstraint?.constant = currentView == .visualizations ? 320 : 180
        syncLiveButton()
    }

    private func statusText(rows: Int, points: Int) -> String {
        if currentView == .visualizations {
            return "\(currentView.title) • \(points) points"
        }
        return "\(currentView.title) • \(rows) rows"
    }

    private var shouldShowChart: Bool {
        if currentView == .visualizations {
            return true
        }
        return currentView.includesChart && !chartPoints.isEmpty && !isLive
    }

    private func displayFieldName(_ field: String) -> String {
        field
            .replacingOccurrences(of: "$metadata.", with: "")
            .replacingOccurrences(of: "$workers.", with: "")
    }

    private func parseLiveTimestamp(_ value: String) -> Date? {
        if let doubleValue = Double(value), doubleValue > 1_000_000 {
            return Date(timeIntervalSince1970: doubleValue / 1000)
        }
        return ISO8601DateFormatter().date(from: value)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row),
              let tableColumn
        else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("observability.\(tableColumn.identifier.rawValue)")
        let view = (tableView.makeView(withIdentifier: identifier, owner: self) as? ObservabilityCellView) ?? ObservabilityCellView()
        view.identifier = identifier
        let key = tableColumn.identifier.rawValue
        view.configure(
            text: rows[row].values[key] ?? "",
            color: colorForCell(row: rows[row], key: key)
        )
        return view
    }

    private func colorForCell(row: DashboardObservabilityRow, key: String) -> NSColor? {
        let level = row.values["$metadata.level"] ?? row.values["level"] ?? row.values["severity"]
        let color = colorForLevel(level)
        if key == "$metadata.level" || key == "level" || key == "severity" {
            return color
        }
        return nil
    }

    private func colorForLevel(_ level: String?) -> NSColor? {
        switch level?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "error", "fatal", "critical":
            .systemRed
        case "warn", "warning":
            .systemOrange
        case "info":
            .secondaryLabelColor
        case "debug", "trace":
            .tertiaryLabelColor
        default:
            nil
        }
    }
}

private struct ObservabilityChartView: View {
    let points: [DashboardObservabilityChartPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if points.isEmpty {
                Text("No data")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if points.contains(where: hasMultipleSegments) {
                stackedBarChart
            } else if points.contains(where: { $0.date != nil }) {
                Chart(points) { point in
                    if let date = point.date {
                        LineMark(
                            x: .value("Time", date),
                            y: .value("Count", point.value)
                        )
                        .interpolationMethod(.catmullRom)

                        AreaMark(
                            x: .value("Time", date),
                            y: .value("Count", point.value)
                        )
                        .foregroundStyle(.blue.opacity(0.12))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
            } else {
                Chart(points) { point in
                    BarMark(
                        x: .value("Group", point.label),
                        y: .value("Count", point.value)
                    )
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.textBackgroundColor))
    }

    private var stackedBarChart: some View {
        Chart(points) { point in
            ForEach(point.segments) { segment in
                if let date = point.date {
                    BarMark(
                        x: .value("Time", date),
                        y: .value("Count", segment.value)
                    )
                    .foregroundStyle(by: .value("Type", segment.kind.title))
                } else {
                    BarMark(
                        x: .value("Group", point.label),
                        y: .value("Count", segment.value)
                    )
                    .foregroundStyle(by: .value("Type", segment.kind.title))
                }
            }
        }
        .chartForegroundStyleScale([
            DashboardObservabilityChartSegment.Kind.info.title: Color.blue,
            DashboardObservabilityChartSegment.Kind.error.title: Color.red,
        ])
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading)
        }
    }

    private func hasMultipleSegments(_ point: DashboardObservabilityChartPoint) -> Bool {
        point.segments.count > 1
    }
}

@MainActor
private final class ObservabilityCellView: NSTableCellView {
    private let textLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        textLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textLabel)

        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func configure(text: String, color: NSColor?) {
        textLabel.stringValue = text
        textLabel.toolTip = text
        textLabel.textColor = color ?? .labelColor
    }
}
