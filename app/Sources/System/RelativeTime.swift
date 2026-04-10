import Foundation

enum RelativeTime {
    static func shortString(since date: Date, referenceDate: Date = Date()) -> String {
        let interval = max(0, referenceDate.timeIntervalSince(date))
        if interval < 5 {
            return "now"
        }

        let value: Double
        let suffix: String

        switch interval {
        case ..<60:
            value = interval
            suffix = "s"
        case ..<3600:
            value = interval / 60
            suffix = "m"
        case ..<86_400:
            value = interval / 3600
            suffix = "h"
        default:
            value = interval / 86_400
            suffix = "d"
        }

        return "\(format(value))\(suffix) ago"
    }

    private static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }
}
