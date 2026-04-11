import Foundation

enum DashboardMetricsRangePreset: String, CaseIterable, Identifiable {
    case lastHour
    case last24Hours
    case last7Days

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lastHour: "Last hour"
        case .last24Hours: "Last 24 hours"
        case .last7Days: "Last 7 days"
        }
    }

    var shortTitle: String {
        switch self {
        case .lastHour: "1h"
        case .last24Hours: "24h"
        case .last7Days: "7d"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .lastHour: 60 * 60
        case .last24Hours: 24 * 60 * 60
        case .last7Days: 7 * 24 * 60 * 60
        }
    }

    func timeframe(referenceDate: Date = Date()) -> DashboardMetricsTimeframe {
        DashboardMetricsTimeframe(
            start: referenceDate.addingTimeInterval(-duration),
            end: referenceDate
        )
    }
}

struct DashboardMetricsTimeframe: Equatable {
    let start: Date
    let end: Date

    var duration: TimeInterval {
        end.timeIntervalSince(start)
    }
}

enum DashboardMetricsVersionFilterMode: String, CaseIterable, Identifiable {
    case allDeployed
    case activeDeployed
    case specific

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allDeployed: "All deployed versions"
        case .activeDeployed: "Actively deployed versions"
        case .specific: "Specific versions"
        }
    }
}

struct DashboardWorkerVersionOption: Identifiable, Equatable {
    let id: String
    let deployedAt: Date?
    let percentage: Double?

    var shortID: String {
        String(id.prefix(8))
    }

    var title: String {
        shortID
    }
}

enum DashboardMetricsValueUnit: Equatable {
    case count
    case milliseconds
    case percent
    case requestsPerSecond
}

struct DashboardMetricsSummaryCardData: Identifiable, Equatable {
    let id: String
    let title: String
    let value: Double
    let unit: DashboardMetricsValueUnit
    let deltaRatio: Double?
}

struct DashboardMetricsPoint: Identifiable, Equatable {
    let id: String
    let date: Date
    let value: Double
}

struct DashboardMetricsSeries: Identifiable, Equatable {
    let id: String
    let title: String
    let points: [DashboardMetricsPoint]

    var total: Double {
        points.reduce(0) { $0 + $1.value }
    }
}

enum DashboardMetricsChartStyle: Equatable {
    case bar
    case line
}

struct DashboardMetricsChartData: Equatable {
    let title: String
    let unit: DashboardMetricsValueUnit
    let style: DashboardMetricsChartStyle
    let series: [DashboardMetricsSeries]
    let emptyMessage: String?
}

struct DashboardActiveDeploymentRow: Identifiable, Equatable {
    let id: String
    let deployedAt: Date?
    let trafficPercent: Double
    let requestsPerSecond: Double
    let errorRate: Double
    let medianCPUTimeMS: Double
}

struct DashboardActiveDeploymentData: Equatable {
    let rows: [DashboardActiveDeploymentRow]
}

struct DashboardWorkerSubrequestRow: Identifiable, Equatable {
    let id: String
    let host: String
    let countsByStatusClass: [String: Int]
    let averageDurationMS: Double

    var totalRequests: Int {
        countsByStatusClass.values.reduce(0, +)
    }
}

struct DashboardRequestDistributionRow: Identifiable, Equatable {
    let id: String
    let coloCode: String
    let requests: Int
}

struct DashboardPlacementPerformanceRow: Identifiable, Equatable {
    let id: String
    let placementUsed: String
    let coloCode: String
    let p90DurationMS: Double
}

struct DashboardWorkerMetricsSnapshot: Equatable {
    let versionOptions: [DashboardWorkerVersionOption]
    let activeVersionOptions: [DashboardWorkerVersionOption]
    let selectedVersionIDs: [String]?
    let summaries: [DashboardMetricsSummaryCardData]
    let activeDeployment: DashboardActiveDeploymentData
    let requestsChart: DashboardMetricsChartData
    let errorsByVersionChart: DashboardMetricsChartData
    let errorsByStatusChart: DashboardMetricsChartData
    let clientDisconnectedByVersionChart: DashboardMetricsChartData
    let clientDisconnectedByTypeChart: DashboardMetricsChartData
    let cpuTimeChart: DashboardMetricsChartData
    let wallTimeChart: DashboardMetricsChartData
    let requestDurationChart: DashboardMetricsChartData
    let subrequests: [DashboardWorkerSubrequestRow]
    let requestDistribution: [DashboardRequestDistributionRow]
    let placementPerformance: [DashboardPlacementPerformanceRow]
}

enum DashboardSubrequestStatusFilter: String, CaseIterable, Identifiable {
    case all
    case status2xx
    case status3xx
    case status4xx
    case status5xx

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .status2xx: "2xx"
        case .status3xx: "3xx"
        case .status4xx: "4xx"
        case .status5xx: "5xx"
        }
    }

    var statusClassKey: String? {
        switch self {
        case .all: nil
        case .status2xx: "2xx"
        case .status3xx: "3xx"
        case .status4xx: "4xx"
        case .status5xx: "5xx"
        }
    }
}
