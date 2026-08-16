import Foundation

/// A source of speech-to-text. Implemented by the local custom-endpoint provider
/// and the OpenRouter cloud provider. The user selects one as the active engine;
/// there is no fallback between them.
protocol TranscriptionProvider: Sendable {
    /// Stable identifier, e.g. "custom" or "cloud".
    var id: String { get }

    /// Transcribe encoded 16 kHz mono audio to text.
    /// - Parameters:
    ///   - audio: encoded audio bytes (WAV or MP3, per `format`).
    ///   - format: the wire format of `audio`.
    ///   - language: optional BCP-47 code (e.g. "en"); nil for auto-detect.
    ///   - prompt: optional vocabulary-biasing prompt, honored by both the local
    ///             and cloud providers.
    /// - Returns: the trimmed transcript text.
    func transcribe(audio: Data, format: AudioUploadFormat, language: String?, prompt: String?) async throws -> String
}
