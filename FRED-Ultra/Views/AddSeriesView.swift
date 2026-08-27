import SwiftUI

struct AddSeriesView: View {
    @StateObject private var searchViewModel = SearchViewModel()
    @Environment(\.dismiss) private var dismiss

    let existingSeriesIDs: Set<String>
    let onSelect: (FREDSeries) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if searchViewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = searchViewModel.errorMessage {
                    ContentUnavailableView {
                        Label("Search Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    }
                } else if searchViewModel.results.isEmpty, searchViewModel.hasSearched {
                    ContentUnavailableView {
                        Label("No Matches", systemImage: "magnifyingglass")
                    } description: {
                        Text("No FRED series matched “\(searchViewModel.trimmedQuery)”.")
                    }
                } else if searchViewModel.results.isEmpty {
                    ContentUnavailableView(
                        "Search for a Series",
                        systemImage: "magnifyingglass",
                        description: Text("Find another FRED series to add to the chart.")
                    )
                } else {
                    List(searchViewModel.results) { series in
                        let isAdded = existingSeriesIDs.contains(series.id)

                        Button {
                            onSelect(series)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(series.title)
                                        .font(.headline)
                                        .lineLimit(2)

                                    Spacer(minLength: 8)

                                    if isAdded {
                                        Text("Added")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Text("\(series.id) • \(series.units.isEmpty ? "Units n/a" : series.units)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .disabled(isAdded)
                    }
                }
            }
            .searchable(text: $searchViewModel.query, prompt: "Search economic data")
            .navigationTitle("Compare Series")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 540)
    }
}
