import Foundation

/// Configuration for the transcription layer. The cloud (OpenRouter)
/// key is injected (it lives in the Keychain).
struct TranscriptionConfig: Sendable {
    /// The default cloud model: an audio-capable model on OpenRouter.
    /// Editable in Settings.
    static let defaultCloudModel = "xiaomi/mimo-v2.5"

    /// The Custom tier endpoint: any OpenAI-compatible transcription server. Default localhost.
    var customEndpoint: URL
    /// Optional Bearer API key for the Custom endpoint; nil or empty sends no auth header.
    var customAPIKey: String?
    /// Cloud (OpenRouter) API key; nil disables the cloud provider.
    var cloudAPIKey: String?
    /// OpenRouter model slug for the cloud tier (default `xiaomi/mimo-v2.5`).
    var cloudModel: String
    /// The chosen OpenRouter provider slug (e.g. "deepinfra"). Empty = none selected
    /// yet. Routing is strict (`only: [slug]`) with ZDR always enforced, no automatic
    /// routing.
    var cloudProvider: String
    /// BCP-47 language code, or nil for auto-detect.
    var language: String?
    /// Which engine transcribes: the Custom endpoint or the OpenRouter cloud. Exactly one,
    /// no fallback.
    var engine: TranscriptionEngine
    /// When true (default), require zero data retention on OpenRouter (non-ZDR providers are
    /// declined server-side). Off = allow any provider (your audio may be retained).
    var enforceZDR: Bool
    /// Health probe timeout (seconds).
    var healthProbeTimeout: TimeInterval
    /// Transcription request timeout (seconds).
    var transcriptionTimeout: TimeInterval
    /// How long a failed health result is trusted before re-probing (seconds).
    var healthCacheTTL: TimeInterval

    init(
        customEndpoint: URL = URL(string: "http://localhost:8000")!,
        customAPIKey: String? = nil,
        cloudAPIKey: String? = nil,
        cloudModel: String = TranscriptionConfig.defaultCloudModel,
        cloudProvider: String = "",
        language: String? = "en",
        engine: TranscriptionEngine = .openrouter,
        enforceZDR: Bool = true,
        healthProbeTimeout: TimeInterval = 3,
        transcriptionTimeout: TimeInterval = 60,
        healthCacheTTL: TimeInterval = 30
    ) {
        self.customEndpoint = customEndpoint
        self.customAPIKey = customAPIKey
        self.cloudAPIKey = cloudAPIKey
        self.cloudModel = cloudModel
        self.cloudProvider = cloudProvider
        self.language = language
        self.engine = engine
        self.enforceZDR = enforceZDR
        self.healthProbeTimeout = healthProbeTimeout
        self.transcriptionTimeout = transcriptionTimeout
        self.healthCacheTTL = healthCacheTTL
    }

    static let `default` = TranscriptionConfig()

    /// Request timeout scaled to clip length. `URLRequest.timeoutInterval` is an
    /// *idle* timeout (resets on data): for long audio the model can stay silent
    /// for minutes while it processes, so a fixed 60s would kill legitimate long
    /// requests before the server ever responds. Floor 120s, ceiling 30 min. This
    /// is a ceiling, not a wait: a fast response still returns immediately.
    static func timeout(forDurationSec duration: Double) -> TimeInterval {
        min(1800, max(120, duration * 4))
    }
}
