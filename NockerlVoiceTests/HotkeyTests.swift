import XCTest

final class HotkeyTests: XCTestCase {

    func testTwoTapsWithinWindowAreDouble() {
        var d = DoubleTapDetector(window: 0.35)
        XCTAssertFalse(d.registerTap(at: 0.00))
        XCTAssertTrue(d.registerTap(at: 0.20))     // 0.20 <= 0.35
    }

    func testSecondTapTooLateIsNotDouble() {
        var d = DoubleTapDetector(window: 0.35)
        XCTAssertFalse(d.registerTap(at: 0.00))
        XCTAssertFalse(d.registerTap(at: 0.50))    // 0.50 > 0.35, becomes the new first
        XCTAssertTrue(d.registerTap(at: 0.70))     // 0.20 after the 0.50 tap
    }

    func testDoublePairIsConsumed() {
        var d = DoubleTapDetector(window: 0.35)
        XCTAssertFalse(d.registerTap(at: 0.00))
        XCTAssertTrue(d.registerTap(at: 0.10))     // pair consumed
        XCTAssertFalse(d.registerTap(at: 0.20))    // a fresh first tap, not a triple
    }

    func testResetClearsPendingTap() {
        var d = DoubleTapDetector(window: 0.35)
        XCTAssertFalse(d.registerTap(at: 0.00))
        d.reset()
        XCTAssertFalse(d.registerTap(at: 0.10))    // previous tap was cleared
    }

    func testRightCommandKeycodeIs54() {
        XCTAssertEqual(HotkeyKeycode.rightCommand, 54)
    }
}
