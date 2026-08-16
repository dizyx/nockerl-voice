import XCTest
@testable import NockerlVoice

/// The "one default engine" rules (auto-promote on save, manual switch, demote on
/// de-configure). Pure transitions, no UserDefaults or Keychain.
final class EngineSelectionTests: XCTestCase {

    func testConfiguringAnEngineMakesItDefault() {
        XCTAssertEqual(EngineSelection.afterConfigure(.openrouter), .openrouter)
        XCTAssertEqual(EngineSelection.afterConfigure(.custom), .custom)
    }

    func testConfiguringAnEngineStealsDefaultFromTheOther() {
        // OpenRouter is default; the user saves a Custom URL, so Custom takes over.
        XCTAssertEqual(EngineSelection.afterConfigure(.custom), .custom)
    }

    func testManualSelectHonoredOnlyWhenConfigured() {
        XCTAssertEqual(
            EngineSelection.afterManualSelect(.custom, isConfigured: true, current: .openrouter),
            .custom
        )
        // Not configured: the tap is a no-op and the default stays put.
        XCTAssertEqual(
            EngineSelection.afterManualSelect(.custom, isConfigured: false, current: .openrouter),
            .openrouter
        )
    }

    func testDeconfiguringTheActiveEnginePromotesTheOther() {
        XCTAssertEqual(
            EngineSelection.afterDeconfigure(.openrouter, current: .openrouter, otherConfigured: true),
            .custom
        )
    }

    func testDeconfiguringTheActiveEngineWithNoOtherGoesNone() {
        XCTAssertNil(
            EngineSelection.afterDeconfigure(.custom, current: .custom, otherConfigured: false)
        )
    }

    func testDeconfiguringAnInactiveEngineLeavesDefaultUnchanged() {
        XCTAssertEqual(
            EngineSelection.afterDeconfigure(.custom, current: .openrouter, otherConfigured: true),
            .openrouter
        )
    }

    func testOtherEngine() {
        XCTAssertEqual(TranscriptionEngine.openrouter.other, .custom)
        XCTAssertEqual(TranscriptionEngine.custom.other, .openrouter)
    }
}
