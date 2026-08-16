import Foundation

/// One vocabulary entry: a word to spell exactly, plus the misspellings that
/// should map to it. Drives the biasing prompt sent to the local model.
struct VocabularyTerm: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var word: String
    var misspellings: [String]

    init(id: UUID = UUID(), word: String, misspellings: [String] = []) {
        self.id = id
        self.word = word
        self.misspellings = misspellings
    }
}
