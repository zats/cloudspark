import Foundation

enum DashboardObservabilityView: String, CaseIterable {
    case events
    case invocations
    case traces
    case visualizations

    var title: String {
        switch self {
        case .events: "Events"
        case .invocations: "Invocations"
        case .traces: "Traces"
        case .visualizations: "Visuals"
        }
    }

    var limit: Int {
        switch self {
        case .events: 100
        case .invocations, .traces: 50
        case .visualizations: 10
        }
    }

    var includesChart: Bool {
        switch self {
        case .events, .traces, .visualizations: true
        case .invocations: false
        }
    }

    var apiView: String {
        switch self {
        case .visualizations: "calculations"
        default: rawValue
        }
    }

    var supportsLive: Bool {
        self == .events
    }

    var showsFields: Bool {
        self != .visualizations
    }
}

enum DashboardObservabilityRangePreset: String, CaseIterable {
    case last15Minutes
    case lastHour
    case last24Hours
    case last3Days
    case last7Days
    case custom

    var title: String {
        switch self {
        case .last15Minutes: "15m"
        case .lastHour: "1h"
        case .last24Hours: "24h"
        case .last3Days: "3d"
        case .last7Days: "7d"
        case .custom: "Custom"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .last15Minutes: 15 * 60
        case .lastHour: 60 * 60
        case .last24Hours: 24 * 60 * 60
        case .last3Days: 3 * 24 * 60 * 60
        case .last7Days: 7 * 24 * 60 * 60
        case .custom: nil
        }
    }
}

struct DashboardObservabilityTimeframe: Equatable {
    let from: Date
    let to: Date

    var apiValue: [String: Int64] {
        [
            "from": Int64(from.timeIntervalSince1970 * 1000),
            "to": Int64(to.timeIntervalSince1970 * 1000),
        ]
    }
}

struct DashboardObservabilityField: Hashable {
    let key: String
    let type: String
    let lastSeenAt: Date?
}

struct DashboardObservabilityRow: Equatable {
    let id: String
    let timestamp: Date?
    let values: [String: String]
}

struct DashboardObservabilityQueryResult {
    let fields: [DashboardObservabilityField]
    let rows: [DashboardObservabilityRow]
    let chartPoints: [DashboardObservabilityChartPoint]
}

struct DashboardObservabilityLiveTailSession {
    let socketURL: URL
}

struct DashboardObservabilityChartPoint: Identifiable, Equatable {
    let id: String
    let date: Date?
    let label: String
    let value: Double
    let segments: [DashboardObservabilityChartSegment]
}

struct DashboardObservabilityChartSegment: Identifiable, Equatable {
    let id: String
    let kind: Kind
    let value: Double

    enum Kind: String {
        case info
        case error

        var title: String { rawValue }
    }
}
