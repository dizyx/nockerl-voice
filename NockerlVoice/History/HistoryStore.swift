import Foundation
import SwiftData

/// Owns the SwiftData container for transcription history and provides writes used
/// by the dictation controller. Views read via `@Query` against the same container.
/// Text is always kept; raw-audio retention is out of scope by default.
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    let container: ModelContainer

    init(inMemory: Bool = false) {
        let schema = Schema([TranscriptionRecord.self, FailedRecording.self])
        // Per-install store selection. The app is NON-sandboxed, so a
        // default-store ModelConfiguration (no url) is shared across bundle ids: a
        // dev build under another id would open, and could `deleteAll()`, the
        // production install's real history. Three branches:
        //   • in-memory (tests): memory-only, NEVER a url (a url conflicts with the flag)
        //   • PRODUCTION persistent: NO url, keeps SwiftData's DEFAULT store, exactly
        //     as before (byte-identical, no migration; `AppPaths.historyStoreURL == nil`)
        //   • NON-production persistent: its OWN namespaced store, isolated from prod
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else if let url = AppPaths.historyStoreURL {
            // Core Data creates the store file but not its parent directory: make it.
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            configuration = ModelConfiguration(schema: schema, url: url)
        } else {
            // Production: the default store, identical to the pre-namespacing configuration.
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        }
        if let container = try? ModelContainer(for: schema, configurations: configuration) {
            self.container = container
        } else {
            // Last resort so the app still runs even if the store can't be opened.
            self.container = try! ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            )
        }
    }

    private var context: ModelContext { container.mainContext }

    func add(text: String, provider: ProviderKind, durationSec: Double, processingMs: Double?, language: String?, pasted: Bool, styleName: String = "Standard", styleID: String? = nil) {
        guard !text.isEmpty else { return }
        context.insert(TranscriptionRecord(
            text: text, provider: provider, durationSec: durationSec,
            processingMs: processingMs, language: language, pasted: pasted,
            styleName: styleName, styleID: styleID
        ))
        try? context.save()
    }

    func delete(_ record: TranscriptionRecord) {
        context.delete(record)
        try? context.save()
    }

    func deleteAll() {
        try? context.delete(model: TranscriptionRecord.self)
        try? context.save()
    }

    // MARK: - Failed recordings (audio-durability safety net)

    /// Record a failed/kept recording. The audio file (`audioFilename`) stays on
    /// disk so the user can retry or export it.
    func recordFailure(audioFilename: String, durationSec: Double, error: String, styleName: String = "Standard", styleID: String? = nil) {
        context.insert(FailedRecording(
            audioFilename: audioFilename, durationSec: durationSec, lastError: error,
            styleName: styleName, styleID: styleID
        ))
        try? context.save()
    }

    /// Remove a failed recording AND its audio file (after a successful retry or an
    /// explicit delete).
    func deleteFailure(_ record: FailedRecording) {
        RecordingStore.shared.delete(record.audioFilename)
        context.delete(record)
        try? context.save()
    }

    /// Surface any audio left on disk that has no matching `FailedRecording`, e.g.
    /// the app quit/crashed mid-transcription. Such audio becomes a retryable entry
    /// instead of being orphaned. Safe to call once at launch.
    func recoverOrphans() {
        let tracked = (try? context.fetch(FetchDescriptor<FailedRecording>()))?
            .map(\.audioFilename) ?? []
        let trackedSet = Set(tracked)
        var inserted = false
        for name in RecordingStore.shared.allFilenames() where !trackedSet.contains(name) {
            context.insert(FailedRecording(
                audioFilename: name,
                durationSec: RecordingStore.shared.durationSec(for: name),
                lastError: "Transcription was interrupted before it finished.",
                attemptCount: 0
            ))
            inserted = true
        }
        if inserted { try? context.save() }
    }
}
