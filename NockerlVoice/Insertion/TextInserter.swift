import AppKit

/// Inserts text into the frontmost app: stash the pasteboard, set our text,
/// synthesize ⌘V, then restore the pasteboard. If Accessibility is not granted,
/// the text is left on the clipboard for manual paste (History is the safety net).
@MainActor
enum TextInserter {

    enum Outcome: Equatable {
        case pasted        // synthesized ⌘V into the frontmost app
        case copiedOnly    // left on the clipboard (no Accessibility, or paste blocked)
    }

    private static let vKeyCode: CGKeyCode = 9   // ANSI 'v'

    @discardableResult
    static func insert(_ text: String) -> Outcome {
        guard !text.isEmpty else { return .copiedOnly }

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard AXIsProcessTrusted() else { return .copiedOnly }
        guard synthesizeCommandV() else { return .copiedOnly }

        // Restore the prior clipboard once the paste has been consumed.
        if let previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(previous, forType: .string)
            }
        }
        return .pasted
    }

    private static func synthesizeCommandV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}
