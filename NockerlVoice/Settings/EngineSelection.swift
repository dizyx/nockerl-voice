import Foundation

/// The two transcription engines the app can use. Exactly one is the active "default"
/// at a time (or none, before anything is configured). There is no fallback between them.
enum TranscriptionEngine: String, CaseIterable, Identifiable, Sendable {
    case openrouter
    case custom

    var id: String { rawValue }

    /// The opposite engine (used when demoting the active one to the other).
    var other: TranscriptionEngine { self == .openrouter ? .custom : .openrouter }
}

/// Pure rules for the "one default engine" model, kept separate from `SettingsStore` so
/// the transitions can be unit-tested without UserDefaults or the Keychain.
///
/// - Auto-promote: saving a change on an engine (its key, URL, model or provider) makes it
///   the default, because you would not configure an engine you did not plan to use. This
///   applies to first setup and to any later saved change.
/// - Manual select: a "Set as default" tap is honored only when that engine is configured.
/// - Demote: removing the active engine's configuration promotes the other when it is still
///   configured, otherwise leaves nothing active.
enum EngineSelection {

    /// New default after `engine` is (re)configured with a saved change.
    static func afterConfigure(_ engine: TranscriptionEngine) -> TranscriptionEngine {
        engine
    }

    /// New default after a manual "Set as default" tap. Ignored (returns `current`) when the
    /// tapped engine is not yet configured.
    static func afterManualSelect(
        _ engine: TranscriptionEngine, isConfigured: Bool, current: TranscriptionEngine?
    ) -> TranscriptionEngine? {
        isConfigured ? engine : current
    }

    /// New default after `engine` loses its configuration. Only moves when `engine` was the
    /// active one; then it hands off to the other engine if that is configured, else `nil`.
    static func afterDeconfigure(
        _ engine: TranscriptionEngine, current: TranscriptionEngine?, otherConfigured: Bool
    ) -> TranscriptionEngine? {
        guard current == engine else { return current }
        return otherConfigured ? engine.other : nil
    }
}
