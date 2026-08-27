import Foundation
import OSLog

/// Unified logging categories. Categories mirror user-visible workflows so
/// `log stream --predicate 'subsystem == "…"'` reads like a session transcript.
enum AppLogger {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.rogerlin.fred-ultra"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let search = Logger(subsystem: subsystem, category: "Search")
    static let detail = Logger(subsystem: subsystem, category: "SeriesDetail")
    static let settings = Logger(subsystem: subsystem, category: "Settings")
    static let export = Logger(subsystem: subsystem, category: "Export")
    static let network = Logger(subsystem: subsystem, category: "Network")
}
