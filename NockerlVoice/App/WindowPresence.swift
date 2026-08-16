import AppKit
import Foundation

/// Tracks the open/close lifecycle of the app's primary windows and drives the
/// Dock activation policy.
///
/// Nockerl Voice is normally a menu-bar app (`LSUIElement`, no Dock icon), but it
/// should become a REAL app while a primary window is up: `.regular` puts it in the
/// Dock and Cmd-Tab so the window has a normal app presence; `.accessory` (no Dock
/// icon) returns once every primary window has closed.
///
/// A COUNTER (not a boolean) is deliberate: at first run the app auto-opens BOTH the
/// dashboard and the onboarding window (the latter whenever a required permission is
/// missing). Closing either one while the other is still
/// open must NOT drop the app back to `.accessory`: the Dock icon should stay until
/// the LAST primary window closes. The count is the minimal correct primitive.
///
/// `@MainActor`: `NSApp.setActivationPolicy` must run on the main thread, and the
/// view `.onAppear`/`.onDisappear` hooks that drive it are main-thread by
/// construction.
@MainActor
final class WindowPresence {
    /// Shared because it is app-level state referenced from view lifecycle hooks
    /// (matches the app's existing singleton pattern: SettingsStore/HistoryStore.shared).
    static let shared = WindowPresence()

    /// Number of currently-open primary windows (dashboard + onboarding).
    private var openCount = 0 {
        didSet { apply() }
    }

    private init() {}

    /// Open dashboard windows specifically, tracked separately from the total because
    /// "is the dashboard on screen" is a different question from "is any window on screen".
    private var dashboardCount = 0

    /// Whether a dashboard window is currently on screen.
    ///
    /// Deliberately a READ of state the scene lifecycle already maintains, not a query into
    /// AppKit. Nothing here can present, order-front or activate anything, so a caller that
    /// checks this cannot accidentally steal focus.
    var isDashboardOpen: Bool { dashboardCount > 0 }

    /// A primary window's content appeared -> it is open.
    func windowOpened() { openCount += 1 }

    /// A primary window's content disappeared -> it closed. Clamped at 0.
    func windowClosed() { openCount = max(0, openCount - 1) }

    /// The DASHBOARD window's content appeared. Also counts toward the Dock refcount.
    func dashboardOpened() {
        dashboardCount += 1
        windowOpened()
    }

    /// The DASHBOARD window's content disappeared. Clamped at 0.
    func dashboardClosed() {
        dashboardCount = max(0, dashboardCount - 1)
        windowClosed()
    }

    private func apply() {
        // `.regular` only while at least one primary window is open; `.accessory`
        // (menu-bar-only, no Dock icon) once the last one closes. This is the
        // hybrid Dock behavior: regular while a primary window is open, accessory
        // otherwise.
        NSApp.setActivationPolicy(openCount > 0 ? .regular : .accessory)
    }
}
