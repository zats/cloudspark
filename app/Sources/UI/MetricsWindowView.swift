import SwiftUI

struct MetricsWindowView: View {
    @ObservedObject var viewModel: MetricsViewModel

    private let topColumns = [GridItem(.adaptive(minimum: 150), spacing: 12)]
    private let twoColumnGrid = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    private let threeColumnGrid = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        content
            .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = viewModel.snapshot {
            switch snapshot {
            case let .worker(workerSnapshot):
                WorkerMetricsDashboardContentView(
                    snapshot: workerSnapshot,
                    viewModel: viewModel,
                    topColumns: topColumns,
                    twoColumnGrid: twoColumnGrid,
                    threeColumnGrid: threeColumnGrid
                )
            case let .page(pageSnapshot):
                PageMetricsDashboardContentView(
                    snapshot: pageSnapshot,
                    topColumns: topColumns,
                    twoColumnGrid: twoColumnGrid
                )
            }
        } else if let errorMessage = viewModel.errorMessage {
            ContentUnavailableView("Failed to load metrics", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
