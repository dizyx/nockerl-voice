import AppKit
import Combine

/// Ties the pieces together: Right ⌘ hotkey → record → transcribe → paste. Owns the
/// dictation state machine and publishes state for the menu-bar UI. History persistence
/// hooks in at `didTranscribe`.
@MainActor
final class DictationController: ObservableObject {

    @Published private(set) var status: DictationStatus = .idle {
        // Keep the tap's ⎋-capture in sync: any non-idle state (recording OR transcribing)
        // is cancellable, so the tap swallows ⎋ and routes it to handleEscape().
        didSet {
            let busy = status != .idle
            monitor.cancellable = busy
            // Mirror to the flag the updater reads. Recording OR transcribing both count as
            // busy: taking key focus during either is what eats a transcript.
            DictationActivity.shared.setBusy(busy)
        }
    }
    @Published private(set) var provider: ProviderKind = .local
    @Published private(set) var lastTranscript: String = ""
    @Published private(set) var lastError: String?
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var hotkeyActive = false

    /// Bumped every time `startHotkey()` FAILS to create the CGEvent tap, i.e. Input
    /// Monitoring is missing or was revoked (macOS resets TCC on some updates, so a
    /// long-running install can lose the grant). A one-shot signal the menu-bar scene
    /// observes to surface the setup guidance instead of the hotkey dying silently
    /// State-driven off the actual tap result, not a first-run flag.
    @Published private(set) var permissionGuidanceRequestID = 0

    private let monitor = RightCommandTapMonitor()
    private var detector = DoubleTapDetector()
    private let recorder = AudioRecorder()
    private let hud = RecordingHUD()
    /// The in-flight transcription task, retained so ⎋ can cancel it.
    private var transcribeTask: Task<Void, Never>?
    /// Retained so the app-activation observer can be torn down with the controller.
    private var activationObserver: (any NSObjectProtocol)?

    init() {
        recorder.onLevel = { [weak self] level in
            self?.inputLevel = level
            self?.hud.updateLevel(level)
        }
        // Duration cap reached: finalize the audio we captured instead of dropping it.
        recorder.onAutoStop = { [weak self] wav in self?.finalize(wav) }
        monitor.onTap = { [weak self] in self?.handleTap() }
        // Re-attempt the hotkey every time the app comes to the front. This is the single
        // point that covers EVERY route by which Accessibility can be granted: the welcome
        // window, the permission window, System Settings opened by hand, or a TCC reset,
        // because all of them end with this app becoming active again.
        //
        // It exists because the grant almost never arrives before the tap is built. The
        // controller is a `@StateObject`, so the first `startHotkey()` runs during app
        // init, before any window is on screen; on a first run that is necessarily before
        // the user has granted anything. `monitor.start()` is a no-op once an active tap
        // exists, so this is cheap, and it only rebuilds when there is a degraded tap AND
        // the grant to upgrade it.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.startHotkey() }
        }
        // HUD style-selector nav (v1.13.0 keyboard-driven mode). ↑ opens the drawer (when
        // closed) or moves the highlight up (when open); ↓/Return/Esc drive the open drawer.
        monitor.onUpArrow = { [weak self] in self?.handleUpArrow() }
        monitor.onDownArrow = { [weak self] in self?.handleDownArrow() }
        monitor.onReturn = { [weak self] in self?.handleReturn() }
        monitor.onEscape = { [weak self] in self?.handleEscape() }
        // Keep the tap's open-state flag in sync so it consumes ↑/↓/Return/Esc ONLY while the
        // drawer is open (otherwise they pass through to the app underneath).
        hud.onSelectorStateChange = { [weak self] open in self?.monitor.selectorOpen = open }
        startHotkey()
        // Probe the local model at launch so the debug log shows reachability
        // even before the first dictation.
        let config = SettingsStore.shared.buildConfig()
        Task { await TranscriptionService(config: config).warmUp() }

        // Surface any audio left behind by an interrupted/crashed transcription so
        // it can be retried, never silently lost.
        HistoryStore.shared.recoverOrphans()

        // A one-time "ready" hint on launch, once the UI has settled.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard let self else { return }
            self.hud.showHint(self.hotkeyActive
                ? "Double-tap Right ⌘ to dictate"
                : "Enable Input Monitoring for the Right ⌘ hotkey")
        }
    }

    // MARK: - Hotkey

    func startHotkey() {
        hotkeyActive = monitor.start()
        if !hotkeyActive {
            // The tap could not be created: Input Monitoring is missing/revoked, so
            // the Right ⌘ hotkey is dead. Surface the setup guidance rather than fail
            // silently. One-shot signal; the scene opens onboarding in response.
            permissionGuidanceRequestID &+= 1
        }
    }

    func stopHotkey() {
        monitor.stop()
        hotkeyActive = false
    }

    private func handleTap() {
        switch status {
        case .idle:
            if detector.registerTap(at: ProcessInfo.processInfo.systemUptime) {
                beginRecording()
            }
        case .recording:
            detector.reset()
            finalize(recorder.stop())
        case .transcribing:
            break
        }
    }

    /// HUD style-selector keyboard nav, only meaningful while recording. ↑ opens the drawer
    /// when closed, else moves the highlight up. (The tap already scopes key-consumption to
    /// the open drawer; these guards keep stray keys inert when not recording.)
    private func handleUpArrow() {
        guard status == .recording else { return }
        if hud.isSelectorOpen { hud.moveHighlightUp() } else { hud.openStyleSelector() }
    }

    private func handleDownArrow() {
        guard status == .recording, hud.isSelectorOpen else { return }
        hud.moveHighlightDown()
    }

    private func handleReturn() {
        guard status == .recording, hud.isSelectorOpen else { return }
        hud.commitHighlight()
    }

    private func handleEscape() {
        switch status {
        case .recording:
            // ⎋ closes the style drawer if it's open; otherwise it cancels the recording
            // (audio DISCARDED: nothing is saved to History).
            if hud.isSelectorOpen { hud.closeStyleSelector() } else { cancelRecording() }
        case .transcribing:
            cancelTranscription()
        case .idle:
            break
        }
    }

    /// ⎋ while recording (drawer closed): stop and DISCARD the capture, no History entry,
    /// no transcription. Shows the same Cancelled pill as a transcription cancel.
    private func cancelRecording() {
        guard status == .recording else { return }
        _ = recorder.stop()   // drop the captured audio on the floor, a deliberate discard
        detector.reset()
        status = .idle
        inputLevel = 0
        hud.showCancelled()
    }

    /// ⎋ during transcription: abort the in-flight request. The transcribe() catch path
    /// keeps the audio in History (retryable) and shows the Cancelled pill.
    private func cancelTranscription() {
        guard status == .transcribing else { return }
        transcribeTask?.cancel()
    }

    // MARK: - Manual control (menu / pre-permission)

    func toggleManually() {
        switch status {
        case .idle: beginRecording()
        case .recording: finalize(recorder.stop())
        case .transcribing: break
        }
    }

    // MARK: - Recording lifecycle

    private func beginRecording() {
        do {
            try recorder.start()
            lastError = nil
            status = .recording
            hud.showRecording()
        } catch {
            lastError = error.localizedDescription
            status = .idle
            hud.showError(error.localizedDescription)
        }
    }

    /// Finalize a recording from either stop path (the manual single-tap or the
    /// duration-cap auto-stop) and start transcription. Idempotent: a second call
    /// (e.g. a manual stop racing the cap) is ignored because `status` is no longer
    /// `.recording`. The capped path used to discard its audio here (the 5-min bug);
    /// now both paths persist and transcribe identically.
    private func finalize(_ wav: Data) {
        guard status == .recording else { return }
        guard !wav.isEmpty else {
            status = .idle
            inputLevel = 0
            hud.hide()
            return
        }
        guard SettingsStore.shared.defaultEngine != nil else {
            status = .idle
            inputLevel = 0
            hud.showError("Set up transcription in Settings first.")
            return
        }
        status = .transcribing
        hud.showTranscribing()
        // 16-bit mono @ 16 kHz: (bytes - 44 header) / 2 / 16000.
        let durationSec = Double(max(0, wav.count - 44)) / 2.0 / 16_000.0
        // Persist to disk BEFORE transcribing so a failure or crash never loses it.
        let filename = RecordingStore.shared.save(wav)
        transcribeTask = Task { await transcribe(wav, filename: filename, durationSec: durationSec) }
    }

    private func transcribe(_ wav: Data, filename: String?, durationSec: Double) async {
        var config = SettingsStore.shared.buildConfig()
        // Scale the request timeout to the clip length so long audio isn't killed by
        // the short default idle timeout before the model can respond.
        config.transcriptionTimeout = TranscriptionConfig.timeout(forDurationSec: durationSec)
        let service = TranscriptionService(config: config)
        // Snapshot the active style NOW (before transcription) so History labels this record
        // with the style that produced it, even if the user renames or deletes it later.
        let styleName = SettingsStore.shared.activeStyle?.name ?? "Standard"
        let styleID = SettingsStore.shared.activeStyleID
        do {
            let startedAt = Date()
            let outcome = try await transcribeWithRetry(service: service, wav: wav)
            let processingMs = Date().timeIntervalSince(startedAt) * 1000
            provider = (outcome.provider == "cloud") ? .cloud : .local
            lastTranscript = outcome.text
            let result = TextInserter.insert(outcome.text)
            lastError = (result == .copiedOnly)
                ? "Copied to clipboard. Paste with ⌘V (grant Accessibility to auto-paste)."
                : nil
            HistoryStore.shared.add(
                text: outcome.text, provider: provider,
                durationSec: durationSec, processingMs: processingMs, language: "en", pasted: result == .pasted,
                styleName: styleName, styleID: styleID
            )
            // Transcript safely saved, so the raw audio is no longer needed.
            if let filename { RecordingStore.shared.delete(filename) }
            hud.showResult(pasted: result == .pasted)
        } catch {
            if Task.isCancelled {
                // User pressed ⎋ mid-transcription: a deliberate abort, not a failure. Keep
                // the audio in History (retryable) and show the Cancelled pill.
                DebugLog.write("transcribe: CANCELLED by user")
                if let filename {
                    HistoryStore.shared.recordFailure(
                        audioFilename: filename, durationSec: durationSec,
                        error: "Transcription cancelled.",
                        styleName: styleName, styleID: styleID
                    )
                }
                hud.showCancelled()
            } else {
                // The verbose reason (provider, HTTP code, raw detail) goes to the debug log;
                // the user sees a short, plain message.
                DebugLog.write("transcribe: FAILED :: \(error.localizedDescription) :: \(String(describing: error))")
                // Two surfaces, two registers. The pill gets two or three words because it is
                // a small floating capsule; History gets the full sentence and any link,
                // because that is where the user can act on it.
                let offline = Self.offlineMessages()
                let historyText = offline?.history
                    ?? (error as? TranscriptionError)?.historyMessage
                    ?? "Something went wrong. Please retry."
                let hudText = offline?.hud
                    ?? (error as? TranscriptionError)?.hudMessage
                    ?? "Error"
                lastError = historyText
                hud.showError(hudText)
                // Keep the audio + record the failure so it can be retried, never lost.
                if let filename {
                    HistoryStore.shared.recordFailure(
                        audioFilename: filename, durationSec: durationSec,
                        error: historyText, styleName: styleName, styleID: styleID
                    )
                    Self.revealHistoryIfAlreadyOpen()
                }
            }
        }
        status = .idle
        inputLevel = 0
        transcribeTask = nil
    }

    /// The most common transcription failure is a busy / rate-limited server (HTTP 429).
    /// Auto-retry it up to `maxRetries` times, 2 s apart, surfacing "Retrying N of 5" in the
    /// HUD. Any other error (or a 429 that survives all retries) is thrown to the caller's
    /// error path (saved to History). Each attempt runs the full local→cloud pipeline.
    private func transcribeWithRetry(service: TranscriptionService, wav: Data) async throws -> TranscriptionService.Outcome {
        try await TranscriptionRetry.run(
            service: service,
            wav: wav,
            prompt: SettingsStore.shared.buildPrompt()
        ) { [hud] phase in
            switch phase {
            case .waiting:
                // The label describes the WAIT, so it is only on screen during the backoff.
                hud.showRetrying(phase.label)
            case .attempting:
                // The retry loop no longer reports this. Inside a sequence the label is a
                // heartbeat and only ever counts up, so it cannot flip back and forth. The
                // case stays because the phase still names the ordinary in-progress state,
                // and this remains the right response if it is ever reported again.
                hud.showTranscribing()
            }
        }
    }

    /// When a CLOUD transcription fails while the system reports no internet, the connection is
    /// the real story: say so instead of blaming the server. Returns nil otherwise (including
    /// for the Custom tier, which reaches its model over Tailscale and can work fine with the
    /// public internet down).
    static func offlineMessages() -> (hud: String, history: String)? {
        guard !NetworkMonitor.shared.isOnline,
              SettingsStore.shared.defaultEngine == .openrouter else { return nil }
        return (hud: "Offline", history: "You're offline. Reconnect and retry from History.")
    }

    /// After a failure the item is sitting in History, so point an ALREADY OPEN dashboard at
    /// it. If no dashboard window is on screen this does NOTHING.
    ///
    /// It reads a counter the scene lifecycle maintains and, at most, assigns a published
    /// section. There is no `openWindow`, no `NSApp.activate`, no `makeKeyAndOrderFront`, so
    /// there is no code path here that can present or focus anything. A window appearing on
    /// its own right after a failed dictation is exactly the focus theft that was rejected
    /// for update prompts, and this is a menu-bar-first app where the window is usually shut.
    private static func revealHistoryIfAlreadyOpen() {
        guard WindowPresence.shared.isDashboardOpen else { return }
        DashboardRouter.shared.section = .history
    }
}
