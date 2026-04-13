//
//  FRED_UltraApp.swift
//  FRED-Ultra
//
//  Created by Roger Lin on 12/11/24.
//

import SwiftUI

@main
struct FRED_UltraApp: App {
    @StateObject private var settings = SettingsManager.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.automatic)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            
            CommandMenu("Data") {
                Button("Refresh") {
                    NotificationCenter.default.post(name: .refreshData, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
                
                Divider()
                
                Button("Export as CSV...") {
                    NotificationCenter.default.post(name: .exportCSV, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                
                Button("Export as JSON...") {
                    NotificationCenter.default.post(name: .exportJSON, object: nil)
                }
            }
        }

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let refreshData = Notification.Name("refreshData")
    static let exportCSV = Notification.Name("exportCSV")
    static let exportJSON = Notification.Name("exportJSON")
}
