import SwiftUI

/// The chart as it is exported: the same marks, wrapped in enough context that the image
/// stands on its own once it has left the app.
///
/// An unlabelled plot pasted into a document is close to useless a week later — nobody
/// can say which series it is, over what window, or under which transform. This card
/// carries all of that plus the source attribution FRED's terms ask for.
struct ChartSnapshotView: View {
    @ObservedObject var viewModel: SeriesDetailViewModel
    var size: CGSize

    /// Exported at a fixed size so the renderer has a defined layout and the output is
    /// reproducible regardless of the window the reader happens to have open.
    static let defaultSize = CGSize(width: 1_100, height: 720)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(viewModel.mainSeries.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .lineLimit(2)

                Text(viewModel.chartExportSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            SeriesPlot(viewModel: viewModel, selectedDate: nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(alignment: .firstTextBaseline) {
                Text(viewModel.chartExportAttribution)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text("FRED Ultra")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(width: size.width, height: size.height)
        // An explicit background: a transparent PNG dropped onto a dark slide is unreadable.
        .background(Color(nsColor: .textBackgroundColor))
    }
}
