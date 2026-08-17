import AppKit

/// A one-shot signal that the user asked for the app "again" with no window on screen.
///
/// macOS calls `applicationShouldHandleReopen` for the two gestures that mean "bring this
/// back": clicking the Dock icon, and launching an app that is already running. With no
/// delegate there was nothing listening, so both did nothing at all. That is a dead end a
/// user finds by accident: the Dock icon is right there, clicking it is the obvious move,
/// and the only way back was the menu bar item they may never have noticed.
///
/// It became reachable the moment the app started keeping its Dock icon after the last
/// window closed. Before that the icon disappeared with the window, so there was nothing to
/// click and nothing to fix.
///
/// The same one-shot counter shape as `permissionGuidanceRequestID`: the delegate cannot
/// call SwiftUI's `openWindow`, so it bumps a value and a view that DOES hold the
/// environment action reacts. A counter rather than a flag, so two reopens in a row are two
/// events rather than one.
@MainActor
final class ReopenRequest: ObservableObject {
    static let shared = ReopenRequest()
    private init() {}

    @Published private(set) var id = 0

    func request() { id &+= 1 }
}

/// Exists only for `applicationShouldHandleReopen`. SwiftUI has no scene-level equivalent.
final class NockerlAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // `flag` is true when a window is already up, in which case AppKit's default of
        // un-minimising and ordering front is right and there is nothing to add.
        if !flag {
            MainActor.assumeIsolated { ReopenRequest.shared.request() }
        }
        return true
    }
}
