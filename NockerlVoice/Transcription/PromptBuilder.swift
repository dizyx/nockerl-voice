import Foundation

/// Builds the vocabulary-biasing prompt from a list of `VocabularyTerm`s (each a
/// word + its misspellings). Sent to the transcription model: the same prompt now
/// goes to BOTH the local and cloud (OpenRouter MiMo) tiers.
enum PromptBuilder {

    static let baseInstructions =
        "Transcribe this audio. Apply light grammar formatting and natural " +
        "punctuation. Use paragraph breaks when the speaker shifts topics or " +
        "pauses. Remove filler words -- specifically do NOT include 'um', 'uh', " +
        "or 'ah' in the transcript. Do NOT summarize, do NOT add timestamps, do " +
        "NOT label speakers."

    /// Default vocabulary. Ships empty: Nockerl Voice is a general-purpose
    /// dictation tool with no built-in terms. Add your own words (and their
    /// common mis-hearings) in the Vocabulary screen; they persist on-device.
    static let defaultTerms: [VocabularyTerm] = []

    /// The three built-in styles. `standard.body` references `baseInstructions`
    /// (not a retyped copy) so existing users' prompts are byte-identical after
    /// the Styles migration - verified by `testStylesMigrationByteIdentical`.
    ///
    /// Formal / Casual / Academic were retired 2026-08-01 (three shades of the same
    /// register tweak); Organized Thoughts joined them the same day, restructuring
    /// speech turned out to be a different product from transcribing it. See
    /// `Style.retiredBuiltInIDs` for how they are removed from existing installs.
    static let defaultStyles: [Style] = [
        Style(id: "standard", name: "Standard", body: baseInstructions),

        // Sentiment reaches the page through PUNCTUATION AND CASE ONLY. The hard rails
        // are the two negatives: never invent emotion, never write stage directions.
        // DISPLAY NAME ONLY. The id stays "emotional" and must not be touched: it is in
        // Style.builtInIDs, activeStyleID persists it across launches, and changing it
        // would strand everyone currently using this style, which is exactly the situation
        // retiredBuiltInIDs exists to clean up after. A cosmetic rename is not worth
        // manufacturing that. The rename does reach existing installs anyway, because
        // SettingsStore.loadStyles refreshes known built-ins from these defaults.
        //
        // "Emotional" consistently read as "this adds emotion", which is the opposite of
        // what the prompt below insists on. "Tone" over "Tonal" because the sibling styles
        // are noun phrases (Standard, Multiple Speakers) and an adjective reads oddly in
        // that list, and because the Styles screen already uses the word "tone" in its own
        // description of what a style does, so the two now agree.
        //
        // The opening sentence is also reworded, because it doubles as the description on
        // screen: expanding a style shows this body verbatim, so it was carrying the
        // explanation the name could not. Every behavioural rule below is unchanged.
        Style(id: "emotional", name: "Tone", body: "Transcribe this audio and let the punctuation carry how the speaker sounded. This does NOT add emotion or commentary: it reads tone, volume, pace, and energy, and reflects them in punctuation, capitalization, and emphasis only. A neutral recording must read exactly like an ordinary transcript.\n\nReflect the speaker's emotional state through punctuation, capitalization, and emphasis ONLY:\n- excited or enthusiastic: exclamation marks and energetic phrasing\n- shouting or heavily stressing a word: FULL CAPS on the words actually stressed\n- angry or frustrated: short, clipped sentences and emphatic punctuation\n- uncertain or hesitant: question marks, and an ellipsis where they trailed off\n- sad or low-energy: quieter punctuation, pauses as commas or ellipses\n- calm or neutral: ordinary punctuation and no embellishment\n\nNever invent emotion that is not there - a calm sentence stays calm, and a neutral recording should read exactly like a normal transcript. Do NOT write stage directions such as '(laughs)', '(sighs)', or '(angrily)'. Do NOT add or remove words to intensify the feeling: preserve exactly what was said. Remove filler words; do NOT include 'um', 'uh', or 'ah'. Do NOT add timestamps or label speakers."),

        Style(id: "meeting-notes", name: "Multiple Speakers", body: "Transcribe this audio with multiple speakers. Identify each distinct speaker by voice. If a speaker states their own name (for example, 'I'm Alex', 'This is Sarah', or 'Kyle here'), use that real name as their label for the whole transcript; otherwise fall back to Speaker 1, Speaker 2, Speaker 3, and so on, numbered in the order they first speak. Write the conversation in chronological order. Start each speaker's turn on a new line that begins with their name or label and a colon (for example, 'Alex: ...' or 'Speaker 1: ...'), and leave a blank line between one speaker's turn and the next so each turn is easy to read. Within a single turn, break long speech into natural paragraphs when the topic shifts or the speaker pauses. Preserve exactly what each person said; do not add, omit, paraphrase, or summarize. Apply light grammar formatting and natural punctuation. Remove filler words; do NOT include 'um', 'uh', or 'ah'. Do NOT add timestamps or commentary."),
    ]

    /// Build the prompt from the default vocabulary.
    static func build() -> String { build(terms: defaultTerms) }

    /// The auto-generated, always-appended vocabulary block (leading space when
    /// non-empty). Extracted verbatim from the old `build(terms:)` so output is
    /// byte-identical.
    static func vocabularyBlock(terms: [VocabularyTerm]) -> String {
        var block = ""

        let words = terms.map(\.word)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !words.isEmpty {
            block += " Domain vocabulary: when you hear any of these terms or a " +
                "close phonetic match, transcribe them with EXACTLY this spelling " +
                "and capitalization: "
            block += words.joined(separator: ", ") + "."
        }

        let corrections = terms.flatMap { term in
            term.misspellings
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { "\($0) becomes \(term.word)" }
        }
        if !corrections.isEmpty {
            block += " For example: " + corrections.joined(separator: "; ") + "."
        }
        return block
    }

    /// Build a prompt from an arbitrary instruction body + the vocabulary block.
    static func build(baseBody: String, terms: [VocabularyTerm]) -> String {
        baseBody + vocabularyBlock(terms: terms)
    }

    /// Back-compat: equivalent to `build(baseBody: baseInstructions, terms:)`.
    /// Existing call sites and tests are unchanged.
    static func build(terms: [VocabularyTerm]) -> String {
        build(baseBody: baseInstructions, terms: terms)
    }
}
