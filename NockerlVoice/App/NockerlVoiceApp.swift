import NockerlDesign
import SwiftData
import SwiftUI

/// Nockerl Voice: native macOS dictation. Double-tap Right ⌘ to start, single-tap
/// to stop; clean transcribed text is pasted into the frontmost app. Menu-bar only,
/// with one unified dashboard window.
@main
struct NockerlVoiceApp: App {
    @StateObject private var controller = DictationController()
    @StateObject private var permissions = PermissionsManager()

    init() {
        // Register the bundled Outfit / Space Mono faces with CoreText BEFORE first
        // paint. Belt-and-suspenders: the faces also auto-register lazily on
        // the first `.nockerlType(…)` resolution, but doing it in the App init
        // guarantees they're live for the very first frame (no first-paint SF flash).
        // Idempotent + @discardableResult; @StateObject defaults still apply since
        // this init assigns no stored property.
        NockerlFonts.registerIfNeeded()
        // Sparkle. Starts the updater and binds it to the user's preference. A
        // no-op while the build still carries the placeholder EdDSA key, so a
        // not-yet-configured build never shows an updater alert at launch.
        Updater.shared.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(controller)
                .environmentObject(permissions)
        } label: {
            MenuBarLabel(
                statusLabel: controller.status.label,
                permissions: permissions,
                guidanceRequestID: controller.permissionGuidanceRequestID
            )
        }
        .menuBarExtraStyle(.menu)
        .modelContainer(HistoryStore.shared.container)

        Window("Dashboard", id: "dashboard") {
            // NOTHING in this app draws a focus ring. Every window gets this, at the scene
            // root, because that is the one place the rule cannot be applied to one window and
            // forgotten on its twin. It was fixed per-view twice and came straight back both
            // times, because a per-view fix only clears the responder the window starts with:
            // click a button or press Tab afterwards and the ring is back.
            //
            // `focusEffectDisabled()` is the real control (macOS 14.0+, read off the SDK
            // interface, and the deployment target is exactly 14.0). It sets an environment
            // value every descendant inherits, so the effect is suppressed for the whole tree
            // permanently rather than for one moment at launch. Keyboard focus itself still
            // works for anyone navigating that way; only the ring, which does not belong in
            // this design, is gone.
            DashboardView()
                .focusEffectDisabled()
                .modelContainer(HistoryStore.shared.container)
                // Hybrid Dock: while the dashboard is open the app becomes a
                // real app (Dock + Cmd-Tab); closing it returns to menu-bar-only.
                // The dashboard-specific pair also records that THIS window is up, which is
                // what lets a failed dictation switch an already-open window to History
                // without ever opening or focusing one.
                .onAppear { WindowPresence.shared.dashboardOpened() }
                .onDisappear { WindowPresence.shared.dashboardClosed() }
        }
        .defaultSize(width: 880, height: 600)
        // Finder-style chrome: no title bar / toolbar strip. The window content
        // (one full-window geometric background) runs edge to edge under the
        // traffic lights, and the sidebar floats translucent on top of it.
        .windowStyle(.hiddenTitleBar)
        // BOTH axes locked. The other two windows already had this and this one was
        // simply missed, so it grew unbounded and the layout broke: the panes are laid
        // out for one size, not for an arbitrary one. `contentSize` pins the window to
        // whatever the content asks for, which is why DashboardView now states a fixed
        // frame rather than a minimum. A fixed HEIGHT costs nothing here because every
        // pane that can outgrow it, History most of all, is already scrollable.
        .windowResizability(.contentSize)

        Window("Set Up Nockerl Voice", id: "onboarding") {
            OnboardingView()
                .focusEffectDisabled()
                .environmentObject(permissions)
                .environmentObject(controller)
                // Hybrid Dock: the onboarding window also drives `.regular`
                // while open, so a first-run user (no Dock icon yet) still gets a
                // Dock presence for the setup window.
                .onAppear { WindowPresence.shared.windowOpened() }
                .onDisappear { WindowPresence.shared.windowClosed() }
        }
        .windowResizability(.contentSize)

        // First-launch welcome: a REAL native window (same scene style as
        // dashboard/onboarding), shown once on a fresh install BEFORE the permission
        // window. Participates in the Dock refcount exactly like its siblings, so
        // the Dock icon never strands.
        Window("Welcome to Nockerl Voice", id: "welcome") {
            WelcomeView()
                .focusEffectDisabled()
                .environmentObject(permissions)
                .onAppear { WindowPresence.shared.windowOpened() }
                .onDisappear { WindowPresence.shared.windowClosed() }
        }
        .windowResizability(.contentSize)
    }
}

/// The menu-bar icon, and also the launch hook: on its first appearance it opens
/// the dashboard window so the app isn't left hidden in the menu bar after launch.
/// (macOS 14 has no scene-level "present at launch" for `Window`; opening from the
/// always-present menu-bar label is the reliable equivalent.)
private struct MenuBarLabel: View {
    let statusLabel: String
    /// Read once at launch for the first-run permission check (part a). Plain `let`
    /// (not `@ObservedObject`): the label only READS the current grant state in its
    /// one-shot onAppear, it does not need to re-render on permission changes.
    let permissions: PermissionsManager
    /// The controller's `permissionGuidanceRequestID` (part b): a value the parent
    /// re-passes on every bump, so `.onChange` here fires each time the hotkey tap
    /// fails to start after launch (e.g. a re-check that still can't create the tap).
    let guidanceRequestID: Int
    @Environment(\.openWindow) private var openWindow
    @State private var openedAtLaunch = false
    /// Observed so the `welcomeShown` flip can be watched as an event (A-F2 replay).
    @ObservedObject private var settings = SettingsStore.shared
    /// A guidance signal that arrived while the first-run welcome still owned the flow.
    /// `permissionGuidanceRequestID` is ONE-SHOT, so suppressing it used to consume it
    /// forever: on a fresh install `startHotkey()` fails before the welcome is dismissed,
    /// which is exactly when the only bump happens. Held here instead, and replayed once
    /// the welcome is done (A-F2).
    @State private var pendingGuidance = false

    var body: some View {
        // The Voice mark as a menu-bar TEMPLATE image: macOS draws only its alpha and
        // tints it for light and dark menu bars, so the source is pure black and
        // `isTemplate` is set. The mark is square, so the footprint is 16x16 rather than
        // the framework mark's 18x16 (which carried an 8:7 aspect).
        //
        // 16 is deliberate, do not bump it to 18. The mark used to read small here, but
        // the cause was a loose viewBox that padded the artwork, not the box size: the
        // glyph occupied about 11pt of the 16pt box. With the tight viewBox it fills
        // roughly 14.4pt of the same box, which is where a status item glyph belongs in
        // a 24pt menu bar. At 18 the glyph would run past 16pt and crowd its neighbours.
        // This is the ONE mark still drawn app-side, and deliberately so: the package
        // offers product art as a SwiftUI Image, and a status item needs a tintable
        // template NSImage. See VoiceMark.swift.
        Image(nsImage: VoiceMark.statusItemImage(size: 16))
            .accessibilityLabel("Nockerl Voice: \(statusLabel)")
            .onAppear {
                guard !openedAtLaunch else { return }
                openedAtLaunch = true
                // Defer one runloop turn so the scene system is ready to honor
                // openWindow (calling it too early in onAppear is a no-op).
                DispatchQueue.main.async {
                    openWindow(id: "dashboard")
                    // Welcome before permissions: on a genuine first run, show the
                    // welcome window ALONE (orientation first). It chains to the permission
                    // window on completion, so the two never stack on a fresh install (the
                    // stacking mess the permission-window sequencing exists to fix).
                    // `welcomeShown` is bundle-id scoped through UserDefaults, so a dev
                    // build still gets a real first run.
                    if !SettingsStore.shared.welcomeShown {
                        openWindow(id: "welcome")
                    } else if !permissions.allGranted {
                        // First-run / TCC-reset guidance, resumed once the welcome has been
                        // seen: Microphone and Accessibility are REQUIRED. If either is missing
                        // at launch, auto-open the setup window. State-driven off the live
                        // grant, so once granted this passes and it never opens again.
                        //
                        // Asks `allGranted` rather than restating the list. The restated version
                        // here still named Input Monitoring after it stopped being required,
                        // which pinned this branch true and reopened the setup window at every
                        // single launch.
                        openWindow(id: "onboarding")
                    }
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            // Runtime hotkey-failure guidance: when `startHotkey()` cannot
            // create the CGEvent tap AFTER launch (Input Monitoring revoked / TCC reset),
            // the controller bumps `permissionGuidanceRequestID`; surface the SAME setup
            // window rather than let the hotkey stay silently dead. openWindow on an
            // already-open onboarding just refocuses it (idempotent, no loop, no nag).
            .onChange(of: guidanceRequestID) { _, _ in
                // While the first-run welcome still owns the flow, DEFER the
                // permission window so a runtime hotkey-failure signal cannot stack it
                // behind the welcome. Deferred, not dropped (A-F2): the signal is one-shot,
                // so discarding it here lost the guidance for the whole session. Once the
                // welcome has been seen this is exactly the normal runtime guidance.
                guard settings.welcomeShown else {
                    pendingGuidance = true
                    return
                }
                surfaceGuidance()
            }
            // A-F2 replay: the welcome just finished. If a guidance signal arrived while it
            // was up, honor it now instead of leaving the hotkey silently dead.
            .onChange(of: settings.welcomeShown) { _, shown in
                guard shown, pendingGuidance else { return }
                pendingGuidance = false
                surfaceGuidance()
            }
    }

    /// Open (or refocus) the permission window. `openWindow` on an already-open onboarding
    /// just refocuses it, so this is idempotent no matter which path calls it.
    private func surfaceGuidance() {
        openWindow(id: "onboarding")
        NSApp.activate(ignoringOtherApps: true)
    }
}
