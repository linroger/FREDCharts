import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = SettingsManager.shared
    @State private var draftAPIKey = SettingsManager.shared.apiKey
    @State private var isTestingAPIKey = false
    @State private var validationResult: APIKeyValidationResult?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    SecureField("FRED API Key", text: $draftAPIKey)
                        .textFieldStyle(.roundedBorder)

                    Button(action: validateAndSave) {
                        if isTestingAPIKey {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Validate")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingAPIKey)
                }

                if let validationResult {
                    Label(validationResult.message, systemImage: validationResult.isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(validationResult.isValid ? .green : .red)
                }

                Link("Get a free FRED API key", destination: URL(string: "https://fred.stlouisfed.org/docs/api/api_key.html")!)
                    .font(.callout)
            } header: {
                Text("FRED API")
            } footer: {
                Text("The API key is stored locally in UserDefaults on this Mac. It is only used to make requests to the official FRED API.")
            }

            Section("Workspace Data") {
                LabeledContent("Favorites", value: "\(settings.favorites.count)")
                LabeledContent("Recent Searches", value: "\(settings.recentSearches.count)")

                if !settings.recentSearches.isEmpty {
                    Button("Clear Recent Searches", role: .destructive) {
                        settings.clearRecentSearches()
                    }
                }
            }

            Section("Help & References") {
                Link("FRED Website", destination: URL(string: "https://fred.stlouisfed.org")!)
                Link("FRED API Documentation", destination: URL(string: "https://fred.stlouisfed.org/docs/api/fred/")!)
                Link("Federal Reserve Data Terms of Use", destination: URL(string: "https://fred.stlouisfed.org/legal/")!)
            }

            Section("About") {
                LabeledContent("App Version", value: "1.0")
                Text("FRED Ultra is a desktop research tool for searching, comparing, and exporting Federal Reserve economic time-series data.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(minWidth: 460, minHeight: 420)
    }

    private func validateAndSave() {
        isTestingAPIKey = true
        validationResult = nil

        Task {
            do {
                try await FREDService.shared.validateAPIKey(draftAPIKey)
                settings.updateAPIKey(draftAPIKey)
                validationResult = APIKeyValidationResult(isValid: true, message: "API key validated and saved.")
                AppLogger.settings.info("Validated API key from Settings")
            } catch {
                validationResult = APIKeyValidationResult(isValid: false, message: error.localizedDescription)
                AppLogger.settings.error("Settings validation failed: \(error.localizedDescription, privacy: .public)")
            }

            isTestingAPIKey = false
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
