import AppKit
import CoreGraphics

/// `CGEventTap` behind the dictation hotkey. Fires `onTap` each time the Right Command key
/// is tapped: pressed and released with no other key in between (so ⌘-key chords don't
/// trigger it). It ALSO surfaces the four HUD style-selector nav keys (↑ ↓ Return Esc) so a
/// keyboard-driven, non-activating HUD can be driven WITHOUT the panel ever becoming the key
/// window (v1.13.0: keyboard is decoupled from window focus; see the HUD research notes).
///
/// The tap prefers an ACTIVE `.defaultTap`, which lets it SWALLOW the four nav keys while
/// the drawer is open, so they don't leak to the app underneath, and gracefully falls back
/// to `.listenOnly` if the active tap can't be created (e.g. only Input Monitoring, not
/// Accessibility, is granted); in that mode the keys are observed but pass through. The Right
/// ⌘ key and every non-nav key ALWAYS pass through untouched.
final class RightCommandTapMonitor {

    /// Invoked on the main run loop when a Right ⌘ tap completes.
    var onTap: (() -> Void)?

    /// The four HUD style-selector nav keys, invoked on the main run loop. ↑ fires whether or
    /// not the drawer is open (the host opens on ↑-when-closed, navigates on ↑-when-open);
    /// ↓/Return/Esc are meaningful only while open. Set `selectorOpen` so the tap knows when
    /// to SWALLOW these (open) versus pass them through (closed).
    var onUpArrow: (() -> Void)?
    var onDownArrow: (() -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    /// Host-set: is the HUD style drawer currently open? Written on the main thread by the
    /// dictation controller; read synchronously in the tap callback (also main-thread: the
    /// tap runs on the main run loop) to decide whether to swallow the nav keys.
    var selectorOpen = false

    /// Host-set: is a transcription in flight (and therefore cancellable)? When true, the tap
    /// swallows ⎋ and fires `onEscape` so the user can abort a slow request; the key never
    /// leaks to the app underneath. Written on the main thread by the dictation controller.
    var cancellable = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var rightCommandDown = false
    private var chordUsed = false

    /// True while running on the fallback `.listenOnly` tap rather than an active
    /// `.defaultTap`. Read by `start()` to decide whether an existing tap is worth
    /// replacing, and the only in-process record of which path was taken.
    private(set) var isDegraded = false

    /// Start the tap. Returns false if it could not be created at all. The caller should
    /// prompt for permission.
    ///
    /// SAFE TO CALL REPEATEDLY, and that is the point. This used to open with
    /// `guard eventTap == nil else { return true }`, which made every later call a silent
    /// success and left a degraded tap in place for the life of the process. That produced
    /// a hotkey which only fired while this app was frontmost, on a fresh install, with no
    /// symptom anywhere else:
    ///
    ///   1. The controller is a `@StateObject`, so `startHotkey()` runs during app init,
    ///      before any window exists. On a genuine first run Accessibility cannot have been
    ///      granted yet, by definition.
    ///   2. `.defaultTap` needs Accessibility, so it fails. `.listenOnly` is created
    ///      instead, and it is created SUCCESSFULLY even with no Input Monitoring grant.
    ///      The system simply starves it, delivering only events aimed at this process.
    ///   3. `start()` therefore returned true, `hotkeyActive` went true, no guidance was
    ///      raised, and the menu bar said the hotkey was ready.
    ///   4. The user granted Accessibility. Pasting began working, so everything looked
    ///      right, but the starved tap was never rebuilt and the hotkey stayed local to
    ///      this app until the next relaunch.
    ///
    /// An ACTIVE tap is still left alone: rebuilding a working tap would drop events for no
    /// reason. A DEGRADED one is replaced, but only once `AXIsProcessTrusted()` says the
    /// grant that would upgrade it has actually arrived, so a repeated call while still
    /// ungranted is not churn.
    @discardableResult
    func start() -> Bool {
        if eventTap != nil {
            guard isDegraded, AXIsProcessTrusted() else { return true }
            DebugLog.write("hotkey: Accessibility now granted, replacing the degraded tap")
            stop()
        }

        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon,
               Unmanaged<RightCommandTapMonitor>.fromOpaque(refcon)
                   .takeUnretainedValue()
                   .handle(type: type, event: event) {
                return nil   // swallow: honored only by an active .defaultTap
            }
            return Unmanaged.passUnretained(event)
        }

        // Prefer an ACTIVE tap (can swallow the open-drawer nav keys); fall back to
        // listen-only if the active tap can't be created. In listen-only the swallow return
        // is ignored, so the keys pass through: nav still works, they just also reach the
        // app behind (harmless, an acceptable degradation).
        let make: (CGEventTapOptions) -> CFMachPort? = { options in
            CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: options,
                eventsOfInterest: CGEventMask(mask),
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        }
        // Which of the two was used matters, so the two attempts are separate rather than
        // a `??` chain: the degraded outcome has to be recorded, not just tolerated.
        var degraded = false
        var created = make(.defaultTap)
        if created == nil {
            created = make(.listenOnly)
            degraded = created != nil
        }
        guard let tap = created else {
            DebugLog.write("hotkey: no tap could be created, the hotkey is dead")
            return false
        }
        isDegraded = degraded
        // The one line that would have made this diagnosable from a log instead of by
        // elimination. There was no instrumentation on this path at all.
        DebugLog.write(degraded
            ? "hotkey: DEGRADED listenOnly tap (no Accessibility); fires only while this app is frontmost"
            : "hotkey: active defaultTap, global")

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        isDegraded = false
        rightCommandDown = false
        chordUsed = false
    }

    /// Returns `true` to SWALLOW the event (honored only by an active tap). The Right ⌘ key
    /// and every non-nav key return `false` (pass through untouched).
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false

        case .keyDown:
            if rightCommandDown {
                chordUsed = true   // ⌘+key chord, not a bare tap
                return false
            }
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            if selectorOpen {
                // Drawer open: the four nav keys drive it AND are swallowed so they don't
                // leak to the app underneath. Everything else passes through.
                switch keycode {
                case 126: fireOnMain(onUpArrow);   return true  // ↑ highlight up
                case 125: fireOnMain(onDownArrow); return true  // ↓ highlight down
                case 36:  fireOnMain(onReturn);    return true  // ⏎ commit
                case 53:  fireOnMain(onEscape);    return true  // ⎋ dismiss
                default:  return false
                }
            } else if cancellable, keycode == 53 {
                // Transcribing: ⎋ aborts the in-flight transcription. Swallowed so it does
                // not also reach the app underneath (which is idle, awaiting the paste).
                fireOnMain(onEscape)
                return true
            } else if keycode == 126 {
                // Drawer closed: bare ↑ opens the selector (NOT swallowed), so ↑ still works
                // normally in whatever app currently has focus.
                fireOnMain(onUpArrow)
            }
            return false

        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == HotkeyKeycode.rightCommand else { return false }
            if event.flags.contains(.maskCommand) {
                rightCommandDown = true
                chordUsed = false
            } else if rightCommandDown {
                rightCommandDown = false
                if !chordUsed { fireOnMain(onTap) }
            }
            return false

        default:
            return false
        }
    }

    /// Hop a callback to the main run loop. (The tap callback already runs there, but
    /// deferring keeps HUD/state mutation out of the event-tap call frame.)
    private func fireOnMain(_ callback: (() -> Void)?) {
        guard let callback else { return }
        DispatchQueue.main.async { callback() }
    }
}
