import AppKit
import Foundation

/// Tracks the open/close lifecycle of the app's primary windows.
///
/// It no longer touches the activation policy. See `apply()` for why: the hybrid Dock
/// behaviour this once implemented could leave the app running and unreachable.
///
/// A COUNTER (not a boolean) is deliberate: at first run the app auto-opens BOTH the
/// dashboard and the onboarding window (the latter whenever a required permission is
/// missing). Closing either one while the other is still
/// open must NOT drop the app back to `.accessory`: the Dock icon should stay until
/// the LAST primary window closes. The count is the minimal correct primitive.
///
/// `@MainActor`: the view `.onAppear`/`.onDisappear` hooks that drive this are
/// main-thread by construction, and `isDashboardOpen` is read from main-actor code.
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
        // THE POLICY IS NEVER CHANGED. This deliberately does nothing to it, and the
        // counter above survives only because `isDashboardOpen` is still a real question
        // that other code asks.
        //
        // It used to flip to `.regular` while a window was open and back to `.accessory`
        // when the last one closed. That downward transition could leave the app
        // completely unreachable: closing the dashboard with the red button removed the
        // Dock icon AND the menu bar item, with the app still running and no way to reach
        // it short of Activity Monitor. Observed on 2026-08-17.
        //
        // The cause is a documented AppKit limitation, not a bug in this file. An app may
        // have a Dock icon and a menu bar, or neither; it cannot have the menu bar alone
        // while `.regular`. Worse, moving between policies is unreliable in exactly this
        // direction: the menu can be left disabled and unclickable until the user clicks
        // the Dock icon, which the same transition has just taken away. A user with no
        // Terminal would have had to reboot.
        //
        // Staying `.accessory` is not a workaround, it is what `LSUIElement` in the
        // Info.plist already declares this app to be, and it is the state the app launches
        // in and works correctly in. Windows still open, still take focus and still work
        // under `.accessory`; only the Dock icon and the Cmd-Tab entry are given up while
        // one is open. That is a real cost, and it buys back an entire class of failure
        // where the app can be running and impossible to reach.
    }
}
