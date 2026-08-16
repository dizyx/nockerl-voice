import XCTest
// Code under test (NockerlVoice/Transcription/WordFrequency.swift) is compiled directly into
// this non-hosted test bundle, so no module import is needed.

final class WordFrequencyTests: XCTestCase {

    func testTokenizeLowercasesAndStripsPunctuation() {
        XCTAssertEqual(
            WordFrequency.tokenize("Roadmap, roadmap. ROADMAP!"),
            ["roadmap", "roadmap", "roadmap"]
        )
    }

    func testTokenizeSplitsContractionsAndDropsTokensWithDigits() {
        // Apostrophes are separators, so contractions break into stem + suffix.
        XCTAssertEqual(WordFrequency.tokenize("Don't"), ["don", "t"])
        XCTAssertEqual(WordFrequency.tokenize("it's"), ["it", "s"])
        XCTAssertEqual(WordFrequency.tokenize("'quoted'"), ["quoted"])
        // Digit-bearing tokens (times, ids) are not interesting words.
        XCTAssertTrue(WordFrequency.tokenize("v2 3pm 14000").isEmpty)
    }

    /// The exact words observed surfacing as "most frequent" on real dictation: every
    /// one is filler.
    func testContractionsAndSpeechFillerAreFilteredOut() {
        let spoken = """
        It's that's we're I'm don't those yeah okay really actually basically
        going to think it's a thing and that's the kind of stuff we're doing
        """
        let top = WordFrequency.topWords(in: [spoken], limit: 20).map(\.word)
        for filler in ["it", "its", "that", "those", "yeah", "okay", "really",
                       "actually", "basically", "going", "think", "thing", "stuff",
                       "kind", "don", "doing"] {
            XCTAssertFalse(top.contains(filler), "\(filler) should be filtered as filler")
        }
    }

    /// …while genuine content words survive, including the two borderline ones below.
    func testContentWordsSurvive() {
        let top = WordFrequency.topWords(in: ["We need to look at the roadmap and the database"], limit: 10).map(\.word)
        XCTAssertTrue(top.contains("need"))       // borderline, but a content word: not filler
        XCTAssertTrue(top.contains("look"))       // borderline, but a content word: not filler
        XCTAssertTrue(top.contains("roadmap"))
        XCTAssertTrue(top.contains("database"))
    }

    func testTopWordsRanksByCountAndExcludesStopwords() {
        let texts = [
            "The roadmap is the roadmap for the quarter",
            "Roadmap review with the team",
        ]
        let top = WordFrequency.topWords(in: texts, limit: 5)
        XCTAssertEqual(top.first?.word, "roadmap")
        XCTAssertEqual(top.first?.count, 3)                       // case-insensitive tally
        XCTAssertFalse(top.contains { $0.word == "the" })         // stopword
        XCTAssertFalse(top.contains { $0.word == "with" })        // stopword
        XCTAssertFalse(top.contains { $0.word == "is" })          // under minLength
    }

    func testTopWordsHonorsLimitAndIsStableOnTies() {
        let top = WordFrequency.topWords(in: ["alpha bravo charlie delta"], limit: 2)
        XCTAssertEqual(top.count, 2)
        // All tie at 1 → alphabetical, so the order can't flicker between renders.
        XCTAssertEqual(top.map(\.word), ["alpha", "bravo"])
    }

    func testEmptyInputYieldsNoWords() {
        XCTAssertTrue(WordFrequency.topWords(in: []).isEmpty)
        XCTAssertTrue(WordFrequency.topWords(in: ["the and but"]).isEmpty)   // all stopwords
    }
}
