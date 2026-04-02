import AppKit

@MainActor
final class BuildsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let headerLabel = NSTextField(labelWithString: "Builds")
    private let tableView = NSTableView(frame: .zero)
    private var builds: [DashboardBuild] = []

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cloudflare2 Builds"
        super.init(window: window)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func show(workerName: String, builds: [DashboardBuild]) {
        update(workerName: workerName, builds: builds)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func update(workerName: String, builds: [DashboardBuild]) {
        self.builds = builds
        headerLabel.stringValue = workerName
        tableView.reloadData()
    }

    private func buildUI() {
        guard let contentView = window?.contentView else {
            return
        }

        headerLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let columns = [
            ("status", "Status", 110.0),
            ("branch", "Branch", 180.0),
            ("created", "Created", 190.0),
            ("versions", "Versions", 160.0),
            ("id", "Build", 260.0),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.headerView = NSTableHeaderView()
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(headerLabel)
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            headerLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            headerLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        builds.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < builds.count, let tableColumn else {
            return nil
        }

        let build = builds[row]
        let text: String
        switch tableColumn.identifier.rawValue {
        case "status":
            text = build.status ?? "-"
        case "branch":
            text = build.branch ?? "-"
        case "created":
            text = build.createdOn ?? "-"
        case "versions":
            text = build.versionIDs.isEmpty ? "-" : build.versionIDs.joined(separator: ",")
        default:
            text = build.id
        }

        let identifier = NSUserInterfaceItemIdentifier("cell-\(tableColumn.identifier.rawValue)")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        view.identifier = identifier

        let label: NSTextField
        if let existing = view.textField {
            label = existing
        } else {
            label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            view.textField = label
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
        }
        label.stringValue = text
        return view
    }
}
