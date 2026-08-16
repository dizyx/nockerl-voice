import Foundation

/// Finds the speaker labels the Multiple Speakers style emits (`Alex:` / `Speaker 1:` at
/// the head of a line), so History can tint them instead of rendering a wall of text.
///
/// Pure + Foundation-only (no SwiftUI) so it is unit-testable; the colouring lives in the
/// view layer.
///
/// The heuristic is deliberately CONSERVATIVE, because a false positive puts a highlight
/// in the middle of ordinary dictation, which is worse than missing one. A label must:
///   - open the line and be followed by a colon, then whitespace or end-of-line;
///   - be at most `maxLabelCharacters` and `maxLabelWords`;
///   - carry no sentence punctuation;
///   - have EVERY word start uppercase, or be a bare number (so "Speaker 1" passes).
///
/// That last rule is what rejects ordinary prose: "Here's the thing: ..." fails on the
/// lowercase "the". A line like "Note: ..." does still match: a single-word capitalised
/// lead-in is indistinguishable from a one-name speaker, and a stray tint there is
/// harmless. Detection is by SHAPE, not by style id, so a custom style duplicated from
/// Multiple Speakers gets the same treatment for free.
enum SpeakerLabel {
    static let maxLabelCharacters = 24
    static let maxLabelWords = 4

    /// Splits a line into its speaker label (colon included) and the rest, or nil when the
    /// line is ordinary prose.
    static func split(_ line: String) -> (label: String, rest: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        guard isLabel(String(line[line.startIndex..<colon])) else { return nil }
        let afterColon = line.index(after: colon)
        // A label's colon is followed by a space or the end of the line. This rejects
        // timestamps ("10:30") and URLs ("https://…") outright.
        if afterColon < line.endIndex, !line[afterColon].isWhitespace { return nil }
        return (String(line[line.startIndex...colon]), String(line[afterColon...]))
    }

    /// Whether `candidate` (the text before the colon) looks like a speaker name.
    static func isLabel(_ candidate: String) -> Bool {
        guard !candidate.isEmpty, candidate.count <= maxLabelCharacters else { return false }
        guard candidate == candidate.trimmingCharacters(in: .whitespaces) else { return false }
        // Sentence punctuation means this is prose that happens to contain a colon.
        if candidate.contains(where: { ".,;!?".contains($0) }) { return false }
        let words = candidate.split(separator: " ")
        guard (1...maxLabelWords).contains(words.count) else { return false }
        return words.allSatisfy { word in
            if word.allSatisfy(\.isNumber) { return true }   // the "1" of "Speaker 1"
            return word.first?.isUppercase == true
        }
    }

    /// True when `text` contains at least one speaker label: lets the UI skip the
    /// attributed-string build entirely for ordinary transcripts.
    static func containsLabels(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .contains { split(String($0)) != nil }
    }
}
