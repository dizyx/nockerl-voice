import Foundation

/// The SINGLE SOURCE OF TRUTH for every per-install data location: the Keychain
/// service, the Application Support subtree, and the log directory, all derived
/// from the running build's bundle identifier.
///
/// Why this exists: those three locations used to be hardcoded strings duplicated
/// across `KeychainStore`, `RecordingStore`, and `DebugLog`. A development build
/// under a DIFFERENT bundle id therefore read the same Keychain item and shared the
/// same Recordings folder as the real install, so a dev/test run could read the
/// production install's OpenRouter key or DELETE its real recordings. Routing every
/// location through the bundle id makes each build own a distinct namespace, which
/// is what lets side-by-side first-run testing be safe.
///
/// BYTE-IDENTICAL UNDER PRODUCTION (no migration, no data move): for the production
/// bundle id these resolve to the exact paths in use before this change: the
/// Keychain service already WAS the bundle-id literal, and the directories keep the
/// human "NockerlVoice" name. Any non-production build (a different id, or a
/// misconfigured nil id) is routed to an isolated namespace instead.
enum AppPaths {
    /// The production bundle identifier. This is the ONE literal in the codebase, and
    /// its ONLY job is to decide whether the running build is production (→ today's
    /// paths, so an existing install never migrates) or a fork (→ an isolated namespace).
    /// Everything data-routing derives from `Bundle.main.bundleIdentifier`, not this.
    static let productionBundleID = "com.dizyx.nockerlvoice"

    /// The running build's bundle id. A misconfigured build with a nil identifier gets
    /// a CLEARLY non-production namespace (never the bare production literal), so it
    /// can never alias production data.
    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "\(productionBundleID).unconfigured"
    }

    /// True only when the running build IS the production install.
    static var isProduction: Bool { bundleID == productionBundleID }

    /// The Keychain generic-password `service`. Derived straight from the bundle id:
    /// under production this equals the pre-change literal `com.dizyx.nockerlvoice`;
    /// a fork gets its own service and cannot read the production key.
    static var keychainService: String { bundleID }

    /// The on-disk namespace segment for the app's own directories. Production keeps
    /// the human "NockerlVoice" folder name (byte-identical, no data move); a fork
    /// uses its full bundle id, so its files live in a distinct folder it fully owns.
    static var directoryNamespace: String { isProduction ? "NockerlVoice" : bundleID }

    /// `…/Application Support/<namespace>/Recordings`: the kept-audio durability
    /// safety net. Falls back to the temporary directory if Application Support is
    /// unavailable (the same fallback `RecordingStore` always used). Under production:
    /// `…/Application Support/NockerlVoice/Recordings`, exactly as before.
    static var recordingsDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        // One appended component (`"<namespace>/Recordings"`), so under production the
        // appended string is the exact original `"NockerlVoice/Recordings"`.
        return base.appendingPathComponent("\(directoryNamespace)/Recordings", isDirectory: true)
    }

    /// `~/Library/Logs/<namespace>`: the append-only debug-log directory. Under
    /// production: `~/Library/Logs/NockerlVoice`, exactly as before.
    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(directoryNamespace)", isDirectory: true)
    }

    /// The SwiftData transcription-history store URL, or `nil` to keep SwiftData's
    /// DEFAULT store.
    ///
    /// UNLIKE the directories above, the history store's legacy location is SwiftData's
    /// INTERNAL default: `HistoryStore` passes no url today, and because the app is
    /// non-sandboxed that default is NOT inside a per-bundle-id container, so every
    /// build (any id) opened the SAME store. There is no controllable "NockerlVoice"
    /// path that equals that internal default, so we do NOT try to name it: PRODUCTION
    /// returns `nil` and `HistoryStore` keeps opening the exact same default store it
    /// opens today: **byte-identical by construction, no migration, no data move for
    /// an existing install**. Only a NON-production build gets its OWN namespaced store,
    /// so a dev/test build can never open (or `deleteAll()`) the production install's
    /// real history. (A nil bundle id resolves to `…unconfigured`, i.e. non-production,
    /// so it too is redirected away from the default store, never onto production data.)
    static var historyStoreURL: URL? {
        guard !isProduction else { return nil }
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        // A fork's store lives beside its Recordings, under its own bundle-id namespace
        // (`directoryNamespace` == the bundle id for any non-production build).
        return base.appendingPathComponent("\(directoryNamespace)/history.store", isDirectory: false)
    }
}
