import AppKit
import Combine
import NockerlDesign
import SwiftUI

/// Floating on-screen indicator shown while recording / transcribing / pasting.
/// Essential because the menu-bar icon is invisible when the menu bar is auto-hidden.
///
/// Architecture: ONE non-activating, borderless panel of a fixed, generous size is
/// created once and positioned once per session. The status pill lives centered
/// inside it and MORPHS between phases (recording → transcribing → pasted). SwiftUI
/// springs the pill's width and cross-fades its content while the window itself
/// never moves or resizes. Non-activating + ignoresMouseEvents so it NEVER steals
/// focus (else the synthesized ⌘V paste would land in the HUD).
@MainActor
final class RecordingHUD {
    private let state = HUDState()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var orderOutTask: Task<Void, Never>?
    private var startedAt: Date?
    private var appearanceObserver: AnyCancellable?
    private var selectorObserver: AnyCancellable?

    /// Host hook fired whenever the style drawer opens/closes, so the CGEventTap can scope its
    /// nav-key consumption to the open state. Set by DictationController.
    var onSelectorStateChange: ((Bool) -> Void)?

    // Tall enough for the style-selector drawer to expand UPWARD on-screen. The pill is
    // bottom-anchored in HUDView, so the extra height extends UP (running off the bottom
    // of the screen was the bug). Mostly transparent: only the pill + drawer are opaque.
    private static let panelSize = NSSize(width: 560, height: 460)

    init() {
        // Live-update the HUD when the user flips Light/Dark while it is on screen,
        // cross-faded to match the window transition.
        appearanceObserver = SettingsStore.shared.$appearance
            .receive(on: RunLoop.main)
            .sink { [weak self] appearance in
                guard let panel = self?.panel else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.3
                    context.allowsImplicitAnimation = true
                    panel.appearance = appearance.nsAppearance
                }
            }

        // v1.13.0 keyboard-driven mode: the drawer is a fully passive, host-driven view.
        // Voice's CGEventTap owns ↑/↓/Return/Esc and writes the highlight through the
        // `highlightedID` binding, so the panel NEVER needs to become the key window. We do
        // NOT call makeKeyAndOrderFront (dropping it, plus the framework's focusEffectDisabled
        // in driven mode, is what removes the light-square focus-ring artifact), and the panel
        // stays fully CLICK-THROUGH at all times (zero clickable surface: every click passes
        // to the app beneath). This observer only mirrors the open/closed state out to the
        // host so its tap knows when to consume the nav keys.
        selectorObserver = state.$selectorOpen
            .receive(on: RunLoop.main)
            .sink { [weak self] open in self?.onSelectorStateChange?(open) }
    }

    func showRecording() {
        cancelHide()
        state.phase = .recording
        state.selectorOpen = false
        state.resetLevels()
        state.elapsed = 0
        startedAt = Date()
        startTicking()
        presentAndPosition()
    }

    func updateLevel(_ level: Float) { state.pushLevel(level) }

    /// Open the style-selector drawer, called by the Right-⌘ tap's ↑ observation while
    /// recording. No-op unless we're recording and it isn't already open.
    func openStyleSelector() {
        guard case .recording = state.phase, !state.selectorOpen else { return }
        // Seed the keyboard highlight on the currently-active style, then open.
        state.highlightedID = SettingsStore.shared.activeStyleID
        state.selectorOpen = true
    }

    /// Move the keyboard highlight up/down through the styles: host-driven nav (v1.13.0),
    /// using the framework's canonical wrap helper so it matches internal semantics exactly.
    func moveHighlightUp() { moveHighlight(.up) }
    func moveHighlightDown() { moveHighlight(.down) }

    private func moveHighlight(_ direction: NockerlHudHighlightDirection) {
        guard state.selectorOpen else { return }
        state.highlightedID = NockerlHudStyleSelector.nextHighlight(
            from: state.highlightedID, direction: direction, in: hudStyles
        )
    }

    /// Commit the highlighted style (Return): set it active, then close the drawer.
    func commitHighlight() {
        guard state.selectorOpen else { return }
        if let id = state.highlightedID, hudStyles.contains(where: { $0.id == id }) {
            SettingsStore.shared.setActiveStyle(id)
        }
        state.selectorOpen = false
    }

    /// Close the drawer without committing (Esc).
    func closeStyleSelector() {
        guard state.selectorOpen else { return }
        state.selectorOpen = false
    }

    /// Whether the style drawer is open. The host tap reads this to scope key-consumption.
    var isSelectorOpen: Bool { state.selectorOpen }

    /// The styles the drawer shows, as framework models (id + label): the SAME array passed
    /// to the selector config, so `nextHighlight` wraps over the identical order.
    private var hudStyles: [NockerlHudStyle] {
        SettingsStore.shared.styles.map { NockerlHudStyle(id: $0.id, label: $0.name) }
    }

    /// Close the selector before any phase change (transcribe / result / error / stop) so the
    /// drawer view is gone before the pill morphs. Setting `selectorOpen = false` fires the
    /// `$selectorOpen` observer → `onSelectorStateChange(false)`, so the host tap stops
    /// consuming the nav keys. (The panel is always click-through now, so there's no mouse
    /// state to restore.)
    private func dismissStyleSelector() {
        guard state.selectorOpen else { return }
        state.selectorOpen = false
    }

    func showTranscribing() {
        cancelHide()
        stopTicking()
        dismissStyleSelector()
        state.transcribingLabel = TranscriptionRetryPhase.attempting.label
        state.phase = .transcribing
        ensureVisible()
    }

    /// Show auto-retry progress in the transcribing pill DURING the backoff between attempts.
    /// The phase is already `.transcribing`; this just morphs the status word. The caller
    /// passes the shared label so this surface cannot word it differently from History.
    func showRetrying(_ label: String) {
        cancelHide()
        state.transcribingLabel = label
        state.phase = .transcribing
        ensureVisible()
    }

    func showResult(pasted: Bool) {
        cancelHide()
        stopTicking()
        dismissStyleSelector()
        state.phase = .result(pasted: pasted)
        ensureVisible()
        scheduleHide(after: 1.8)
    }

    func showError(_ message: String) {
        cancelHide()
        stopTicking()
        dismissStyleSelector()
        state.phase = .error(message)
        ensureVisible()
        scheduleHide(after: 8.0)
    }

    /// The user aborted the in-flight transcription with ⎋. Show a brief "Cancelled" pill
    /// (red ✕) then auto-dismiss; the caller saves the audio to History for retry.
    func showCancelled() {
        cancelHide()
        stopTicking()
        dismissStyleSelector()
        state.phase = .cancelled
        ensureVisible()
        scheduleHide(after: 1.8)
    }

    /// A one-time, auto-dismissing hint pill (e.g. the launch "ready" prompt).
    func showHint(_ message: String) {
        cancelHide()
        stopTicking()
        state.phase = .hint(message)
        presentAndPosition()
        scheduleHide(after: 4.5)
    }

    func hide() {
        cancelHide()
        stopTicking()
        dismissStyleSelector()
        guard let panel, panel.isVisible, state.visible else { return }
        // Play the pill's fromBottom EXIT (slide down + fade) by removing its presence
        // inside an animation, then order the now-empty transparent window out once the
        // slide has finished. (The window itself no longer alpha-fades: the pill's own
        // motion is the whole show/hide transition.)
        withAnimation(.easeInOut(duration: 0.28)) { state.visible = false }
        orderOutTask?.cancel()
        orderOutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    // MARK: - Panel

    /// Order the panel front (transparent when empty) and toggle the pill's presence so
    /// its fromBottom entrance plays. On subsequent phases the window stays put and the
    /// persistent framework pill morphs (constant height, width only).
    private func presentAndPosition() {
        orderOutTask?.cancel()
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.appearance = SettingsStore.shared.appearance.nsAppearance  // follow Light/Dark setting
        position(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.40, dampingFraction: 0.80)) {
            state.visible = true
        }
    }

    private func ensureVisible() {
        orderOutTask?.cancel()
        guard let panel else { presentAndPosition(); return }
        panel.appearance = SettingsStore.shared.appearance.nsAppearance  // follow Light/Dark setting
        if !panel.isVisible {
            position(panel)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        // Bring the pill in if it isn't already; mid-session phase changes
        // (recording → transcribing → error) are NOT animated here. The persistent
        // framework HUD morphs internally on its `phase` prop.
        if !state.visible {
            withAnimation(.spring(response: 0.40, dampingFraction: 0.80)) { state.visible = true }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = KeyableHUDPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // SwiftUI draws the shadow
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let hosting = NSHostingView(rootView: HUDView().environmentObject(state))
        // ROOT-CAUSE CRASH FIX: do NOT let the hosting view resize the panel from its
        // content. The panel is a fixed-size float; the pill + drawer float within it. When
        // the drawer changed the content size, NSHostingView's updateWindowContentSize /
        // minSize path trapped (EXC_BREAKPOINT: a hard crash on stop-with-drawer-open).
        // Empty sizingOptions disables that window-sizing path entirely.
        hosting.sizingOptions = []
        hosting.setFrameSize(Self.panelSize)
        panel.contentView = hosting
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = Self.panelSize
        // Centered horizontally; the pill (centered in the panel) lands ~108pt up.
        panel.setFrame(
            NSRect(x: frame.midX - size.width / 2, y: frame.minY + 24, width: size.width, height: size.height),
            display: true
        )
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, let start = self.startedAt else { break }
                self.state.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopTicking() { tickTask?.cancel(); tickTask = nil }

    private func scheduleHide(after seconds: Double) {
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.hide() }
        }
    }

    private func cancelHide() { hideTask?.cancel(); hideTask = nil }
}

// MARK: - State

/// A borderless HUD panel that CAN become key, used ONLY so the style-selector drawer
/// receives keyboard while it is open. `.nonactivatingPanel` still holds: the app never
/// activates and the frontmost app stays frontmost, so the synthesized ⌘V paste still
/// lands there. This override just lets the panel be the key window briefly.
private final class KeyableHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class HUDState: ObservableObject {
    enum Phase: Equatable {
        case hint(String)
        case recording
        case transcribing
        case result(pasted: Bool)
        case error(String)
        case cancelled

        /// recording / transcribing / error / result render via the framework
        /// NockerlRecordingHUD (result adopted in v1.7.0); hint + cancelled stay app-side.
        var usesFrameworkHUD: Bool {
            switch self {
            case .recording, .transcribing, .error, .result: return true
            case .hint, .cancelled: return false
            }
        }

        /// Map to the framework phase (only meaningful when `usesFrameworkHUD`).
        var frameworkPhase: NockerlRecordingHudPhase {
            switch self {
            case .transcribing: return .transcribing
            case .error: return .error
            case let .result(pasted): return .result(pasted: pasted)
            default: return .recording
            }
        }

        var errorText: String {
            if case let .error(message) = self { return message }
            return ""
        }
    }

    static let barCount = 5

    @Published var phase: Phase = .recording
    /// Whether the pill is present. Host-toggled inside `withAnimation`
    /// (RecordingHUD.present/hide) so the component's fromBottom entrance/exit plays;
    /// false = the transparent panel is empty.
    @Published var visible: Bool = false
    /// Log-normalized amplitudes (0…1), newest last. PRE-normalized at ingest.
    /// The framework equalizer contract takes processed 0…1 amplitudes and scales
    /// bars directly (fit-matrix ruling), so raw mic levels never reach the view.
    @Published var levels: [CGFloat] = Array(repeating: 0, count: barCount)
    @Published var elapsed: TimeInterval = 0
    /// The status word shown in the `.transcribing` phase: normally "Transcribing…", set to
    /// "Retrying N of 5" during the 429 auto-retry sequence.
    @Published var transcribingLabel: String = "Transcribing…"
    /// The style-selector drawer is expanded. Mirrored to the host (onSelectorStateChange)
    /// so its CGEventTap scopes nav-key consumption to the open state.
    @Published var selectorOpen: Bool = false
    /// The keyboard-highlighted style `id` in the OPEN drawer (v1.13.0 host-driven mode).
    /// Voice's tap moves this via `NockerlHudStyleSelector.nextHighlight`; the drawer renders
    /// the neutral brightness-step highlight off it, with no focus ring.
    @Published var highlightedID: String?

    func pushLevel(_ level: Float) {
        levels.removeFirst()
        levels.append(Self.normalized(level))
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: Self.barCount)
    }

    /// Log normalization, Android parity: ln(raw+1)/ln(32768), raw ≈ level·32767.
    /// Moved out of the equalizer view (it used to live in `barHeight`).
    static func normalized(_ level: Float) -> CGFloat {
        let raw = max(0, min(level, 1)) * 32_767
        return CGFloat(log(raw + 1) / log(32_768))
    }
}
