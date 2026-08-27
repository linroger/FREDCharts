import SwiftUI

// MARK: - Detail Surface Components
//
// Small presentational pieces shared by the series detail surfaces. They hold no state
// and read nothing beyond what they are handed.

/// A one-shot alert describing the outcome of an export or clipboard copy.
struct ExportNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct NoticeLabel: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct HeaderBadge: View {
    let symbol: String
    let label: String

    var body: some View {
        Label(label, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct InsightStatCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
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
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
