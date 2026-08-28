import Charts
import SwiftUI

/// Scatter of the primary series against one comparison series, with an OLS fit.
///
/// This is the surface for questions of the form "how do these two move together" —
/// a Phillips curve, Okun's law, a money-growth-and-prices plot. Points are shaded by
/// date so a regime shift shows up as a cloud that has moved, which a single correlation
/// coefficient cannot reveal.
struct SeriesScatterView: View {
    @ObservedObject var viewModel: SeriesDetailViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if viewModel.comparisonSeries.count > 1 {
                    partnerPicker
                }

                scatterSection

                if let regression = viewModel.regression {
                    fitSection(regression)
                }

                if !viewModel.comparisonSummaries.isEmpty {
                    correlationSection
                }
            }
            .padding(20)
        }
    }

    // MARK: Partner selection

    private var partnerPicker: some View {
        Picker("Compare against", selection: Binding(
            get: { viewModel.regressionPartner?.id ?? "" },
            set: { viewModel.selectRegressionPartner(id: $0) }
        )) {
            ForEach(viewModel.comparisonSeries) { series in
                Text("\(series.id) — \(series.title)").tag(series.id)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("relationship.partnerPicker")
    }

    // MARK: Scatter

    @ViewBuilder
    private var scatterSection: some View {
        GroupBox(scatterTitle) {
            if viewModel.scatterPoints.count < 3 {
                ContentUnavailableView {
                    Label("Not Enough Overlap", systemImage: "circle.dotted")
                } description: {
                    Text("These series share fewer than three observation dates in the selected window. Widen the window, or pick series with overlapping coverage.")
                }
                .frame(minHeight: 220)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    scatter
                    Text("Each point is one date on which both series reported. Lighter points are older; the line is the least-squares fit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var scatterTitle: String {
        guard let partner = viewModel.regressionPartner else { return "Relationship" }
        return "\(viewModel.mainSeries.id) against \(partner.id)"
    }

    private var scatter: some View {
        Chart {
            ForEach(viewModel.scatterPoints) { point in
                PointMark(
                    x: .value(viewModel.scatterXUnitsLabel, point.x),
                    y: .value(viewModel.scatterYUnitsLabel, point.y)
                )
                .symbolSize(36)
                .opacity(0.75)
                .foregroundStyle(by: .value("Date", point.date))
            }

            if let line = fittedLine {
                ForEach(line, id: \.x) { endpoint in
                    LineMark(
                        x: .value(viewModel.scatterXUnitsLabel, endpoint.x),
                        y: .value(viewModel.scatterYUnitsLabel, endpoint.y),
                        series: .value("Fit", "fit")
                    )
                    .foregroundStyle(.primary)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                }
            }
        }
        // A continuous scale keeps the legend to a gradient rather than one entry per point.
        .chartForegroundStyleScale(
            range: Gradient(colors: [Color.accentColor.opacity(0.25), Color.accentColor])
        )
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let doubleValue = value.as(Double.self) {
                        Text(xFormatter.formatAxisValue(doubleValue))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let doubleValue = value.as(Double.self) {
                        Text(yFormatter.formatAxisValue(doubleValue))
                    }
                }
            }
        }
        .chartXAxisLabel(viewModel.scatterXUnitsLabel, alignment: .center)
        .chartYAxisLabel(viewModel.scatterYUnitsLabel)
        .chartLegend(position: .bottom)
        .frame(minHeight: 340)
        .accessibilityIdentifier("relationship.scatter")
    }

    /// The fit drawn across the observed x-range only, so the line never implies
    /// predictions outside the data it was estimated from.
    private var fittedLine: [(x: Double, y: Double)]? {
        guard let regression = viewModel.regression,
              let minimumX = viewModel.scatterPoints.map(\.x).min(),
              let maximumX = viewModel.scatterPoints.map(\.x).max(),
              maximumX > minimumX else { return nil }

        return [
            (x: minimumX, y: regression.intercept + regression.slope * minimumX),
            (x: maximumX, y: regression.intercept + regression.slope * maximumX)
        ]
    }

    private var xFormatter: ValueFormatter {
        ValueFormatter(units: viewModel.scatterXUnitsLabel)
    }

    private var yFormatter: ValueFormatter {
        ValueFormatter(units: viewModel.scatterYUnitsLabel)
    }

    // MARK: Fit

    private func fitSection(_ regression: RegressionResult) -> some View {
        GroupBox("Least-Squares Fit") {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    FitStat(title: "R²", value: regression.formattedRSquared, detail: "Variance explained")
                    FitStat(title: "Slope", value: String(format: "%.4g", regression.slope), detail: slopeDetail)
                    FitStat(title: "t-statistic", value: regression.formattedTStatistic, detail: "Slope over its standard error")
                    FitStat(title: "Observations", value: "\(regression.sampleCount)", detail: "Aligned dates")
                }

                Text(regression.interpretation(
                    xUnits: viewModel.scatterXUnitsLabel,
                    yUnits: viewModel.scatterYUnitsLabel
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Label(
                    "A fit describes co-movement in this window. It is not evidence that one series causes the other.",
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var slopeDetail: String {
        "\(viewModel.scatterYUnitsLabel) per \(viewModel.scatterXUnitsLabel)"
    }

    // MARK: Correlation

    private var correlationSection: some View {
        GroupBox("Correlation with \(viewModel.mainSeries.id)") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(viewModel.comparisonSummaries) { summary in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(summary.seriesTitle)
                                .font(.headline)
                                .lineLimit(1)
                            Spacer()
                            Text("r = \(summary.formattedCorrelation)")
                                .font(.headline.monospacedDigit())
                        }
                        Text(summary.interpretation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

private struct FitStat: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
