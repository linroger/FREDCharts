import Foundation
import OSLog

enum AppLogger {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.rogerlin.fred-ultra"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let search = Logger(subsystem: subsystem, category: "Search")
    static let detail = Logger(subsystem: subsystem, category: "SeriesDetail")
    static let settings = Logger(subsystem: subsystem, category: "Settings")
    static let export = Logger(subsystem: subsystem, category: "Export")
}
