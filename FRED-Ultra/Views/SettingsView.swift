import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = SettingsManager.shared

    var body: some View {
        Form {
            Section(header: Text("API Configuration")) {
                SecureField("FRED API Key", text: $settings.apiKey)
                Text("You can get a free API key from the FRED website.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("About")) {
                Text("FRED-Ultra v1.0")
                Link("Visit FRED Website", destination: URL(string: "https://fred.stlouisfed.org")!)
            }
        }
        .navigationTitle("Settings")
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
