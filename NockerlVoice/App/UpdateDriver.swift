import Foundation
import Sparkle

/// Whether a dictation is in flight, readable from code that must never interrupt one.
///
/// A separate one-property type rather than a reference to `DictationController`, because the
/// updater must not retain the controller and does not need anything else from it. The
/// controller mirrors its own status here from the `didSet` it already had.
@MainActor
final class DictationActivity {
    static let shared = DictationActivity()
    private init() {}

    /// True while recording OR transcribing. Both are states where taking key focus would
    /// interrupt the user, so both count as busy.
    private(set) var isBusy = false

    func setBusy(_ busy: Bool) { isBusy = busy }
}

/// What the update UI should currently be showing.
///
/// `idle` and `available` are the only states reachable without the user asking for anything.
/// Everything past `available` requires an explicit opt-in, because it means bytes are moving.
enum UpdatePhase: Equatable {
    case idle
    /// Discovered, not acted on. This is the QUIET state: it drives a passive indicator only.
    case available(version: String)
    case checking
    case downloading(fraction: Double?)
    case extracting(fraction: Double)
    case readyToInstall
    case installing
    case upToDate
    case failed(String)
}

/// Observable state shared by the menu bar indicator and the in-app update panel.
@MainActor
final class UpdateModel: ObservableObject {
    static let shared = UpdateModel()
    private init() {}

    @Published private(set) var phase: UpdatePhase = .idle

    /// True when an update has been found and not yet acted on. The quiet indicator reads
    /// only this, so discovery never needs to present anything.
    var hasQuietUpdate: Bool {
        if case .available = phase { return true }
        return false
    }

    /// True while an update flow the user opted into is on screen.
    @Published var isPanelPresented = false

    fileprivate func setPhase(_ phase: UpdatePhase) { self.phase = phase }

    /// A background check found something. Called from the updater delegate rather than the
    /// user driver, because that is where a background check reports.
    ///
    /// Sets the quiet indicator ONLY. It holds no Sparkle callback, so acting on it has to
    /// run a real user-initiated check, which is exactly what the menu item and the sidebar
    /// row already do. Anything more would be presenting an update the user never asked to
    /// see, which is the behaviour this whole design avoids.
    func noteBackgroundDiscovery(version: String) {
        guard case .idle = phase else { return }
        // STICKY. Sparkle tears the background session down immediately after reporting,
        // and that teardown used to reset the phase, so the row appeared and vanished in
        // the same instant. A discovery is a fact about the world, not part of a session:
        // 1.0.11 still exists after the check that found it has ended.
        discovered = version
        phase = .available(version: version)
    }

    /// A version found by a background check, held across session teardown.
    private(set) var discovered: String?

    /// Act on the row. Runs a real user-initiated check when there is no live session,
    /// which is ALWAYS the case for a background discovery.
    ///
    /// This is not the same as `respond(.install)`. That answers a question Sparkle is
    /// currently asking, and after a background check Sparkle is asking nothing: the
    /// session is already over and no reply is held. Calling it would have silently done
    /// nothing, which is the same dead end this whole file was written to remove. A real
    /// check re-runs the flow with a live reply behind it.
    func install() {
        if updateChoiceReply != nil || installReply != nil {
            respond(.install)
        } else {
            Updater.shared.openDiscoveredUpdate()
        }
    }

    /// The user said Later. Clears the sticky discovery too, because "not now" means the
    /// row should go away rather than reappear the moment the session ends.
    func postpone() {
        discovered = nil
        if updateChoiceReply != nil || installReply != nil {
            respond(.dismiss)
        } else {
            setPhase(.idle)
        }
    }

    /// Reply blocks Sparkle handed us, held until the user answers in OUR UI.
    ///
    /// Sparkle's contract is that each of these is invoked EXACTLY once. They are cleared as
    /// they are called so a second answer cannot double-invoke one, and `dismissUpdateInstallation`
    /// drains whatever is left so a torn-down session can never strand the updater.
    fileprivate var updateChoiceReply: ((SPUUserUpdateChoice) -> Void)?
    fileprivate var installReply: ((SPUUserUpdateChoice) -> Void)?
    fileprivate var acknowledgement: (() -> Void)?

    /// Answer a pending found-update prompt. Called from our own UI, never from Sparkle.
    func respond(_ choice: SPUUserUpdateChoice) {
        if let reply = updateChoiceReply {
            updateChoiceReply = nil
            reply(choice)
            return
        }
        if let reply = installReply {
            installReply = nil
            reply(choice)
        }
    }

    /// Acknowledge a terminal message (no update found, or an error).
    func acknowledge() {
        guard let ack = acknowledgement else { return }
        acknowledgement = nil
        ack()
        setPhase(.idle)
        isPanelPresented = false
    }

    fileprivate func drainPendingReplies() {
        // Dismiss rather than install: abandoning a session must never be read as consent.
        if let reply = updateChoiceReply { updateChoiceReply = nil; reply(.dismiss) }
        if let reply = installReply { installReply = nil; reply(.dismiss) }
        if let ack = acknowledgement { acknowledgement = nil; ack() }
    }
}

/// Our own `SPUUserDriver`, replacing Sparkle's standard AppKit dialog.
///
/// WHY A CUSTOM DRIVER AT ALL. `SPUStandardUpdaterController` bundles `SPUStandardUserDriver`,
/// whose scheduled-update path presents a modal that takes key focus. This app is driven by a
/// global hotkey while the user is typing or speaking into a DIFFERENT application, so a dialog
/// seizing focus mid-dictation can swallow a transcript. `SPUUpdater` accepts any
/// `SPUUserDriver`, so the presentation is ours to define.
///
/// THE RULE THIS TYPE ENFORCES. Discovery is passive. `showUpdateFound(with:state:reply:)` is
/// the only place an update can first surface, and when it was not user initiated it records the
/// version, replies `.dismiss`, and shows nothing at all. Sparkle then stops, and the user finds
/// out from a quiet indicator whenever they next look at the menu bar.
///
/// NOTHING APPEARS DURING A DICTATION. Every presenting path goes through `present(_:)`, which
/// refuses while `DictationActivity.shared.isBusy`. There is no second route to the panel.
///
/// Every method here runs on the main thread: the protocol is declared `NS_SWIFT_UI_ACTOR`.
@MainActor
final class NockerlUpdateDriver: NSObject, SPUUserDriver {
    private let model: UpdateModel

    /// The default is resolved INSIDE the initialiser, not in the parameter list. A default
    /// argument is evaluated at the call site, which is nonisolated, so naming the MainActor
    /// isolated `.shared` there is an isolation violation (a warning today, an error under the
    /// Swift 6 language mode). Resolving it in the body keeps it on the actor.
    init(model: UpdateModel? = nil) {
        self.model = model ?? .shared
        super.init()
    }

    /// The ONE gate. Any state that would put something in front of the user passes through
    /// here, and it is refused outright while a dictation is in flight. There is deliberately
    /// no queue and no retry: a missed panel is recoverable (the quiet indicator still shows,
    /// and the menu item still works), whereas an interrupted dictation is not.
    /// The last phase KIND written to the log, so progress ticks do not repeat a line.
    private var lastLoggedLabel = ""

    /// The phase reduced to its kind, dropping the payload. Two downloads at 41% and 42%
    /// are the same event as far as a log is concerned; a download becoming an extraction
    /// is not.
    private static func label(for phase: UpdatePhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .checking: return "checking"
        case .available(let version): return "available \(version)"
        case .downloading: return "downloading"
        case .extracting: return "extracting"
        case .readyToInstall: return "ready to install"
        case .installing: return "installing"
        case .upToDate: return "up to date"
        case .failed(let message): return "FAILED :: \(message)"
        }
    }

    private func present(_ phase: UpdatePhase) {
        // EVERY phase transition is logged, including the ones that are refused.
        //
        // The update path had no instrumentation at all, which is why a broken one could
        // only be reported as "nothing happens" and had to be diagnosed by reading source.
        // A signature rejection, a failed download and a silently suppressed panel are
        // three completely different problems that look identical from the outside, and
        // the log is what separates them.
        //
        // The suppressed case is logged deliberately. `present` refuses while a dictation
        // is in flight, which is correct, but an update that vanishes for a reason the user
        // cannot see is exactly the kind of thing that gets reported as a bug.
        guard !DictationActivity.shared.isBusy else {
            DebugLog.write("update: \(Self.label(for: phase)) SUPPRESSED, dictation in flight")
            return
        }
        // Log TRANSITIONS, not ticks. Download and extraction publish a new fraction many
        // times a second, and logging each one buried a whole update in hundreds of
        // near-identical lines, which defeats the point of having a log at all.
        let label = Self.label(for: phase)
        if label != lastLoggedLabel {
            lastLoggedLabel = label
            DebugLog.write("update: \(label)")
        }
        model.setPhase(phase)
        model.isPanelPresented = true
    }

    // MARK: - Permission and check lifecycle

    // `show(_:reply:)`, not `showUpdatePermissionRequest(_:reply:)`. Swift auto-renames this
    // ObjC selector and the old spelling is a hard error, not a deprecation. The header does
    // not show it: there are no NS_SWIFT_NAME annotations, so the Swift names only appear if
    // you ask the compiler for the protocol requirements.
    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        // Never ask. The preference already lives in Settings, and the honest default is the
        // one the user set there. Profiling stays off regardless of what Sparkle would ask.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: SettingsStore.shared.checkForUpdatesAutomatically,
                                         sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        // Reached only from the menu item, so the user is already looking at us.
        present(.checking)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let version = appcastItem.displayVersionString

        // An information-only update must never be downloaded. Treat it as a quiet notice.
        guard !appcastItem.isInformationOnlyUpdate else {
            model.setPhase(.available(version: version))
            reply(.dismiss)
            return
        }

        // THE QUIET PATH. A scheduled discovery records the version and stops. No panel, no
        // activation, no window. Replying `.dismiss` tells Sparkle to stand down without
        // skipping the version, so the user can still choose it later from the menu.
        guard state.userInitiated else {
            model.setPhase(.available(version: version))
            reply(.dismiss)
            return
        }

        // The user asked, so hold the reply until they answer in our panel.
        model.updateChoiceReply = reply
        present(.available(version: version))
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // Release notes render in our panel from the appcast item, so nothing to do here.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        // Not worth surfacing on its own: the version and the action still work without notes.
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        model.acknowledgement = acknowledgement
        present(.upToDate)
        // If the gate refused (a dictation started mid-check) nothing is on screen to
        // acknowledge, so release Sparkle immediately rather than stranding the session.
        if !model.isPanelPresented { model.acknowledge() }
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        model.acknowledgement = acknowledgement
        present(.failed(error.localizedDescription))
        if !model.isPanelPresented { model.acknowledge() }
    }

    // MARK: - Download and extraction progress

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        present(.downloading(fraction: nil))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        received = 0
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
        guard expectedLength > 0 else { return }
        present(.downloading(fraction: min(1, Double(received) / Double(expectedLength))))
    }

    func showDownloadDidStartExtractingUpdate() {
        present(.extracting(fraction: 0))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        present(.extracting(fraction: progress))
    }

    // MARK: - Install

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Consent to download is NOT consent to relaunch. Ask again, because relaunching mid
        // dictation would be the same transcript-eating interruption in a different costume.
        model.installReply = reply
        present(.readyToInstall)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        model.setPhase(.installing)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        // The last line the OLD binary writes. If an update goes wrong after this point,
        // the evidence is the absence of a matching launch line from the new one.
        DebugLog.write("update: installed, relaunched=\(relaunched)")
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        // Sparkle is tearing the session down. Release anything still held so the updater can
        // never be left waiting on a reply that will not come.
        model.drainPendingReplies()
        // A background discovery SURVIVES this. Sparkle ends the session immediately after
        // reporting a found update, and resetting to idle here is what made the row flash
        // and disappear: the log showed FOUND and then "session dismissed" one line later.
        // The session is over; the update still exists.
        // Says WHICH branch was taken, because that is the only thing worth knowing here
        // and the two outcomes used to log identically. "session dismissed" appeared both
        // when a discovery was correctly preserved and when it was silently wiped, which
        // made the log useless for the one question being asked of it.
        if let discovered = model.discovered {
            DebugLog.write("update: session ended, holding \(discovered)")
            model.setPhase(.available(version: discovered))
        } else {
            DebugLog.write("update: session ended, nothing to hold")
            model.setPhase(.idle)
        }
        model.isPanelPresented = false
        expectedLength = 0
        received = 0
    }

    // MARK: - Download bookkeeping

    private var expectedLength: UInt64 = 0
    private var received: UInt64 = 0
}
