import Foundation

/// One counted word for the Dashboard "Most frequent words" card.
struct WordCount: Identifiable, Equatable, Sendable {
    let word: String
    let count: Int
    var id: String { word }
}

/// Counts the words a user actually dictates, ignoring the filler that dominates any English
/// text ("the", "is", "a", …). Pure + static so it is unit-testable without any UI.
enum WordFrequency {

    /// Words that say nothing about what the user actually talks about. Three groups:
    ///
    /// 1. The standard English function-word list (the NLTK set): articles, pronouns,
    ///    prepositions, auxiliaries.
    /// 2. CONTRACTION STEMS: because `tokenize` splits on apostrophes, "it's" arrives as
    ///    "it" + "s" and "don't" as "don" + "t". The one- and two-letter halves fall out under
    ///    `minLength`, but stems like "don"/"wouldn"/"isn" are 3+ chars and must be listed
    ///    explicitly or they show up as words (this is exactly why NLTK carries them too).
    /// 3. SPEECH FILLER: dictation is spoken, so it is dense with discourse particles
    ///    ("yeah", "okay", "basically", "gonna") that written-text lists don't bother with.
    ///
    /// Deliberately NOT included: "look" and "need" (they read as real content words).
    static let stopwords: Set<String> = [
        // 1. Standard English function words (3+ chars; shorter ones fall out on minLength)
        "the", "and", "but", "for", "nor", "yet", "not", "you", "your", "yours", "yourself",
        "yourselves", "our", "ours", "ourselves", "myself", "him", "his", "himself", "she",
        "her", "hers", "herself", "its", "itself", "they", "them", "their", "theirs",
        "themselves", "what", "which", "who", "whom", "this", "that", "these", "those",
        "are", "was", "were", "been", "being", "have", "has", "had", "having", "does", "did",
        "doing", "the", "because", "until", "while", "with", "about", "against", "between",
        "into", "through", "during", "before", "after", "above", "below", "from", "down",
        "out", "off", "over", "under", "again", "further", "then", "once", "here", "there",
        "when", "where", "why", "how", "all", "any", "both", "each", "few", "more", "most",
        "other", "some", "such", "only", "own", "same", "than", "too", "very", "can", "will",
        "just", "should", "now", "also", "even", "much", "many", "well", "back", "still",
        "every", "another", "around", "would", "could", "might", "must", "shall", "upon",
        "whose", "whether", "though", "although", "since", "unless", "however", "therefore",
        // 2. Contraction stems left behind after splitting on apostrophes
        "don", "doesn", "didn", "wasn", "weren", "isn", "aren", "hasn", "haven", "hadn",
        "won", "wouldn", "couldn", "shouldn", "mustn", "mightn", "needn", "shan", "ain",
        "let", "lets", "cannot",
        // 3. Spoken-language filler and discourse particles
        "yeah", "yes", "okay", "sure", "right", "well", "like", "really", "actually",
        "basically", "literally", "obviously", "probably", "definitely", "maybe", "perhaps",
        "gonna", "wanna", "gotta", "kinda", "sorta", "sort", "kind", "thing", "things",
        "stuff", "lot", "lots", "bit", "way", "ways", "something", "anything", "nothing",
        "everything", "someone", "anyone", "everyone", "somebody", "anybody", "everybody",
        "little", "big", "good", "great", "nice", "bad", "sure", "mean", "means", "meant",
        "think", "thinks", "thought", "know", "knows", "knew", "want", "wants", "wanted",
        "going", "goes", "went", "gone", "get", "gets", "got", "getting", "make", "makes",
        "made", "making", "say", "says", "said", "saying", "see", "sees", "saw", "seen",
        "come", "comes", "came", "give", "gives", "gave", "take", "takes", "took", "taken",
        "put", "puts", "use", "uses", "used", "using", "try", "tries", "tried", "trying",
        "time", "times", "day", "days", "one", "two", "first", "last", "next", "new", "old",
        "guess", "sorry", "please", "thanks", "thank", "hey", "hello", "alright",
    ]

    /// The `limit` most-used words across `texts`, most frequent first. Words are lowercased,
    /// stripped of punctuation, and filtered: stopwords out, anything under `minLength` out,
    /// pure numbers out. Ties break alphabetically so the order is stable between renders.
    static func topWords(in texts: [String], limit: Int = 10, minLength: Int = 3) -> [WordCount] {
        var counts: [String: Int] = [:]
        for text in texts {
            for token in tokenize(text) where token.count >= minLength && !stopwords.contains(token) {
                counts[token, default: 0] += 1
            }
        }
        // Split into explicitly-typed steps: as one chained expression the Swift type-checker
        // times out ("unable to type-check this expression in reasonable time").
        var ranked: [WordCount] = counts.map { WordCount(word: $0.key, count: $0.value) }
        ranked.sort { (lhs: WordCount, rhs: WordCount) -> Bool in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.word < rhs.word   // stable alphabetical tie-break
        }
        return Array(ranked.prefix(limit))
    }

    /// Lowercased word tokens. APOSTROPHES ARE SEPARATORS, so contractions break into their
    /// parts: "it's" → "it" + "s", "don't" → "don" + "t", "we're" → "we" + "re". The short
    /// halves fall out under `minLength` and the stems are listed in `stopwords`, which is how
    /// contractions get filtered without enumerating every one of them. Digits are kept during
    /// the split (not separators) purely so a mixed token stays whole and can be dropped as a
    /// unit. Otherwise "v2" would split into "v" and survive as a bogus word.
    static func tokenize(_ text: String) -> [String] {
        let separated = text.lowercased().split { (c: Character) -> Bool in
            !(c.isLetter || c.isNumber)
        }
        var tokens: [String] = []
        for piece in separated {
            let token = String(piece)
            // Drop anything carrying a digit: times, versions, counts and IDs ("3pm", "v2",
            // "14000") are not interesting words.
            if !token.isEmpty, !token.contains(where: \.isNumber) {
                tokens.append(token)
            }
        }
        return tokens
    }
}
