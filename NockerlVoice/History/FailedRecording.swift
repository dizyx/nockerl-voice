import Foundation
import SwiftData

/// A recording whose transcription failed, or was interrupted before it finished.
/// The raw audio is kept on disk (see `RecordingStore`) so it can be retried or
/// exported; we never silently lose a recording. Cleared once a retry succeeds or
/// the user deletes it (audio-durability safety net).
@Model
final class FailedRecording {
    var id: UUID
    /// Filename within `RecordingStore.directory`.
    var audioFilename: String
    var createdAt: Date
    var durationSec: Double
    var lastError: String
    /// How many transcription attempts have been made (0 = recovered orphan, never tried).
    var attemptCount: Int
    /// The dictation style ACTIVE when the recording was made: snapshotted so a failed row
    /// shows the same style badge a successful row would. Defaulted for clean migration.
    var styleName: String = "Standard"
    /// The active style's id at record time (built-in slug or custom UUID). Optional.
    var styleID: String?

    init(
        audioFilename: String,
        createdAt: Date = .now,
        durationSec: Double,
        lastError: String,
        attemptCount: Int = 1,
        styleName: String = "Standard",
        styleID: String? = nil
    ) {
        self.id = UUID()
        self.audioFilename = audioFilename
        self.createdAt = createdAt
        self.durationSec = durationSec
        self.lastError = lastError
        self.attemptCount = attemptCount
        self.styleName = styleName
        self.styleID = styleID
    }
}
