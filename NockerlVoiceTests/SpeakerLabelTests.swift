import XCTest
// Code under test (NockerlVoice/Transcription/SpeakerLabel.swift) is compiled directly
// into this non-hosted test bundle, so no module import is needed.

final class SpeakerLabelTests: XCTestCase {

    // MARK: Real labels the Multiple Speakers style emits

    func testNamedSpeakerIsALabel() {
        let parts = SpeakerLabel.split("Alex: we should ship it")
        XCTAssertEqual(parts?.label, "Alex:")
        XCTAssertEqual(parts?.rest, " we should ship it")
    }

    func testNumberedSpeakerIsALabel() {
        XCTAssertEqual(SpeakerLabel.split("Speaker 1: hello there")?.label, "Speaker 1:")
        XCTAssertEqual(SpeakerLabel.split("Speaker 12: hello")?.label, "Speaker 12:")
    }

    func testFullNameIsALabel() {
        XCTAssertEqual(SpeakerLabel.split("Sarah Chen: agreed")?.label, "Sarah Chen:")
    }

    func testLabelWithNothingAfterTheColon() {
        XCTAssertEqual(SpeakerLabel.split("Alex:")?.label, "Alex:")
    }

    // MARK: Prose that must NOT be highlighted (the expensive failure)

    func testOrdinaryProseWithAColonIsNotALabel() {
        // Fails on the lowercase "the"/"thing": the rule that carries most of the weight.
        XCTAssertNil(SpeakerLabel.split("Here's the thing: we should go"))
        XCTAssertNil(SpeakerLabel.split("My favourite part was this: the ending"))
    }

    func testTimestampsAndURLsAreNotLabels() {
        XCTAssertNil(SpeakerLabel.split("10:30 was when we started"))   // no space after colon
        XCTAssertNil(SpeakerLabel.split("https://example.com is the link"))
    }

    func testSentencePunctuationDisqualifies() {
        XCTAssertNil(SpeakerLabel.split("Wait, Alex: what?"))
        XCTAssertNil(SpeakerLabel.split("I said no. Alex: yes"))
    }

    func testOverlongOrTooManyWordsIsNotALabel() {
        XCTAssertNil(SpeakerLabel.split("A Very Long Speaker Name Indeed: hi"))  // 6 words
        XCTAssertNil(SpeakerLabel.split(String(repeating: "A", count: 25) + ": hi"))
    }

    func testLabelMustOpenTheLine() {
        XCTAssertNil(SpeakerLabel.split("  Alex: indented"))
        XCTAssertNil(SpeakerLabel.split("and then Alex: said no"))
    }

    // MARK: containsLabels (the cheap gate the view uses)

    func testContainsLabelsDetectsAMultiSpeakerTranscript() {
        let transcript = """
        Alex: we should ship it today.

        Speaker 2: I'd rather wait for the tests.
        """
        XCTAssertTrue(SpeakerLabel.containsLabels(transcript))
    }

    func testContainsLabelsIsFalseForOrdinaryDictation() {
        let transcript = """
        I need to remember to email the team about the roadmap.
        Here's the thing: we are already behind.
        """
        XCTAssertFalse(SpeakerLabel.containsLabels(transcript))
    }

    func testEmptyAndWhitespaceAreSafe() {
        XCTAssertNil(SpeakerLabel.split(""))
        XCTAssertNil(SpeakerLabel.split("   "))
        XCTAssertFalse(SpeakerLabel.containsLabels(""))
    }
}
