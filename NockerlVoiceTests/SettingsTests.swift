import XCTest

@MainActor
final class SettingsTests: XCTestCase {

    private func ephemeralDefaults() -> UserDefaults {
        UserDefaults(suiteName: "nv-test-\(UUID().uuidString)")!
    }

    func testDefaultsAreSeeded() {
        let s = SettingsStore(defaults: ephemeralDefaults())
        XCTAssertNil(s.defaultEngine)   // fresh install: nothing configured yet
        XCTAssertTrue(s.terms.isEmpty)  // fresh install: vocabulary ships empty
        XCTAssertTrue(s.localEndpoint.isEmpty)
    }

    func testVocabularyPersistsAcrossInstances() {
        let defaults = ephemeralDefaults()
        let first = SettingsStore(defaults: defaults)
        first.terms = [VocabularyTerm(word: "Foo", misspellings: ["fou"])]

        let second = SettingsStore(defaults: defaults)
        XCTAssertEqual(second.terms.count, 1)
        XCTAssertEqual(second.terms.first?.word, "Foo")
        XCTAssertEqual(second.terms.first?.misspellings, ["fou"])
    }

    func testBuildPromptUsesCustomVocabulary() {
        let s = SettingsStore(defaults: ephemeralDefaults())
        s.terms = [VocabularyTerm(word: "Zebra", misspellings: ["zeebra"])]
        let prompt = s.buildPrompt()
        XCTAssertTrue(prompt.contains("Zebra"))
        XCTAssertTrue(prompt.contains("zeebra becomes Zebra"))
        XCTAssertFalse(prompt.contains("Nockerl"))
    }

    func testBuildConfigCarriesDefaultEngine() {
        let s = SettingsStore(defaults: ephemeralDefaults())
        XCTAssertNil(s.defaultEngine)                          // fresh: nothing configured
        XCTAssertEqual(s.buildConfig().engine, .openrouter)    // safe fallback when none
        s.saveCustomEndpoint("http://127.0.0.1:9999")          // configures + auto-promotes Custom
        XCTAssertEqual(s.defaultEngine, .custom)
        XCTAssertEqual(s.buildConfig().engine, .custom)
        s.setDefaultEngine(.openrouter)                        // refused: OpenRouter unconfigured
        XCTAssertEqual(s.defaultEngine, .custom)
    }

    func testBuildConfigUsesEndpointAndOmitsLanguage() {
        let s = SettingsStore(defaults: ephemeralDefaults())
        s.localEndpoint = "http://127.0.0.1:9999"
        let config = s.buildConfig()
        XCTAssertEqual(config.customEndpoint.absoluteString, "http://127.0.0.1:9999")
        XCTAssertNil(config.language)   // never sent: providers auto-detect
    }

    // MARK: - Styles

    func testStylesMigrationByteIdentical() {
        let sample = [VocabularyTerm(word: "Zebra", misspellings: ["zeebra"])]
        XCTAssertEqual(
            PromptBuilder.build(baseBody: PromptBuilder.baseInstructions, terms: sample),
            PromptBuilder.build(terms: sample)
        )
        // The "standard" built-in body IS the baseInstructions constant (not a retyped copy).
        let standard = PromptBuilder.defaultStyles.first { $0.id == Style.defaultID }
        XCTAssertEqual(standard?.body, PromptBuilder.baseInstructions)
    }

    func testEmptyStylesFloorsToBaseInstructions() {
        let d = ephemeralDefaults()
        let s = SettingsStore(defaults: d)
        s.styles = []
        s.terms = [VocabularyTerm(word: "Zebra", misspellings: ["zeebra"])]
        // Floor: no active style -> baseInstructions + vocabulary block == today's build(terms:).
        XCTAssertEqual(s.buildPrompt(), PromptBuilder.build(terms: s.terms))
    }

    func testStylesPersistAcrossInstances() {
        let d = ephemeralDefaults()
        let first = SettingsStore(defaults: d)
        let added = first.addStyle()
        // Mutate through the store (value-type semantics) so didSet persists.
        if let i = first.styles.firstIndex(where: { $0.id == added.id }) {
            first.styles[i].name = "Mine"
            first.styles[i].body = "Custom body."
        }
        first.activeStyleID = added.id

        let second = SettingsStore(defaults: d)
        XCTAssertTrue(second.styles.contains { $0.id == added.id && $0.body == "Custom body." })
        XCTAssertEqual(second.activeStyleID, added.id)
    }

    func testSetActiveStyleChangesPrompt() {
        let s = SettingsStore(defaults: ephemeralDefaults())
        s.terms = []
        let standardPrompt = s.buildPrompt()
        // "formal", then "organized", both retired. Pinned to a live built-in.
        s.setActiveStyle("emotional")
        let emotionalPrompt = s.buildPrompt()
        XCTAssertNotEqual(standardPrompt, emotionalPrompt)
        // Anchored on the RULE rather than on the opening sentence. The opening doubles as
        // the on-screen description and gets reworded when that description is improved,
        // which broke this assertion once; the rule below is the behaviour being asserted
        // and does not move for copy reasons.
        XCTAssertTrue(emotionalPrompt.contains("punctuation, capitalization, and emphasis ONLY"))
    }

    func testSetActiveStyleRejectsUnknownID() {
        let s = SettingsStore(defaults: ephemeralDefaults())
        let before = s.activeStyleID
        s.setActiveStyle("does-not-exist")
        XCTAssertEqual(s.activeStyleID, before)
    }

    func testDeleteActiveStyleFallsBackToStandard() {
        let s = SettingsStore(defaults: ephemeralDefaults())
        let added = s.addStyle()
        s.setActiveStyle(added.id)
        s.deleteStyle(added.id)
        XCTAssertEqual(s.activeStyleID, Style.defaultID)
        XCTAssertFalse(s.styles.contains { $0.id == added.id })
    }

    func testBuiltInsAreNotDeletable() {
        let s = SettingsStore(defaults: ephemeralDefaults())
        let countBefore = s.styles.count
        s.deleteStyle(Style.defaultID)
        XCTAssertEqual(s.styles.count, countBefore)
        XCTAssertEqual(s.activeStyleID, Style.defaultID)
    }

    func testLoadStylesDedupesDuplicateIDs() {
        let d = ephemeralDefaults()
        let dupes = [
            Style(id: "custom-x", name: "One", body: "b1"),
            Style(id: "custom-x", name: "Two", body: "b2"),
            Style(id: "custom-y", name: "Three", body: "b3"),
        ]
        let data = try! JSONEncoder().encode(dupes)
        d.set(data, forKey: "transcriptionStyles")

        let s = SettingsStore(defaults: d)
        let customs = s.styles.filter { !$0.isBuiltIn }
        XCTAssertEqual(customs.count, 2)
        XCTAssertEqual(s.styles.first { $0.id == "custom-x" }?.name, "One")
    }

    func testMeetingNotesBuiltInLabelsSpeakers() {
        let mn = PromptBuilder.defaultStyles.first { $0.id == "meeting-notes" }
        XCTAssertNotNil(mn)
        XCTAssertEqual(mn?.name, "Multiple Speakers")
        XCTAssertTrue(mn?.isBuiltIn == true)
        // Multiple speakers, chronological, real names when introduced (else Speaker N),
        // with a blank line between speakers and paragraph breaks within a turn.
        XCTAssertTrue(mn?.body.contains("Speaker 1") == true)
        XCTAssertTrue(mn?.body.contains("chronological") == true)
        XCTAssertTrue(mn?.body.lowercased().contains("name") == true)
        XCTAssertTrue(mn?.body.lowercased().contains("blank line") == true)
        XCTAssertTrue(mn?.body.lowercased().contains("paragraph") == true)
    }

    func testLoadStylesMergesNewBuiltInForExistingUsers() {
        let d = ephemeralDefaults()
        // Simulate a pre-Meeting-Notes install: persisted styles WITHOUT "meeting-notes".
        let old = [
            Style(id: "standard", name: "Standard", body: "b"),
            Style(id: "custom-1", name: "Mine", body: "c"),
        ]
        d.set(try! JSONEncoder().encode(old), forKey: "transcriptionStyles")

        let s = SettingsStore(defaults: d)
        // The new built-in is merged in; the user's custom style is preserved.
        XCTAssertTrue(s.styles.contains { $0.id == "meeting-notes" && $0.isBuiltIn })
        XCTAssertTrue(s.styles.contains { $0.id == "custom-1" && $0.name == "Mine" })
    }

    // MARK: Retired built-ins (Formal / Casual / Academic / Organized, withdrawn 2026-08-01)

    func testRetiredBuiltInsAreStrippedFromExistingInstalls() {
        let d = ephemeralDefaults()
        let old = [
            Style(id: "standard", name: "Standard", body: "b"),
            Style(id: "formal", name: "Formal", body: "f"),
            Style(id: "casual", name: "Casual", body: "c"),
            Style(id: "academic", name: "Academic", body: "a"),
            Style(id: "organized", name: "Organized Thoughts", body: "o"),
            Style(id: "custom-1", name: "Mine", body: "m"),
        ]
        d.set(try! JSONEncoder().encode(old), forKey: "transcriptionStyles")

        let s = SettingsStore(defaults: d)
        for retired in ["formal", "casual", "academic", "organized"] {
            XCTAssertFalse(s.styles.contains { $0.id == retired }, "\(retired) should be gone")
        }
        // Everything else survives, and the two new built-ins arrive.
        XCTAssertTrue(s.styles.contains { $0.id == "custom-1" && $0.name == "Mine" })
        XCTAssertTrue(s.styles.contains { $0.id == "emotional" && $0.isBuiltIn })
    }

    /// The nasty case: a user whose ACTIVE style was one of the retired ones. Without the
    /// guard they'd load pointing at a style that no longer exists: no radio lit, and the
    /// prompt silently degrading to base instructions.
    func testActiveStyleOnARetiredBuiltInFallsBackToStandard() {
        let d = ephemeralDefaults()
        d.set(try! JSONEncoder().encode([
            Style(id: "standard", name: "Standard", body: "b"),
            Style(id: "academic", name: "Academic", body: "a"),
        ]), forKey: "transcriptionStyles")
        d.set("academic", forKey: "activeStyleID")

        let s = SettingsStore(defaults: d)
        XCTAssertEqual(s.activeStyleID, Style.defaultID)
        XCTAssertNotNil(s.activeStyle, "the active style must always resolve")
    }

    func testActiveCustomStyleSurvivesTheRetirement() {
        let d = ephemeralDefaults()
        d.set(try! JSONEncoder().encode([
            Style(id: "standard", name: "Standard", body: "b"),
            Style(id: "custom-9", name: "Mine", body: "m"),
        ]), forKey: "transcriptionStyles")
        d.set("custom-9", forKey: "activeStyleID")

        XCTAssertEqual(SettingsStore(defaults: d).activeStyleID, "custom-9")
    }

    func testRetiredAndBuiltInIDSetsDoNotOverlap() {
        XCTAssertTrue(Style.builtInIDs.isDisjoint(with: Style.retiredBuiltInIDs))
    }
}
