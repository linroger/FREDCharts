import Charts
import SwiftUI

/// The chart surface of the series detail view: plot, baseline, hover selection, and the
/// empty states that explain *why* nothing is plotted.
struct SeriesChartView: View {
    @ObservedObject var viewModel: SeriesDetailViewModel
    @Binding var selectedDate: Date?

    var body: some View {
        GroupBox(viewModel.chartSectionTitle) {
            VStack(alignment: .leading, spacing: 14) {
                if viewModel.isWindowEmpty {
                    ContentUnavailableView {
                        Label("No Data In This Window", systemImage: "calendar.badge.exclamationmark")
                    } description: {
                        Text(viewModel.emptyWindowMessage)
                    } actions: {
                        Button("Show All Time") {
                            viewModel.updateRange(.all)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(minHeight: 280)
                } else if viewModel.chartPoints.isEmpty {
                    ContentUnavailableView(
                        "No Data",
                        systemImage: "chart.xyaxis.line",
                        description: Text("There are no observations to plot.")
                    )
                    .frame(minHeight: 280)
                } else {
                    chart
                    selectionReadout
                    if !viewModel.recessionIntervals.isEmpty {
                        Label(
                            "Shaded bands mark U.S. recessions as dated by the NBER.",
                            systemImage: "rectangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Text(viewModel.chartMode == .spread
                         ? viewModel.chartMode.explanation
                         : viewModel.transformExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var chart: some View {
        SeriesPlot(viewModel: viewModel, selectedDate: selectedDate)
            .chartXSelection(value: $selectedDate)
            .frame(minHeight: 340)
            .accessibilityIdentifier("detail.chart")
    }

    @ViewBuilder
    private var selectionReadout: some View {
        if let selectedDate {
            let points = viewModel.nearestPoints(to: selectedDate)

            if !points.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(FREDDate.displayString(from: points[0].date))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(points) { point in
                        HStack {
                            Text(point.seriesTitle)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer(minLength: 16)
                            Text(viewModel.valueFormatter.formatValue(point.value, compact: false))
                                .font(.callout.weight(.semibold).monospacedDigit())
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}
