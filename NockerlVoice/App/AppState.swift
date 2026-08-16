import Foundation
import NockerlDesign

/// Dictation lifecycle state. The observable owner is `DictationController`.
enum DictationStatus: Equatable {
    case idle
    case recording
    case transcribing

    var symbolName: String {
        switch self {
        case .idle: return "mic"
        case .recording: return "mic.fill"
        case .transcribing: return "waveform"
        }
    }

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        }
    }
}

/// Which transcription backend produced the last result.
enum ProviderKind: String {
    case local
    case cloud

    var label: String {
        switch self {
        case .local: return "Local"
        case .cloud: return "Cloud"
        }
    }

    /// Short badge label for compact UI.
    var badge: String {
        switch self {
        case .local: return "Local"
        case .cloud: return "Cloud"
        }
    }
}
