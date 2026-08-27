import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = SettingsManager.shared

    @State private var draftAPIKey = ""
    @State private var isTestingAPIKey = false
    @State private var validationResult: APIKeyValidationResult?
    @State private var cachedSeriesCount = 0
    @State private var showingClearKeyConfirmation = false

    private var appVersion: String {
        let marketing = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(marketing) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    SecureField("FRED API Key", text: $draftAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("settings.apiKeyField")
                        .onSubmit(validateAndSave)

                    Button(action: validateAndSave) {
                        if isTestingAPIKey {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Validate & Save")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingAPIKey)
                    .accessibilityIdentifier("settings.validateButton")
                }

                if let validationResult {
                    Label(validationResult.message, systemImage: validationResult.isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(validationResult.isValid ? .green : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LabeledContent("Storage", value: settings.apiKeyStorage.rawValue)

                if settings.hasValidAPIKey {
                    Button("Remove Saved API Key", role: .destructive) {
                        showingClearKeyConfirmation = true
                    }
                }

                Link("Get a free FRED API key", destination: URL(string: "https://fred.stlouisfed.org/docs/api/api_key.html")!)
                    .font(.callout)
            } header: {
                Text("FRED API")
            } footer: {
                Text(settings.apiKeyStorage.explanation)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Shade U.S. recessions on charts", isOn: Binding(
                    get: { settings.showsRecessionShading },
                    set: { settings.setRecessionShading($0) }
                ))
            } header: {
                Text("Charts")
            } footer: {
                Text("Uses the NBER-based recession indicator (USREC), the same dating FRED uses for the shaded bands on its own charts.")
                    .foregroundStyle(.secondary)
            }

            Section("Workspace Data") {
                LabeledContent("Favorites", value: "\(settings.favorites.count)")
                LabeledContent("Recent Searches", value: "\(settings.recentSearches.count)")
                LabeledContent("Cached Series", value: "\(cachedSeriesCount)")

                if !settings.recentSearches.isEmpty {
                    Button("Clear Recent Searches", role: .destructive) {
                        settings.clearRecentSearches()
                    }
                }

                if !settings.favorites.isEmpty {
                    Button("Clear Favorites", role: .destructive) {
                        settings.clearFavorites()
                    }
                }

                Button("Clear Downloaded Observations") {
                    Task {
                        await FREDService.shared.clearCaches()
                        await refreshCacheCount()
                    }
                }
                .help("Discards locally cached FRED responses so the next load fetches fresh data")
            }

            Section("Help & References") {
                Link("FRED Website", destination: URL(string: "https://fred.stlouisfed.org")!)
                Link("FRED API Documentation", destination: URL(string: "https://fred.stlouisfed.org/docs/api/fred/")!)
                Link("Federal Reserve Data Terms of Use", destination: URL(string: "https://fred.stlouisfed.org/legal/")!)
            }

            Section("About") {
                LabeledContent("App Version", value: appVersion)
                Text("FRED Ultra is a desktop research tool for searching, comparing, transforming, and exporting Federal Reserve economic time-series data. It talks only to the official FRED API.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(minWidth: 480, minHeight: 480)
        .task {
            // The field deliberately starts empty: a saved key lives in the Keychain and
            // is never read back into the UI. "Storage" below reports where it is kept.
            await refreshCacheCount()
        }
        .confirmationDialog(
            "Remove the saved FRED API key?",
            isPresented: $showingClearKeyConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Key", role: .destructive) {
                settings.clearAPIKey()
                draftAPIKey = ""
                validationResult = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("FRED Ultra will return to the welcome screen until a new key is validated.")
        }
    }

    private func refreshCacheCount() async {
        cachedSeriesCount = await FREDService.shared.cachedSeriesCount
    }

    private func validateAndSave() {
        let candidate = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !isTestingAPIKey else { return }

        isTestingAPIKey = true
        validationResult = nil

        Task {
            defer { isTestingAPIKey = false }

            do {
                try await FREDService.shared.validateAPIKey(candidate)
                let storage = settings.updateAPIKey(candidate)
                draftAPIKey = ""
                validationResult = APIKeyValidationResult(isValid: true, message: "API key validated and saved. \(storage.explanation)")
                AppLogger.settings.info("Validated API key from Settings (\(storage.rawValue, privacy: .public))")
            } catch {
                validationResult = APIKeyValidationResult(isValid: false, message: SearchViewModel.describe(error))
                AppLogger.settings.error("Settings validation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

private struct APIKeyValidationResult {
    let isValid: Bool
    let message: String
}

#Preview {
    SettingsView()
}
