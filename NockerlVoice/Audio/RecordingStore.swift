import Foundation

/// Durable on-disk storage for raw recordings. Audio is written here BEFORE a
/// transcription attempt, so a failed (or crashed) transcription never loses the
/// recording. The file is deleted only once a transcript is safely persisted. The
/// audio-durability safety net (in-flight/failed recordings are kept; successful
/// recordings are still discarded).
@MainActor
final class RecordingStore {
    static let shared = RecordingStore()

    private let dir: URL

    init() {
        // Per-install recordings directory, derived from the bundle id. Under
        // the production bundle id this is byte-identical to the previous
        // `…/Application Support/NockerlVoice/Recordings`; a fork under another id gets
        // its OWN folder, so its `delete(_:)` (a bare removeItem) can never reach the
        // production install's real recordings.
        dir = AppPaths.recordingsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    var directory: URL { dir }

    func url(for filename: String) -> URL { dir.appendingPathComponent(filename) }

    /// Persist a WAV and return its filename (nil on write failure).
    func save(_ wav: Data) -> String? {
        let name = "\(UUID().uuidString).wav"
        do {
            try wav.write(to: url(for: name), options: .atomic)
            return name
        } catch {
            DebugLog.write("RecordingStore: save failed :: \(error.localizedDescription)")
            return nil
        }
    }

    func data(for filename: String) -> Data? { try? Data(contentsOf: url(for: filename)) }

    func delete(_ filename: String) { try? FileManager.default.removeItem(at: url(for: filename)) }

    func exists(_ filename: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: filename).path)
    }

    /// All `.wav` filenames currently on disk (used to recover orphaned audio).
    func allFilenames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.hasSuffix(".wav") } ?? []
    }

    /// Duration (seconds) of a stored 16 kHz mono 16-bit WAV, derived from file size
    /// (bytes - 44-byte header) / 2 bytes per sample / 16 kHz.
    func durationSec(for filename: String) -> Double {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url(for: filename).path)
        let size = (attrs?[.size] as? Int) ?? 0
        return Double(max(0, size - 44)) / 2.0 / 16_000.0
    }
}
