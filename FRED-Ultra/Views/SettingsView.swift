import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = SettingsManager.shared
    @State private var showingAPIKeyHelp = false
    @State private var testingAPIKey = false
    @State private var apiKeyTestResult: APIKeyTestResult?
    
    var body: some View {
        Form {
            Section {
                HStack {
                    SecureField("FRED API Key", text: $settings.apiKey)
                        .textFieldStyle(.roundedBorder)
                    
                    Button(action: testAPIKey) {
                        if testingAPIKey {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Text("Test")
                        }
                    }
                    .disabled(settings.apiKey.isEmpty || testingAPIKey)
                }
                
                if let result = apiKeyTestResult {
                    HStack {
                        Image(systemName: result.isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.isValid ? .green : .red)
                        Text(result.message)
                            .font(.caption)
                            .foregroundStyle(result.isValid ? .green : .red)
                    }
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("You need a free API key from FRED to use this app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Link(destination: URL(string: "https://fred.stlouisfed.org/docs/api/api_key.html")!) {
                        Label("Get a Free API Key", systemImage: "key")
                    }
                }
            } header: {
                Text("API Configuration")
            } footer: {
                Text("Your API key is stored securely on your device.")
            }
            
            Section("Data") {
                HStack {
                    Text("Favorites")
                    Spacer()
                    Text("\(settings.favorites.count)")
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Text("Recent Searches")
                    Spacer()
                    Text("\(settings.recentSearches.count)")
                        .foregroundStyle(.secondary)
                }
                
                if !settings.recentSearches.isEmpty {
                    Button("Clear Recent Searches") {
                        settings.clearRecentSearches()
                    }
                }
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("1.0.0")
                        .foregroundStyle(.secondary)
                }
                
                Link(destination: URL(string: "https://fred.stlouisfed.org")!) {
                    Label("FRED Website", systemImage: "globe")
                }
                
                Link(destination: URL(string: "https://fred.stlouisfed.org/docs/api/fred/")!) {
                    Label("API Documentation", systemImage: "book")
                }
            }
            
            Section("Acknowledgments") {
                Text("This app uses data from the Federal Reserve Economic Data (FRED) service provided by the Federal Reserve Bank of St. Louis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(minWidth: 400, minHeight: 350)
    }
    
    private func testAPIKey() {
        testingAPIKey = true
        apiKeyTestResult = nil
        
        Task {
            do {
                // Try a simple search to test the API key
                _ = try await FREDService.shared.searchSeries(query: "GDP", limit: 1)
                await MainActor.run {
                    apiKeyTestResult = APIKeyTestResult(isValid: true, message: "API key is valid!")
                    testingAPIKey = false
                }
            } catch FREDError.missingAPIKey {
                await MainActor.run {
                    apiKeyTestResult = APIKeyTestResult(isValid: false, message: "Please enter an API key")
                    testingAPIKey = false
                }
            } catch {
                await MainActor.run {
                    apiKeyTestResult = APIKeyTestResult(isValid: false, message: error.localizedDescription)
                    testingAPIKey = false
                }
            }
        }
    }
}

struct APIKeyTestResult {
    let isValid: Bool
    let message: String
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
