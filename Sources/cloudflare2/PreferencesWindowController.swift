import AppKit

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let accountField = NSTextField(string: "")
    private let workerField = NSTextField(string: "")
    private var completion: ((Result<AppSettings, Error>) -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 168),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cloudflare2"
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func show(current: AppSettings?, completion: @escaping (Result<AppSettings, Error>) -> Void) {
        self.completion = completion
        accountField.stringValue = current?.accountID ?? ""
        workerField.stringValue = current?.workerName ?? ""
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let contentView = window?.contentView else {
            return
        }

        let accountLabel = label("Account ID")
        let workerLabel = label("Worker")
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"

        let stack = NSStackView(views: [
            accountLabel,
            accountField,
            workerLabel,
            workerField,
            saveButton,
        ])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        return label
    }

    @objc
    private func save() {
        let accountID = accountField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let workerName = workerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountID.isEmpty, !workerName.isEmpty else {
            let error = NSError(domain: "cloudflare2", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Account ID and worker are required."
            ])
            completion?(.failure(error))
            return
        }

        completion?(.success(AppSettings(accountID: accountID, workerName: workerName)))
        completion = nil
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        completion = nil
    }
}
