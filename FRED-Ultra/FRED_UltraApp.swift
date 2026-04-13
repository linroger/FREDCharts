import SwiftUI

@main
struct FRED_UltraApp: App {
    @StateObject private var settings = SettingsManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .frame(minWidth: 1080, minHeight: 720)
                .onAppear {
                    AppLogger.app.info("FRED Ultra window appeared")
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Data") {
                Button("Refresh") {
                    NotificationCenter.default.post(name: .refreshData, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button("Export as CSV…") {
                    NotificationCenter.default.post(name: .exportCSV, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Export as JSON…") {
                    NotificationCenter.default.post(name: .exportJSON, object: nil)
                }
            }
        }

        Settings {
            SettingsView()
        }
    }
}

extension Notification.Name {
    static let refreshData = Notification.Name("refreshData")
    static let exportCSV = Notification.Name("exportCSV")
    static let exportJSON = Notification.Name("exportJSON")
}
