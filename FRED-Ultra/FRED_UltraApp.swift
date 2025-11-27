//
//  FRED_UltraApp.swift
//  FRED-Ultra
//
//  Created by Roger Lin on 12/11/24.
//

import SwiftUI

@main
struct FRED_UltraApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .frame(width: 400, height: 300)
        }
        #endif
    }
}
