import Foundation
import Sparkle

/// Owns the Sparkle updater.
///
/// Sparkle is the standard updater for notarized, directly-distributed Mac apps. The Mac
/// App Store is not an option here: the global hotkey needs a `CGEventTap` and paste
/// insertion needs Accessibility, and both require an un-sandboxed app, which MAS forbids.
///
/// This type is the ONLY place Sparkle is imported. `SettingsStore` owns the user
/// preference and stays Sparkle-free, because it is compiled into the unit-test bundle;
/// the preference reaches Sparkle through the `applyAutomaticUpdateChecks` bridge wired in
/// `start()`.
///
/// PRIVACY: Sparkle's optional anonymous system profile is explicitly disabled below, and
/// also set to false in Info.plist. An update check already reveals an IP and a version to
/// the feed host; nothing further is sent. The README promises no telemetry.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    /// The placeholder `SUPublicEDKey` shipped in Info.plist (32 zero bytes, base64) until
    /// the real EdDSA keypair is generated. Kept here so `isConfigured` can recognise it.
    private static let placeholderPublicKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    /// Nil until `start()` runs, and it stays nil while the build carries the placeholder key.
    private var updater: SPUUpdater?

    /// Retained for the updater's lifetime. `SPUUpdater` does not own its user driver.
    private var driver: NockerlUpdateDriver?

    /// True when the build carries a REAL EdDSA public key, i.e. updates can actually be
    /// verified. While the placeholder is in place the updater is never instantiated and no
    /// feed is ever fetched, which keeps a misconfigured build from surfacing anything at
    /// launch. That matters more than usual here: this app is driven by a global hotkey, and
    /// a dialog that seizes focus mid-dictation can eat the transcript.
    static var isConfigured: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else { return false }
        return !key.isEmpty && key != placeholderPublicKey
    }

    /// Whether a manual "Check for Updates" can run right now.
    @Published private(set) var canCheckForUpdates = false

    private init() {}

    /// Start the updater and bind it to the user's preference. Idempotent, so calling it
    /// again at launch is harmless. No-op while the public key is a placeholder.
    ///
    /// This builds `SPUUpdater` directly with OUR user driver rather than taking
    /// `SPUStandardUpdaterController`. The standard controller is a convenience wrapper that
    /// bundles `SPUStandardUserDriver`, and that driver's scheduled-update path is the
    /// focus-stealing modal this app cannot tolerate. Everything else the wrapper provided
    /// (starting the updater, exposing it for binding, validating the menu item) is a few
    /// lines and is reproduced below.
    func start() {
        guard updater == nil, Self.isConfigured else { return }

        let driver = NockerlUpdateDriver()
        let updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: driver,
            delegate: nil
        )

        // PRIVACY: no anonymous system profile, ever. Belt and braces with Info.plist.
        updater.sendsSystemProfile = false
        // Consent is per update, never implicit. Sparkle must not stage anything on its own.
        updater.automaticallyDownloadsUpdates = false
        updater.automaticallyChecksForUpdates = SettingsStore.shared.checkForUpdatesAutomatically

        do {
            // `start()`, not `startUpdater()`: the Objective-C selector is startUpdater but
            // Sparkle renames it for Swift, and the old spelling is marked obsoleted so it is a
            // hard error rather than a deprecation.
            try updater.start()
        } catch {
            // A misconfigured updater must fail silently and stay off. The menu item remains
            // disabled, so it is visibly unavailable rather than a dead action.
            DebugLog.write("updater: start FAILED :: \(error.localizedDescription)")
            return
        }

        self.driver = driver
        self.updater = updater

        // Forward later preference changes to Sparkle. SettingsStore persists the value and
        // calls this from its didSet, the same shape as launchAtLogin delegating to
        // SMAppService, minus the third-party import.
        SettingsStore.shared.applyAutomaticUpdateChecks = { [weak updater] enabled in
            updater?.automaticallyChecksForUpdates = enabled
        }

        canCheckForUpdates = true

        // Check ONCE at launch when the preference is on, which is what "check for updates
        // automatically" says and what it was not doing. Sparkle's scheduler works off
        // `updateCheckInterval`, which defaults to roughly a day and is measured from the
        // last check, so someone who quits nightly could go a long time without one and
        // would reasonably conclude the setting did nothing.
        //
        // `checkForUpdatesInBackground`, not `checkForUpdates`: the background form reports
        // through our driver without presenting anything, which is what keeps discovery
        // quiet. Sparkle's own documentation names this exact call for forcing a check on
        // every launch, and warns to make it immediately after starting the updater and
        // only while automatic checks are enabled, because calling it later interferes with
        // the scheduler.
        if updater.automaticallyChecksForUpdates {
            DispatchQueue.main.async { updater.checkForUpdatesInBackground() }
        }
    }

    /// A user-initiated check, from the menu bar. Does nothing until the real key lands.
    ///
    /// This is the ONLY entry point that may put a visible update flow on screen, and it can
    /// only be reached by the user picking the menu item. Discovery never calls it.
    func checkForUpdates() {
        updater?.checkForUpdates()
    }

    /// Bring the quietly-discovered update forward, from the menu bar entry that appears once
    /// something has been found. Routed through the same user-initiated check so Sparkle
    /// re-presents the update through our driver with `state.userInitiated` true.
    func openDiscoveredUpdate() {
        updater?.checkForUpdates()
    }
}
