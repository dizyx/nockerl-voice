import Foundation

/// Routes a transcription to the single active engine: the Custom endpoint or the
/// OpenRouter cloud. There is no fallback between them; the user picks one default in
/// Settings.
actor TranscriptionService {

    struct Outcome: Sendable, Equatable {
        let text: String
        /// Provider that produced the text: "custom" or "cloud".
        let provider: String
    }

    private let config: TranscriptionConfig
    private let custom: CustomEndpointProvider

    init(config: TranscriptionConfig = .default) {
        self.config = config
        self.custom = CustomEndpointProvider(
            baseURL: config.customEndpoint,
            timeout: config.transcriptionTimeout,
            apiKey: config.customAPIKey
        )
    }

    /// Transcribe 16 kHz mono WAV audio with the active engine. No fallback: a failure on
    /// the chosen engine surfaces to the caller.
    /// - Parameter prompt: the vocabulary/style prompt, sent to whichever engine runs.
    func transcribe(wav: Data, prompt: String?) async throws -> Outcome {
        // Shrink the upload ~10x by encoding to MP3 (macOS has no native MP3 encoder, so
        // this uses LAME). A long meeting then fits in a single request instead of
        // exceeding the provider's payload limit. Falls back to the original WAV.
        let (audio, format): (Data, AudioUploadFormat) =
            AudioEncoder.mp3(fromWAV: wav).map { ($0, AudioUploadFormat.mp3) } ?? (wav, .wav)
        DebugLog.write("transcribe: start engine=\(config.engine.rawValue) inBytes=\(wav.count) sendBytes=\(audio.count) fmt=\(format.openRouter) endpoint=\(config.customEndpoint.absoluteString) cloudKey=\(config.cloudAPIKey?.isEmpty == false)")
        switch config.engine {
        case .custom:
            let text = try await custom.transcribe(audio: audio, format: format, language: config.language, prompt: prompt)
            guard !text.isEmpty else { throw TranscriptionError.emptyTranscript }
            DebugLog.write("transcribe: custom OK len=\(text.count)")
            return Outcome(text: text, provider: custom.id)
        case .openrouter:
            return try await transcribeWithCloud(audio: audio, format: format, prompt: prompt)
        }
    }

    private func transcribeWithCloud(audio: Data, format: AudioUploadFormat, prompt: String?) async throws -> Outcome {
        guard let key = config.cloudAPIKey, !key.isEmpty else {
            DebugLog.write("transcribe: -> no cloud key")
            throw TranscriptionError.providerFailed(
                provider: "cloud", status: nil,
                detail: "No OpenRouter API key is set. Add it in Settings under OpenRouter."
            )
        }
        let cloud = OpenRouterProvider(
            apiKey: key,
            model: config.cloudModel,
            providerSlug: config.cloudProvider,
            timeout: config.transcriptionTimeout,
            enforceZDR: config.enforceZDR
        )
        let text = try await cloud.transcribe(audio: audio, format: format, language: config.language, prompt: prompt)
        guard !text.isEmpty else { throw TranscriptionError.emptyTranscript }
        DebugLog.write("transcribe: cloud OK len=\(text.count)")
        return Outcome(text: text, provider: cloud.id)
    }

    /// One-shot reachability probe at launch, for the debug log only. Best-effort: no
    /// routing depends on it, and a missing `/health` on a generic endpoint is harmless.
    func warmUp() async {
        guard config.engine == .custom else {
            DebugLog.write("warmUp: engine=openrouter (no local probe)")
            return
        }
        do {
            try await custom.checkHealth(timeout: config.healthProbeTimeout)
            DebugLog.write("warmUp: custom reachable @ \(config.customEndpoint.absoluteString)")
        } catch {
            DebugLog.write("warmUp: custom probe failed @ \(config.customEndpoint.absoluteString) :: \(error.localizedDescription)")
        }
    }
}
