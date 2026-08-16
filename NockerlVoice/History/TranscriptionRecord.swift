import Foundation
import SwiftData

/// One persisted transcription: the durable record behind the "grab the last
/// transcript if a paste went wrong" safety net.
@Model
final class TranscriptionRecord {
    var id: UUID
    var text: String
    var createdAt: Date
    /// ProviderKind raw value ("local" | "cloud").
    var providerRaw: String
    var durationSec: Double
    /// Server processing time (the transcribe round-trip) in milliseconds. Optional
    /// so existing records migrate cleanly; nil means "not measured".
    var processingMs: Double?
    var language: String?
    var pasted: Bool
    /// The dictation style ACTIVE when this was transcribed: snapshotted so History keeps the
    /// label even if the style is later renamed or deleted. Defaulted so pre-Styles records
    /// migrate cleanly ("Standard" is the original built-in).
    var styleName: String = "Standard"
    /// The active style's id (built-in slug or custom UUID) at record time: drives the History
    /// tag color. Optional: older records have none (fall back to the default tag color).
    var styleID: String?

    init(
        text: String,
        createdAt: Date = .now,
        provider: ProviderKind,
        durationSec: Double = 0,
        processingMs: Double? = nil,
        language: String? = nil,
        pasted: Bool,
        styleName: String = "Standard",
        styleID: String? = nil
    ) {
        self.id = UUID()
        self.text = text
        self.createdAt = createdAt
        self.providerRaw = provider.rawValue
        self.durationSec = durationSec
        self.processingMs = processingMs
        self.language = language
        self.pasted = pasted
        self.styleName = styleName
        self.styleID = styleID
    }

    var provider: ProviderKind { ProviderKind(rawValue: providerRaw) ?? .local }
}
