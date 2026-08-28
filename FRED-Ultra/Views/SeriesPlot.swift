import Charts
import SwiftUI

/// The plot marks themselves, with no chrome and no gestures.
///
/// Shared by the interactive chart and the exported image so the two can never drift:
/// a picture saved from the app is the same picture the reader was looking at.
struct SeriesPlot: View {
    @ObservedObject var viewModel: SeriesDetailViewModel
    /// Hover position, when there is one. Nil for a static render.
    var selectedDate: Date?

    var body: some View {
        Chart {
            // Drawn first so the bands sit behind every line and marker.
            ForEach(viewModel.recessionIntervals, id: \.start) { interval in
                RectangleMark(
                    xStart: .value("Recession start", interval.start),
                    xEnd: .value("Recession end", interval.end)
                )
                .foregroundStyle(.secondary.opacity(0.15))
                .accessibilityLabel("U.S. recession")
            }

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
}
