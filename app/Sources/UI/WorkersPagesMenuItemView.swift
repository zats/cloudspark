import AppKit

@MainActor
final class WorkersPagesMenuItemView: NSView {
    private let backgroundView = NSView()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let statusIconView = NSImageView()
    private let metricsStack = NSStackView()
    private let accountLabel = NSTextField(labelWithString: "")
    private let requestsItem = MetricItemView(symbolName: "chart.xyaxis.line")
    private let errorsItem = MetricItemView(symbolName: "xmark.icloud")
    private let cpuItem = MetricItemView(symbolName: "cpu")
    private let releaseItem = MetricItemView(symbolName: "clock")
    private var project: DashboardProject
    private var isPointerHovering = false
    private var trackingArea: NSTrackingArea?
    private let rowWidth: CGFloat = 360
    private let rowHeight: CGFloat = 64

    init(project: DashboardProject) {
        self.project = project
        super.init(frame: NSRect(x: 0, y: 0, width: rowWidth, height: rowHeight))
        translatesAutoresizingMaskIntoConstraints = false
        setup()
        update(project: project)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func update(project: DashboardProject) {
        self.project = project
        let symbolName = switch project.kind {
        case .worker: "gearshape"
        case .page: "richtext.page"
        }
        iconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: project.name
        )
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        nameLabel.stringValue = project.name
        subtitleLabel.stringValue = project.subtitle ?? ""
        subtitleLabel.isHidden = (project.subtitle?.isEmpty ?? true)

        statusIconView.isHidden = (project.statusText?.isEmpty ?? true)
        statusIconView.image = statusImage(for: project.statusText)
        statusIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        updateStatusSymbolEffect()

        requestsItem.update(text: project.metrics.map { formatCompactInt($0.requests) })
        errorsItem.update(text: project.metrics.map { formatCompactInt($0.errors) })
        cpuItem.update(text: project.metrics.map { formatCPUTime($0.averageCPUTimeMS) })
        releaseItem.update(text: project.lastReleaseAt.map(formatRelativeDate))
        accountLabel.stringValue = project.accountEmail ?? ""
        accountLabel.isHidden = (project.accountEmail?.isEmpty ?? true)

        let hasVisibleMetrics = [requestsItem, errorsItem, cpuItem, releaseItem].contains { !$0.isHidden }
        metricsStack.isHidden = !hasVisibleMetrics

        refreshHighlight()
    }

    private func setup() {
        wantsLayer = true

        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 4
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = .secondaryLabelColor
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(iconView)

        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        metricsStack.orientation = .horizontal
        metricsStack.alignment = .centerY
        metricsStack.spacing = 10
        metricsStack.translatesAutoresizingMaskIntoConstraints = false
        [requestsItem, errorsItem, cpuItem, releaseItem].forEach(metricsStack.addArrangedSubview)

        accountLabel.font = NSFont.systemFont(ofSize: 9, weight: .regular)
        accountLabel.textColor = .tertiaryLabelColor
        accountLabel.lineBreakMode = .byTruncatingHead
        accountLabel.alignment = .right
        accountLabel.translatesAutoresizingMaskIntoConstraints = false

        let labels = NSStackView(views: [nameLabel, subtitleLabel, metricsStack])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labels)
        addSubview(accountLabel)

        statusIconView.translatesAutoresizingMaskIntoConstraints = false
        statusIconView.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(statusIconView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: rowWidth),
            heightAnchor.constraint(equalToConstant: rowHeight),

            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            backgroundView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            statusIconView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            statusIconView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            statusIconView.widthAnchor.constraint(equalToConstant: 14),
            statusIconView.heightAnchor.constraint(equalToConstant: 14),

            accountLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            accountLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            accountLabel.leadingAnchor.constraint(greaterThanOrEqualTo: labels.leadingAnchor, constant: 80),

            labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: accountLabel.leadingAnchor, constant: -10),
            labels.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerHovering = true
        refreshHighlight()
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerHovering = false
        refreshHighlight()
        super.mouseExited(with: event)
    }

    func refreshHighlight(isHighlighted: Bool? = nil) {
        let highlighted = isHighlighted ?? isPointerHovering || (enclosingMenuItem?.isHighlighted == true)
        backgroundView.layer?.backgroundColor = highlighted
            ? NSColor.selectedContentBackgroundColor.cgColor
            : NSColor.clear.cgColor
        let primary = highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
        let secondary = highlighted ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.8) : NSColor.secondaryLabelColor
        let tertiary = highlighted ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.55) : NSColor.tertiaryLabelColor
        nameLabel.textColor = primary
        subtitleLabel.textColor = secondary
        accountLabel.textColor = tertiary
        iconView.contentTintColor = secondary
        statusIconView.contentTintColor = highlighted
            ? NSColor.selectedMenuItemTextColor
            : statusColor(for: project.statusText)
        [requestsItem, errorsItem, cpuItem, releaseItem].forEach { $0.apply(primary: secondary, highlighted: highlighted) }
    }

    private func statusImage(for status: String?) -> NSImage? {
        let symbolName = switch DashboardStatusKind(status: status) {
        case .inProgress:
            "arrow.trianglehead.2.clockwise"
        case .success:
            "checkmark.circle.fill"
        case .failure:
            "xmark.circle.fill"
        case .neutral:
            "circle.fill"
        }
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: status)
    }

    private func updateStatusSymbolEffect() {
        if #available(macOS 14.0, *) {
            statusIconView.removeAllSymbolEffects(animated: false)
            guard project.statusKind == .inProgress else {
                return
            }
            statusIconView.addSymbolEffect(.rotate.byLayer, options: .repeating)
        }
    }

    private func statusColor(for status: String?) -> NSColor {
        switch DashboardStatusKind(status: status) {
        case .inProgress:
            return NSColor.systemOrange.blended(withFraction: 0.15, of: .labelColor) ?? .systemOrange
        case .success:
            return NSColor.systemGreen.blended(withFraction: 0.15, of: .labelColor) ?? .systemGreen
        case .failure:
            return NSColor.systemRed.blended(withFraction: 0.15, of: .labelColor) ?? .systemRed
        case .neutral:
            return .secondaryLabelColor
        }
    }

    private func formatCompactInt(_ value: Int) -> String {
        if value >= 1000 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 1
            formatter.minimumFractionDigits = 0
            let compact = Double(value) / 1000
            return "\(formatter.string(from: NSNumber(value: compact)) ?? "\(compact)")k"
        }
        return "\(value)"
    }

    private func formatCPUTime(_ milliseconds: Double) -> String {
        if milliseconds >= 1000 {
            return String(format: "%.1fs", milliseconds / 1000)
        }
        if milliseconds >= 100 {
            return String(format: "%.0fms", milliseconds)
        }
        if milliseconds >= 10 {
            return String(format: "%.1fms", milliseconds)
        }
        return String(format: "%.1fms", milliseconds)
    }

    private func formatRelativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

@MainActor
private final class MetricItemView: NSView {
    private let iconView = NSImageView()
    private let textField = NSTextField(labelWithString: "")

    init(symbolName: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        textField.font = NSFont.systemFont(ofSize: 10)
        textField.lineBreakMode = .byClipping
        textField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(textField)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),

            textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 3),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            topAnchor.constraint(equalTo: textField.topAnchor),
            bottomAnchor.constraint(equalTo: textField.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func update(text: String?) {
        if let text, !text.isEmpty {
            textField.stringValue = text
            isHidden = false
        } else {
            textField.stringValue = ""
            isHidden = true
        }
    }

    func apply(primary: NSColor, highlighted: Bool) {
        textField.textColor = primary
        iconView.contentTintColor = primary
        alphaValue = highlighted ? 0.95 : 1
    }
}
