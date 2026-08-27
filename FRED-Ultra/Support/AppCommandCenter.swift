import Foundation

/// Bridges menu-bar commands to whichever series detail view is on screen.
///
/// Replaces broadcast `NotificationCenter` posts: the menu can now *disable* Refresh,
/// Export, and Copy when no series is open, instead of firing commands into the void.
@MainActor
final class AppCommandCenter: ObservableObject {
    static let shared = AppCommandCenter()

    struct Handlers {
        let refresh: () -> Void
        let exportCSV: () -> Void
        let exportJSON: () -> Void
        let copyToClipboard: () -> Void
    }

    /// True while a series detail view is registered, i.e. the data commands are live.
    @Published private(set) var isSeriesActive = false

    private var ownerToken: String?
    private var handlers: Handlers?

    init() {}

    func register(token: String, handlers: Handlers) {
        ownerToken = token
        self.handlers = handlers
        isSeriesActive = true
    }

    /// Ignores stale unregistrations: when the user switches series, SwiftUI may deliver
    /// the outgoing view's `onDisappear` after the incoming view has already registered.
    func unregister(token: String) {
        guard ownerToken == token else { return }
        ownerToken = nil
        handlers = nil
        isSeriesActive = false
    }

    func refresh() { handlers?.refresh() }
    func exportCSV() { handlers?.exportCSV() }
    func exportJSON() { handlers?.exportJSON() }
    func copyToClipboard() { handlers?.copyToClipboard() }
}
