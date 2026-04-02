import AppKit

@MainActor
final class SettingsWindowController: NSWindowController {
    enum Tab {
        case general
        case accounts
    }

    private let tabsController = SettingsTabsViewController()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.toolbarStyle = .preference
        super.init(window: window)
        window.contentViewController = tabsController
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func show(
        sessions: [DashboardSession],
        selectedTab: Tab = .general,
        onLogin: @escaping () -> Void,
        onLogout: @escaping (DashboardSession) -> Void,
        onSetLaunchAtLogin: @escaping (Bool) -> Void,
        onSetNotificationsEnabled: @escaping (Bool) -> Void,
        onSetRefreshInterval: @escaping (AppPreferences.RefreshInterval) -> Void
    ) {
        tabsController.update(
            sessions: sessions,
            isLaunchAtLoginEnabled: LaunchAtLoginManager.isEnabled,
            areNotificationsEnabled: AppPreferences.notificationsEnabled,
            refreshInterval: AppPreferences.refreshInterval
        )
        tabsController.onLogin = onLogin
        tabsController.onLogout = onLogout
        tabsController.onSetLaunchAtLogin = onSetLaunchAtLogin
        tabsController.onSetNotificationsEnabled = onSetNotificationsEnabled
        tabsController.onSetRefreshInterval = onSetRefreshInterval
        tabsController.select(tab: selectedTab)
        NSApplication.shared.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.center()
        window?.orderFrontRegardless()
        window?.makeKey()
    }

    func refresh(sessions: [DashboardSession]) {
        tabsController.update(
            sessions: sessions,
            isLaunchAtLoginEnabled: LaunchAtLoginManager.isEnabled,
            areNotificationsEnabled: AppPreferences.notificationsEnabled,
            refreshInterval: AppPreferences.refreshInterval
        )
    }

    var hostWindow: NSWindow? {
        window
    }
}

@MainActor
private final class SettingsTabsViewController: NSTabViewController {
    let generalViewController = GeneralSettingsViewController()
    let accountsViewController = AccountsSettingsViewController()

    var onLogin: (() -> Void)? {
        didSet { accountsViewController.onLogin = onLogin }
    }
    var onLogout: ((DashboardSession) -> Void)? {
        didSet { accountsViewController.onLogout = onLogout }
    }
    var onSetLaunchAtLogin: ((Bool) -> Void)? {
        didSet { generalViewController.onSetLaunchAtLogin = onSetLaunchAtLogin }
    }
    var onSetNotificationsEnabled: ((Bool) -> Void)? {
        didSet { generalViewController.onSetNotificationsEnabled = onSetNotificationsEnabled }
    }
    var onSetRefreshInterval: ((AppPreferences.RefreshInterval) -> Void)? {
        didSet { generalViewController.onSetRefreshInterval = onSetRefreshInterval }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .toolbar

        let generalItem = NSTabViewItem(viewController: generalViewController)
        generalItem.label = "General"
        generalItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)

        let accountsItem = NSTabViewItem(viewController: accountsViewController)
        accountsItem.label = "Accounts"
        accountsItem.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)

        addTabViewItem(generalItem)
        addTabViewItem(accountsItem)
    }

    func update(
        sessions: [DashboardSession],
        isLaunchAtLoginEnabled: Bool,
        areNotificationsEnabled: Bool,
        refreshInterval: AppPreferences.RefreshInterval
    ) {
        generalViewController.update(
            isLaunchAtLoginEnabled: isLaunchAtLoginEnabled,
            areNotificationsEnabled: areNotificationsEnabled,
            refreshInterval: refreshInterval
        )
        accountsViewController.update(sessions: sessions)
    }

    func select(tab: SettingsWindowController.Tab) {
        selectedTabViewItemIndex = switch tab {
        case .general: 0
        case .accounts: 1
        }
    }
}

@MainActor
private final class GeneralSettingsViewController: NSViewController {
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let hintLabel = NSTextField(labelWithString: "Open \(AppBundle.name) automatically when you log in.")
    private let refreshIntervalLabel = NSTextField(labelWithString: "Refresh interval")
    private let refreshIntervalControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let notificationsCheckbox = NSButton(checkboxWithTitle: "Build notifications", target: nil, action: nil)
    private let notificationsHintLabel = NSTextField(labelWithString: "Show local notifications for started, deployed, and failed builds.")
    var onSetLaunchAtLogin: ((Bool) -> Void)?
    var onSetNotificationsEnabled: ((Bool) -> Void)?
    var onSetRefreshInterval: ((AppPreferences.RefreshInterval) -> Void)?

    override func loadView() {
        view = NSView()
        buildUI()
    }

    func update(
        isLaunchAtLoginEnabled: Bool,
        areNotificationsEnabled: Bool,
        refreshInterval: AppPreferences.RefreshInterval
    ) {
        launchAtLoginCheckbox.state = isLaunchAtLoginEnabled ? .on : .off
        notificationsCheckbox.state = areNotificationsEnabled ? .on : .off
        refreshIntervalControl.selectItem(at: AppPreferences.RefreshInterval.allCases.firstIndex(of: refreshInterval) ?? 1)
    }

    private func buildUI() {
        hintLabel.textColor = .secondaryLabelColor
        notificationsHintLabel.textColor = .secondaryLabelColor
        refreshIntervalLabel.textColor = .labelColor

        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(toggleLaunchAtLogin)
        refreshIntervalControl.addItems(withTitles: AppPreferences.RefreshInterval.allCases.map(\.title))
        refreshIntervalControl.target = self
        refreshIntervalControl.action = #selector(changeRefreshInterval)
        notificationsCheckbox.target = self
        notificationsCheckbox.action = #selector(toggleNotifications)

        let refreshRow = NSStackView(views: [refreshIntervalLabel, refreshIntervalControl])
        refreshRow.orientation = .horizontal
        refreshRow.alignment = .centerY
        refreshRow.spacing = 12
        refreshRow.setHuggingPriority(.defaultHigh, for: .vertical)

        let stack = NSStackView(views: [
            launchAtLoginCheckbox,
            hintLabel,
            refreshRow,
            notificationsCheckbox,
            notificationsHintLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.setCustomSpacing(16, after: hintLabel)
        stack.setCustomSpacing(16, after: refreshRow)
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
        ])
    }

    @objc
    private func toggleLaunchAtLogin() {
        onSetLaunchAtLogin?(launchAtLoginCheckbox.state == .on)
    }

    @objc
    private func toggleNotifications() {
        onSetNotificationsEnabled?(notificationsCheckbox.state == .on)
    }

    @objc
    private func changeRefreshInterval() {
        let index = refreshIntervalControl.indexOfSelectedItem
        guard AppPreferences.RefreshInterval.allCases.indices.contains(index) else { return }
        onSetRefreshInterval?(AppPreferences.RefreshInterval.allCases[index])
    }
}

@MainActor
private final class AccountsSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let scrollView = NSScrollView()
    private let tableView = AccountsTableView()
    private let controls = NSSegmentedControl(labels: ["", ""], trackingMode: .momentary, target: nil, action: nil)
    private var sessions: [DashboardSession] = []
    var onLogin: (() -> Void)?
    var onLogout: ((DashboardSession) -> Void)?

    override func loadView() {
        view = NSView()
        buildUI()
    }

    func update(sessions: [DashboardSession]) {
        self.sessions = sessions
        tableView.reloadData()
        if !sessions.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        updateControls()
    }

    private func buildUI() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("account"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 52
        tableView.intercellSpacing = .zero
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.focusRingType = .none
        tableView.menuProvider = { [weak self] row in
            self?.makeContextMenu(for: row)
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        controls.segmentStyle = .smallSquare
        controls.setWidth(26, forSegment: 0)
        controls.setWidth(26, forSegment: 1)
        controls.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: nil), forSegment: 0)
        controls.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: nil), forSegment: 1)
        controls.target = self
        controls.action = #selector(handleControls)
        controls.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        view.addSubview(controls)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            scrollView.heightAnchor.constraint(equalToConstant: 180),

            controls.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            controls.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
        ])
    }

    private func updateControls() {
        controls.setEnabled(true, forSegment: 0)
        controls.setEnabled(tableView.selectedRow >= 0 && tableView.selectedRow < sessions.count, forSegment: 1)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        sessions.count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("accountCell")
        let view = (tableView.makeView(withIdentifier: identifier, owner: self) as? AccountCellView) ?? AccountCellView()
        view.identifier = identifier
        view.configure(session: sessions[row])
        return view
    }

    @objc
    private func handleControls() {
        defer { controls.selectedSegment = -1 }
        switch controls.selectedSegment {
        case 0:
            onLogin?()
        case 1:
            if tableView.selectedRow >= 0, tableView.selectedRow < sessions.count {
                onLogout?(sessions[tableView.selectedRow])
            }
        default:
            break
        }
    }

    private func makeContextMenu(for row: Int) -> NSMenu? {
        guard sessions.indices.contains(row) else { return nil }
        let session = sessions[row]
        let menu = NSMenu()

        let copyItem = NSMenuItem(title: "Copy Account ID", action: #selector(copySelectedAccountID), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = !(session.accountID?.isEmpty ?? true)
        menu.addItem(copyItem)

        menu.addItem(NSMenuItem.separator())

        let logoutItem = NSMenuItem(title: "Log Out", action: #selector(logOutSelectedAccount), keyEquivalent: "")
        logoutItem.target = self
        menu.addItem(logoutItem)

        return menu
    }

    @objc
    private func copySelectedAccountID() {
        guard tableView.selectedRow >= 0, tableView.selectedRow < sessions.count,
              let accountID = sessions[tableView.selectedRow].accountID,
              !accountID.isEmpty
        else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(accountID, forType: .string)
    }

    @objc
    private func logOutSelectedAccount() {
        guard tableView.selectedRow >= 0, tableView.selectedRow < sessions.count else {
            return
        }
        onLogout?(sessions[tableView.selectedRow])
    }
}

@MainActor
private final class AccountCellView: NSTableCellView {
    private let avatarView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let emailLabel = NSTextField(labelWithString: "")
    private var imageTask: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
        avatarView.image = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
    }

    func configure(session: DashboardSession?) {
        imageTask?.cancel()
        nameLabel.stringValue = session?.userEmail ?? "Cloudflare"
        emailLabel.stringValue = session?.accountID ?? ""
        avatarView.image = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)

        guard let rawURL = session?.userAvatarURL, let url = URL(string: rawURL) else {
            return
        }

        imageTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled, let image = NSImage(data: data) else { return }
                self.avatarView.image = image
            } catch {}
        }
    }

    private func buildUI() {
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.imageScaling = .scaleAxesIndependently
        avatarView.wantsLayer = true
        avatarView.layer?.cornerRadius = 18
        avatarView.layer?.masksToBounds = true

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        emailLabel.textColor = .secondaryLabelColor

        let labels = NSStackView(views: [nameLabel, emailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false

        addSubview(avatarView)
        addSubview(labels)

        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            avatarView.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 36),
            avatarView.heightAnchor.constraint(equalToConstant: 36),

            labels.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

private final class AccountsTableView: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return menuProvider?(row)
    }
}
