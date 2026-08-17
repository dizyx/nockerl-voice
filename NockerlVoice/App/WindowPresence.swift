import AppKit
import Foundation

/// Tracks the open/close lifecycle of the app's primary windows.
///
/// The activation policy is promoted ONE WAY, from accessory to regular, the first time a
/// primary window opens, and never demoted. See `apply()`: the demotion is what could leave
/// the app running and unreachable.
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

    /// Set once the app has been promoted to `.regular`. It is never demoted again.
    private var promoted = false

    private func apply() {
        // ONE WAY ONLY. Accessory at launch, regular the moment a primary window opens,
        // and NEVER back again for the life of the process.
        //
        // The downward transition is the one that broke: closing the dashboard with the
        // red button removed the Dock icon AND the menu bar item, leaving the app running
        // and unreachable short of Activity Monitor. An app may have a Dock icon and a menu
        // bar or neither, never the menu bar alone while regular, and moving between the
        // policies can leave the menu disabled until the user clicks the Dock icon that the
        // same transition just took away.
        //
        // The previous fix was to stop changing the policy at all. That removed the crash
        // but also the app: no Dock icon, no launcher entry, and no application menu to
        // quit from, so it stopped behaving like a real app at all. Staying regular keeps
        // every one of those and still never performs the transition that strands it.
        //
        // The cost is a Dock icon that outlives the window that earned it, until the app
        // quits. That is ordinary Mac behaviour, and it is the right side of this trade:
        // an app that is visible when it has nothing open is a much smaller problem than an
        // app that is invisible while running.
        guard openCount > 0, !promoted else { return }
        promoted = true
        NSApp.setActivationPolicy(.regular)
    }

}
