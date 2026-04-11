import Charts
import Foundation
import SwiftUI

struct MetricsDashboardContentView: View {
    let snapshot: DashboardWorkerMetricsSnapshot
    @ObservedObject var viewModel: WorkerMetricsViewModel
    let topColumns: [GridItem]
    let twoColumnGrid: [GridItem]
    let threeColumnGrid: [GridItem]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: topColumns, spacing: 12) {
                    ForEach(snapshot.summaries) { summary in
                        MetricsSummaryCard(summary: summary)
                    }
                }

                MetricsCard(title: "Active deployment") {
                    ActiveDeploymentCard(rows: snapshot.activeDeployment.rows)
                }

                LazyVGrid(columns: twoColumnGrid, spacing: 12) {
                    MetricsCard(title: snapshot.requestsChart.title) {
                        MetricsTimeSeriesChart(chart: snapshot.requestsChart)
                    }
                    MetricsCard(title: "Subrequests") {
                        SubrequestsCard(
                            rows: viewModel.pagedSubrequests,
                            page: viewModel.subrequestPage,
                            pageCount: viewModel.subrequestPageCount,
                            filter: viewModel.subrequestStatusFilter,
                            search: viewModel.subrequestSearch,
                            onChangeFilter: { viewModel.updateSubrequestStatus($0) },
                            onChangeSearch: { viewModel.updateSubrequestSearch($0) },
                            onPreviousPage: { viewModel.previousSubrequestPage() },
                            onNextPage: { viewModel.nextSubrequestPage() }
                        )
                    }
                }

                LazyVGrid(columns: twoColumnGrid, spacing: 12) {
                    MetricsCard(title: snapshot.errorsByVersionChart.title) {
                        MetricsTimeSeriesChart(chart: snapshot.errorsByVersionChart)
                    }
                    MetricsCard(title: snapshot.errorsByStatusChart.title) {
                        MetricsTimeSeriesChart(chart: snapshot.errorsByStatusChart)
                    }
                }

                LazyVGrid(columns: twoColumnGrid, spacing: 12) {
                    MetricsCard(title: snapshot.clientDisconnectedByVersionChart.title) {
                        MetricsTimeSeriesChart(chart: snapshot.clientDisconnectedByVersionChart)
                    }
                    MetricsCard(title: snapshot.clientDisconnectedByTypeChart.title) {
                        MetricsTimeSeriesChart(chart: snapshot.clientDisconnectedByTypeChart)
                    }
                }

                LazyVGrid(columns: twoColumnGrid, spacing: 12) {
                    MetricsCard(title: "Request distribution") {
                        RequestDistributionCard(rows: snapshot.requestDistribution)
                    }
                    MetricsCard(title: "Placement performance") {
                        PlacementPerformanceCard(rows: snapshot.placementPerformance)
                    }
                }

                LazyVGrid(columns: threeColumnGrid, spacing: 12) {
                    MetricsCard(title: snapshot.cpuTimeChart.title) {
                        MetricsTimeSeriesChart(chart: snapshot.cpuTimeChart)
                    }
                    MetricsCard(title: snapshot.wallTimeChart.title) {
                        MetricsTimeSeriesChart(chart: snapshot.wallTimeChart)
                    }
                    MetricsCard(title: snapshot.requestDurationChart.title) {
                        MetricsTimeSeriesChart(chart: snapshot.requestDurationChart)
                    }
                }
            }
            .padding(14)
        }
    }
}

struct MetricsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct MetricsSummaryCard: View {
    let summary: DashboardMetricsSummaryCardData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(metricsFormattedValue(summary.value, unit: summary.unit))
                .font(.system(size: 24, weight: .semibold))
            if let deltaRatio = summary.deltaRatio {
                Text(metricsFormattedDelta(deltaRatio))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(deltaRatio > 0 ? .blue : deltaRatio < 0 ? .red : .secondary)
            } else {
                Text("No previous data")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct ActiveDeploymentCard: View {
    let rows: [DashboardActiveDeploymentRow]

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                deploymentHeaderCell("Version ID", width: 110, alignment: .leading)
                deploymentHeaderCell("Deployed", width: 100, alignment: .leading)
                deploymentHeaderCell("Traffic %", width: 90, alignment: .leading)
                deploymentHeaderCell("Requests/sec", width: 110, alignment: .leading)
                deploymentHeaderCell("Error Rate", width: 90, alignment: .leading)
                deploymentHeaderCell("Median CPU", width: nil, alignment: .leading)
            }
            ForEach(rows) { row in
                HStack {
                    deploymentValueCell(String(row.id.prefix(8)), width: 110, alignment: .leading)
                    deploymentValueCell(row.deployedAt.map { RelativeTime.shortString(since: $0) } ?? "—", width: 100, alignment: .leading)
                    deploymentValueCell(metricsPercentString(row.trafficPercent / 100), width: 90, alignment: .leading)
                    deploymentValueCell(metricsFormattedValue(row.requestsPerSecond, unit: .requestsPerSecond), width: 110, alignment: .leading)
                    deploymentValueCell(metricsPercentString(row.errorRate), width: 90, alignment: .leading)
                    deploymentValueCell(metricsFormattedValue(row.medianCPUTimeMS, unit: .milliseconds), width: nil, alignment: .leading)
                }
                Divider()
            }
        }
    }
}

struct MetricsTimeSeriesChart: View {
    let chart: DashboardMetricsChartData

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MetricsLegend(series: chart.series, unit: chart.unit)
            if chart.series.isEmpty {
                Text(chart.emptyMessage ?? "No data")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else if chart.style == .bar {
                MetricsBarChart(chart: chart)
            } else {
                MetricsLineChart(chart: chart)
            }
        }
    }
}

struct MetricsBarChart: View {
    let chart: DashboardMetricsChartData

    private var marks: [MetricsChartMarkRow] {
        metricsChartMarkRows(from: chart.series)
    }

    private var colorsBySeriesTitle: [String: Color] {
        metricsColorsBySeriesTitle(for: chart.series)
    }

    var body: some View {
        Chart {
            ForEach(marks) { mark in
                BarMark(
                    x: .value("Time", mark.date),
                    y: .value("Value", mark.value)
                )
                .position(by: .value("Series", mark.seriesTitle))
                .foregroundStyle(colorsBySeriesTitle[mark.seriesTitle] ?? .purple)
            }
        }
        .chartXAxis { metricsXAxis }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .chartLegend(.hidden)
        .frame(minHeight: 240)
    }

    @AxisContentBuilder
    private var metricsXAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { value in
            AxisGridLine()
            AxisTick()
            AxisValueLabel {
                if let date = value.as(Date.self) {
                    Text(metricsChartAxisLabel(date))
                }
            }
        }
    }
}

struct MetricsLineChart: View {
    let chart: DashboardMetricsChartData

    private var marks: [MetricsChartMarkRow] {
        metricsChartMarkRows(from: chart.series)
    }

    private var colorsBySeriesTitle: [String: Color] {
        metricsColorsBySeriesTitle(for: chart.series)
    }

    var body: some View {
        Chart {
            ForEach(marks) { mark in
                LineMark(
                    x: .value("Time", mark.date),
                    y: .value("Value", mark.value),
                    series: .value("Series", mark.seriesTitle)
                )
                .foregroundStyle(colorsBySeriesTitle[mark.seriesTitle] ?? .purple)
                .interpolationMethod(.linear)
            }
        }
        .chartXAxis { metricsXAxis }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .chartLegend(.hidden)
        .frame(minHeight: 240)
    }

    @AxisContentBuilder
    private var metricsXAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { value in
            AxisGridLine()
            AxisTick()
            AxisValueLabel {
                if let date = value.as(Date.self) {
                    Text(metricsChartAxisLabel(date))
                }
            }
        }
    }
}

struct MetricsLegend: View {
    let series: [DashboardMetricsSeries]
    let unit: DashboardMetricsValueUnit

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(series.prefix(4).enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 4) {
                    Circle()
                        .fill(metricsColor(for: index))
                        .frame(width: 7, height: 7)
                    Text(item.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(metricsFormattedValue(item.total, unit: unit))
                        .font(.system(size: 11, weight: .medium))
                }
            }
            if series.count > 4 {
                Text("+\(series.count - 4) more")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SubrequestsCard: View {
    let rows: [DashboardWorkerSubrequestRow]
    let page: Int
    let pageCount: Int
    let filter: DashboardSubrequestStatusFilter
    let search: String
    let onChangeFilter: (DashboardSubrequestStatusFilter) -> Void
    let onChangeSearch: (String) -> Void
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Picker("Status", selection: Binding(get: { filter }, set: onChangeFilter)) {
                    ForEach(DashboardSubrequestStatusFilter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Search origins…", text: Binding(get: { search }, set: onChangeSearch))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }

            VStack(spacing: 8) {
                HStack {
                    subrequestHeaderText("Origin", width: nil, alignment: .leading)
                    subrequestHeaderText("Requests", width: 110, alignment: .leading)
                    subrequestHeaderText("Request Duration", width: 120, alignment: .leading)
                }

                ForEach(rows) { row in
                    HStack {
                        Text(row.host)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 6) {
                            ForEach(["2xx", "3xx", "4xx", "5xx"], id: \.self) { key in
                                let count = row.countsByStatusClass[key] ?? 0
                                if count > 0 {
                                    Text("\(key) \(metricsCompactCount(count))")
                                        .font(.system(size: 11, weight: .medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(subrequestStatusBackground(key))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                            }
                        }
                        .frame(width: 110, alignment: .leading)
                        Text(metricsFormattedValue(row.averageDurationMS, unit: .milliseconds))
                            .font(.system(size: 12))
                            .frame(width: 120, alignment: .leading)
                    }
                    Divider()
                }
            }

            HStack {
                Text("Page \(page + 1) of \(pageCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Previous", action: onPreviousPage)
                    .disabled(page == 0)
                Button("Next", action: onNextPage)
                    .disabled(page >= pageCount - 1)
            }
        }
    }
}

struct RequestDistributionCard: View {
    let rows: [DashboardRequestDistributionRow]

    var body: some View {
        RequestDistributionMapCard(rows: rows)
    }
}

struct PlacementPerformanceCard: View {
    let rows: [DashboardPlacementPerformanceRow]

    var body: some View {
        if rows.isEmpty {
            VStack(spacing: 12) {
                Text("Enable Smart Placement to see the performance impact of placement decisions.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Enable in Settings") {}
                    .disabled(true)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            VStack(spacing: 8) {
                HStack {
                    Text("Placement")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("P90")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                ForEach(rows.prefix(8)) { row in
                    HStack {
                        Text("\(row.placementUsed) • \(row.coloCode)")
                            .font(.system(size: 12))
                        Spacer()
                        Text(metricsFormattedValue(row.p90DurationMS, unit: .milliseconds))
                            .font(.system(size: 12, weight: .medium))
                    }
                    Divider()
                }
            }
            .frame(minHeight: 240, alignment: .top)
        }
    }
}

private func deploymentHeaderCell(_ text: String, width: CGFloat?, alignment: Alignment) -> some View {
    Text(text)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: width, alignment: alignment)
}

private func deploymentValueCell(_ text: String, width: CGFloat?, alignment: Alignment) -> some View {
    Text(text)
        .font(.system(size: 12))
        .frame(width: width, alignment: alignment)
}

private func subrequestHeaderText(_ text: String, width: CGFloat?, alignment: Alignment) -> some View {
    Text(text)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: width, alignment: alignment)
}

private func subrequestStatusBackground(_ key: String) -> Color {
    switch key {
    case "2xx": Color.green.opacity(0.12)
    case "3xx": Color.blue.opacity(0.12)
    case "4xx": Color.orange.opacity(0.12)
    case "5xx": Color.red.opacity(0.12)
    default: Color.gray.opacity(0.12)
    }
}

private func metricsColor(for index: Int) -> Color {
    let palette: [Color] = [.purple, .orange, .blue, .pink, .green, .red, .teal, .indigo]
    return palette[index % palette.count]
}

private func metricsColorsBySeriesTitle(for series: [DashboardMetricsSeries]) -> [String: Color] {
    Dictionary(uniqueKeysWithValues: Array(series.enumerated()).map { index, item in
        (item.title, metricsColor(for: index))
    })
}

private struct MetricsChartMarkRow: Identifiable {
    let id: String
    let seriesTitle: String
    let date: Date
    let value: Double
}

private func metricsChartMarkRows(from series: [DashboardMetricsSeries]) -> [MetricsChartMarkRow] {
    series.flatMap { item in
        item.points.map { point in
            MetricsChartMarkRow(
                id: "\(item.id)-\(point.id)",
                seriesTitle: item.title,
                date: point.date,
                value: point.value
            )
        }
    }
}

private func metricsChartAxisLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d, HH:mm"
    return formatter.string(from: date)
}

private func metricsCompactCount(_ value: Int) -> String {
    metricsFormattedValue(Double(value), unit: .count)
}

private func metricsFormattedValue(_ value: Double, unit: DashboardMetricsValueUnit) -> String {
    switch unit {
    case .count:
        return NumberFormatter.metricsCompactCount.string(from: NSNumber(value: value)) ?? "\(Int(value))"
    case .milliseconds:
        if value >= 1000 {
            return String(format: "%.2f s", value / 1000)
        }
        if value >= 100 {
            return String(format: "%.0f ms", value)
        }
        if value >= 10 {
            return String(format: "%.1f ms", value)
        }
        return String(format: "%.2f ms", value)
    case .percent:
        return metricsPercentString(value)
    case .requestsPerSecond:
        if value < 0.01 {
            return "0 req/s"
        }
        return String(format: "%.2f req/s", value)
    }
}

private func metricsPercentString(_ value: Double) -> String {
    String(format: "%.0f%%", value * 100)
}

private func metricsFormattedDelta(_ ratio: Double) -> String {
    let sign = ratio > 0 ? "+" : ""
    return "\(sign)\(String(format: "%.2f%%", ratio * 100))"
}

private extension NumberFormatter {
    static let metricsCompactCount: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        formatter.notANumberSymbol = "0"
        return formatter
    }()
}
