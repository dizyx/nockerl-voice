import XCTest
import AppKit
// Code under test (NockerlVoice/Insertion/TextInserter.swift) is compiled directly
// into this non-hosted test bundle (see project.yml `NockerlVoiceTests.sources`), so
// no module import is needed.
//
// These tests cover the DATA-LOSS contract of the paste path: a transcription
// must NEVER vanish, and a user's own clipboard must NEVER be destroyed. TextInserter
// talks to the real `NSPasteboard.general` (there is no injection seam and these tests
// do not refactor production), so every test snapshots and restores the clipboard:
// the suite must not clobber the clipboard of whoever runs it.
//
// Two runtime facts shape how these are written, and neither is fakeable in a unit test:
//   * `AXIsProcessTrusted()`: whether the test runner has Accessibility trust. In a
//     normal CI / Xcode test run it is FALSE (the runner is not in the Accessibility
//     list), which is exactly the degradation path we most need to prove. Tests read the
//     SAME value the production code reads, then assert the branch that value selects,
//     so the assertions are consistent with the code, never flaky.
//   * The auto-paste path posts a real synthesized ⌘V and restores the clipboard
//     asynchronously (~0.25 s later). That path is gated behind Accessibility trust and
//     is effectively Mac-manual; the one test that exercises it self-skips unless trust
//     is granted, so the normal suite never posts a stray keystroke.

@MainActor
final class TextInserterTests: XCTestCase {

    // MARK: - Clipboard hygiene helpers

    private func snapshotClipboard() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    private func setClipboard(_ value: String?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let value { pb.setString(value, forType: .string) }
    }

    // MARK: - Empty input is a lossless no-op

    /// Empty text has nothing to paste: the guard returns `.copiedOnly` BEFORE the
    /// pasteboard is ever cleared, so an accidental empty insert must not wipe whatever
    /// the user already had on the clipboard.
    func testEmptyTextReturnsCopiedOnlyAndLeavesClipboardUntouched() {
        let saved = snapshotClipboard()
        defer { setClipboard(saved) }

        let sentinel = "user-clipboard-\(UUID().uuidString)"
        setClipboard(sentinel)

        let outcome = TextInserter.insert("")

        XCTAssertEqual(outcome, .copiedOnly,
                       "Empty text has nothing to paste and must report .copiedOnly.")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), sentinel,
                       "Empty insert must not touch the clipboard (the guard returns before clearContents()).")
    }

    // MARK: - Degradation contract + the core safety net (no Accessibility path)

    /// The most important data-loss guarantee, on the path a normal test runner is in
    /// (Accessibility NOT trusted): insert() must degrade to `.copiedOnly` AND leave the
    /// transcript sitting on the clipboard for a manual ⌘V. The dictation is preserved,
    /// never silently dropped, even though auto-paste is unavailable.
    ///
    /// Skipped when the runner DOES have Accessibility trust, because there insert() takes
    /// the auto-paste branch and would post a real ⌘V (covered, opt-in, by
    /// `testRestoresPriorClipboardAfterSuccessfulPaste`).
    func testDegradesToCopiedOnlyAndPreservesTranscriptWhenAccessibilityNotTrusted() throws {
        try XCTSkipIf(AXIsProcessTrusted(),
                      "Accessibility IS granted to the test runner, so insert() auto-pastes (posts a real ⌘V). The .copiedOnly degradation path requires Accessibility NOT trusted: the normal CI/test-runner state.")

        let saved = snapshotClipboard()
        defer { setClipboard(saved) }

        let transcript = "degrade-path transcript \(UUID().uuidString)"
        let outcome = TextInserter.insert(transcript)

        XCTAssertEqual(outcome, .copiedOnly,
                       "Without Accessibility trust, insert() must degrade to clipboard-only, never a false .pasted.")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), transcript,
                       "In the degraded path the transcript stays on the clipboard for manual ⌘V: the dictation is not lost.")
    }

    // MARK: - Save/restore of the user's prior clipboard (auto-paste path: AX-gated / Mac-manual)

    /// Verifies the "we do not destroy the user's clipboard" half of the contract: after a
    /// SUCCESSFUL auto-paste, the value the user had before dictating is restored (~0.25 s
    /// later). This path only exists when Accessibility is trusted AND CGEvent synthesis
    /// succeeds, so it self-skips otherwise. It is effectively Mac-manual: when it does run
    /// it posts a real synthesized ⌘V into the frontmost app, which is why it is gated
    /// behind a deliberate Accessibility grant rather than run in the normal suite.
    func testRestoresPriorClipboardAfterSuccessfulPaste() throws {
        try XCTSkipUnless(AXIsProcessTrusted(),
                          "The prior-clipboard restore only runs on the successful auto-paste branch, which requires Accessibility trust. In the normal (untrusted) runner insert() returns .copiedOnly and deliberately LEAVES the transcript on the clipboard, so there is nothing to restore. Verify on a Mac with Accessibility granted (Mac-manual).")

        let saved = snapshotClipboard()
        defer { setClipboard(saved) }

        let prior = "the user's own clipboard \(UUID().uuidString)"
        setClipboard(prior)

        let transcript = "auto-pasted transcript \(UUID().uuidString)"
        let outcome = TextInserter.insert(transcript)

        // Only the .pasted branch schedules a restore. If CGEvent synthesis was unavailable
        // insert() returns .copiedOnly and correctly leaves the transcript on the clipboard:
        // there is nothing to restore, so skip rather than assert a restore that never happens.
        guard outcome == .pasted else {
            throw XCTSkip("insert() did not reach the .pasted branch (CGEvent synthesis unavailable); no restore is scheduled.")
        }

        // Immediately after a successful paste the transcript is still on the clipboard
        // (the restore is asynchronous), the trusted-path half of the "never lose a
        // dictation" safety net.
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), transcript,
                       "Right after a successful auto-paste the transcript is still on the clipboard (restore is async).")

        // ...and shortly after, the user's prior clipboard is put back: their data survives.
        let restored = expectation(description: "prior clipboard restored after auto-paste")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), prior,
                           "After a successful auto-paste the user's prior clipboard contents must be restored.")
            restored.fulfill()
        }
        wait(for: [restored], timeout: 2.0)
    }
}
