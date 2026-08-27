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
                    Text(viewModel.transformExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(viewModel.chartPoints) { point in
                if point.role == .observed, viewModel.allSeries.count == 1 {
                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value(viewModel.displayUnitsLabel, point.value)
                    )
                    .interpolationMethod(interpolationMethod)
                    .foregroundStyle(
                        .linearGradient(
                            colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }

                LineMark(
                    x: .value("Date", point.date),
                    y: .value(viewModel.displayUnitsLabel, point.value)
                )
                .interpolationMethod(interpolationMethod)
                .foregroundStyle(by: .value("Series", point.plotKey))
                .lineStyle(
                    point.role == .movingAverage
                        ? StrokeStyle(lineWidth: 1.4, dash: [5, 3])
                        : StrokeStyle(lineWidth: 1.8)
                )
            }

            // Growth charts need a visible zero; index charts need their base of 100.
            if let baseline = chartBaseline {
                RuleMark(y: .value("Baseline", baseline))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            if let selectedDate {
                RuleMark(x: .value("Selected", selectedDate))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                ForEach(viewModel.nearestPoints(to: selectedDate)) { point in
                    PointMark(
                        x: .value("Date", point.date),
                        y: .value(viewModel.displayUnitsLabel, point.value)
                    )
                    .symbolSize(90)
                    .foregroundStyle(by: .value("Series", point.plotKey))
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.year().month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let doubleValue = value.as(Double.self) {
                        Text(viewModel.valueFormatter.formatAxisValue(doubleValue))
                    }
                }
            }
        }
        .chartLegend(position: .bottom, spacing: 16)
        .chartXSelection(value: $selectedDate)
        .frame(minHeight: 340)
        .accessibilityIdentifier("detail.chart")
    }

    /// Smooth curves are only honest when the data is sparse enough that the curve is
    /// interpolating between real observations rather than inventing shape.
    private var interpolationMethod: InterpolationMethod {
        viewModel.chartPoints.count <= 250 ? .monotone : .linear
    }

    private var chartBaseline: Double? {
        switch viewModel.transform {
        case .level: return nil
        case .indexed: return 100
        case .periodChange, .periodPercentChange, .yearOverYear: return 0
        }
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
