import SwiftUI

@main
struct FRED_UltraApp: App {
    @StateObject private var settings = SettingsManager.shared
    @StateObject private var commandCenter = AppCommandCenter.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .frame(minWidth: 1_040, minHeight: 680)
                .onAppear {
                    AppLogger.app.info("FRED Ultra window appeared")
                }
        }
        // `.contentMinSize` keeps the minimum honest while still letting the window be
        // resized freely; `.contentSize` pinned the window to its content.
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Data") {
                Button("Refresh Series") {
                    commandCenter.refresh()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!commandCenter.isSeriesActive)

                Divider()

                Button("Export as CSV…") {
                    commandCenter.exportCSV()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!commandCenter.isSeriesActive)

                Button("Export as JSON…") {
                    commandCenter.exportJSON()
                }
                .disabled(!commandCenter.isSeriesActive)

                Button("Copy Visible Data") {
                    commandCenter.copyToClipboard()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!commandCenter.isSeriesActive)
            }

            CommandGroup(replacing: .help) {
                Link("FRED API Documentation", destination: URL(string: "https://fred.stlouisfed.org/docs/api/fred/")!)
                Link("FRED Website", destination: URL(string: "https://fred.stlouisfed.org")!)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
