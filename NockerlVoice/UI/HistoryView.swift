import NockerlDesign
import SwiftData
import SwiftUI

/// History pane: a flat list of single-line rows that expand to the full text.
/// Each line shows the provider + date + a preview, with copy/delete on the far
/// right. Pattern mirrors the Android inbox.
///
/// NOTE: icon actions use the framework `NockerlDesign.NockerlIconButton`
/// (module-qualified) with `.compact` density + semantic tints to preserve
/// row density and action colors.
struct HistorySection: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \TranscriptionRecord.createdAt, order: .reverse) private var records: [TranscriptionRecord]
    @Query(sort: \FailedRecording.createdAt, order: .reverse) private var failedRecords: [FailedRecording]
    @State private var search = ""
    @State private var expandedID: UUID?
    @State private var copiedID: UUID?
    @State private var confirmClear = false
    @State private var retryingIDs: Set<UUID> = []
    /// Live "Retrying N of 5" label per row, published by the retry loop (HUD parity).
    @State private var retryLabel: [UUID: String] = [:]
    /// In-flight retry tasks, retained so a running retry can be cancelled from the row.
    @State private var retryTasks: [UUID: Task<Void, Never>] = [:]

    private var filtered: [TranscriptionRecord] {
        guard !search.isEmpty else { return records }
        return records.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    /// Failed rows sit at the top of the list, but only when not searching (search targets
    /// transcript text, which failed rows don't have).
    private var showFailedRows: Bool { search.isEmpty && !failedRecords.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: NockerlSpace.space4) {
            // Title alone: Clear All used to ride here and its .sm button height pushed the
            // title DOWN, so History's header sat lower than every other screen's.
            SectionTitle(.history)

            // Search shrinks to fit; Clear All sits to its right (the screen's only button).
            HStack(spacing: NockerlSpace.space2) {
                searchBar
                if !records.isEmpty {
                    NockerlButton("Clear All", variant: .destructive, size: .sm) { confirmClear = true }
                        .confirmationDialog(
                            "Delete all \(records.count) transcriptions? This removes them from disk and can't be undone.",
                            isPresented: $confirmClear, titleVisibility: .visible
                        ) {
                            Button("Delete All", role: .destructive) { HistoryStore.shared.deleteAll() }
                            Button("Cancel", role: .cancel) {}
                        }
                        .fixedSize()
                }
            }

            if filtered.isEmpty && !showFailedRows {
                NockerlEmptyState(
                    systemImage: "waveform",
                    title: records.isEmpty ? "No transcriptions yet" : "No matches",
                    description: records.isEmpty ? "Your dictations will appear here." : "Try a different search."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NockerlCard(elevation: .level2) {
                    ScrollView {
                        LazyVStack(spacing: NockerlSpace.space0) {
                            // Failed / interrupted recordings surface at the TOP as normal
                            // rows (not a banner): same chrome, with a caution mark + retry.
                            if showFailedRows {
                                ForEach(failedRecords) { failedRow($0) }
                            }
                            ForEach(filtered) { row($0) }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
        }
        .padding(NockerlSpace.space6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Error rows can carry an in-app link (the busy case points at the Transcription
        // pane). Route ours to the router and hand anything else back to the system, so a
        // real web address would still behave normally. This only changes the selected
        // section in a window the user is already looking at: it opens nothing and
        // activates nothing.
        .environment(\.openURL, OpenURLAction { url in
            DashboardRouter.shared.handle(url) ? .handled : .systemAction
        })
    }

    // The framework search field (NockerlDesign v1.3.0, the Swift parity twin):
    // recessed well, leading magnifier, trailing clear, in-place filtering, and an
    // accessible name taken from the placeholder. This screen hand-rolled that recipe
    // back when no Swift twin existed. It has existed since 2026-07-07, so the copy
    // retires and the shared component owns the chrome.
    private var searchBar: some View {
        NockerlSearchField(text: $search, placeholder: "Search transcriptions")
    }

    // MARK: - Failed / interrupted recordings (retryable, rendered as top-of-list rows)

    /// A failed recording rendered with the SAME row chrome as a transcript: style badge,
    /// date, then a yellow caution mark and the (lightly bolder) human-readable error where
    /// the transcript preview would be. Tap to expand the full error. Copy is swapped for
    /// Retry (a spinner while it runs); Delete stays.
    private func failedRow(_ rec: FailedRecording) -> some View {
        let palette = NockerlPalette.resolve(colorScheme)
        let isExpanded = expandedID == rec.id
        let isRetrying = retryingIDs.contains(rec.id)
        return VStack(alignment: .leading, spacing: NockerlSpace.space0) {
            HStack(spacing: NockerlSpace.space3) {
                Button { toggle(rec.id) } label: {
                    HStack(spacing: NockerlSpace.space2) {
                        // Same style badge a successful row shows (snapshotted at record time).
                        NockerlBadge(rec.styleName, tone: .accent, variant: .outline)
                        Text(rec.createdAt, format: .dateTime.month().day().hour().minute())
                            .nockerlType(.bodySmall)
                            .foregroundStyle(palette.onCardMuted)
                            .fixedSize()
                        if isRetrying {
                            // Active retry: the amber caution mark steps aside and the live
                            // "Retrying N of 5" progress (HUD parity) shows in accent cyan.
                            Text(retryLabel[rec.id] ?? "Retrying…")
                                .nockerlType(.bodyMedium)
                                .foregroundStyle(palette.accentPrimary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            // Caution, not alarm: an amber warning mark. Most failures are a
                            // transient busy server, so it never escalates to a red X.
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: NockerlFontSize.size12))
                                .foregroundStyle(palette.statusWarning)
                                .accessibilityLabel("Needs attention")
                            if isExpanded {
                                Spacer(minLength: 0)
                            } else {
                                // Same weight as the transcript preview. The amber caution
                                // mark + top-of-list placement is enough attention, no bold.
                                Text(oneLine(errorPlain(rec.lastError)))
                                    .nockerlType(.bodyMedium)
                                    .foregroundStyle(palette.onCard)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Retry replaces Copy; WHILE retrying it becomes a Stop button so a hung or
                // unwanted retry can always be cancelled: no dead-end retry loop.
                if isRetrying {
                    NockerlDesign.NockerlIconButton(
                        systemName: "stop.fill", label: "Cancel retry", density: .compact
                    ) { cancelRetry(rec) }
                        .help("Cancel retry")
                } else {
                    NockerlDesign.NockerlIconButton(
                        systemName: "arrow.clockwise", label: "Retry", density: .compact
                    ) { retry(rec) }
                        .help("Retry transcription")
                }
                NockerlDesign.NockerlIconButton(
                    systemName: "trash", label: "Delete",
                    density: .compact, tint: .destructive
                ) { delete(rec) }
                    .help("Delete")
            }
            .padding(.horizontal, NockerlSpace.space4)
            .padding(.vertical, NockerlSpace.space2)

            if isExpanded {
                Text(errorText(rec.lastError))
                    .nockerlType(.bodyMedium)
                    .foregroundStyle(palette.onCard)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, NockerlSpace.space4)
                    .padding(.bottom, NockerlSpace.space3)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.cardHairline).frame(height: NockerlSpace.spacePx)
        }
        .contextMenu {
            Button("Retry") { retry(rec) }
            Button("Delete", role: .destructive) { delete(rec) }
        }
    }

    private func delete(_ rec: FailedRecording) {
        if expandedID == rec.id { expandedID = nil }
        HistoryStore.shared.deleteFailure(rec)
    }

    /// Re-run a saved recording through the SAME retry policy as a live dictation
    /// (DictationController.transcribeWithRetry): auto-retry a busy server (429) up to five
    /// times two seconds apart, publishing "Retrying N of 5" into the row; ANY other error
    /// fails on the first attempt (a brief flash, then back to the error). On success the row
    /// becomes a normal transcript; on final failure it returns to a retryable error.
    private func retry(_ rec: FailedRecording) {
        guard !retryingIDs.contains(rec.id) else { return }
        guard let wav = RecordingStore.shared.data(for: rec.audioFilename) else {
            rec.lastError = "Audio file is missing. It may have been moved or deleted."
            try? context.save()
            return
        }
        let recID = rec.id
        retryingIDs.insert(recID)
        retryLabel[recID] = TranscriptionRetryPhase.attempting.label   // an attempt IS running
        if expandedID == recID { expandedID = nil }      // collapse while it runs
        var config = SettingsStore.shared.buildConfig()
        config.transcriptionTimeout = TranscriptionConfig.timeout(forDurationSec: rec.durationSec)
        let duration = rec.durationSec
        // Snapshot the CURRENT active style: a retry re-runs with today's style.
        let styleName = SettingsStore.shared.activeStyle?.name ?? "Standard"
        let styleID = SettingsStore.shared.activeStyleID
        retryTasks[recID] = Task { @MainActor in
            // Cleanup ALWAYS runs (success, failure, or cancel) so a row can never wedge in
            // the retrying state and block future retries.
            defer { retryingIDs.remove(recID); retryLabel[recID] = nil; retryTasks[recID] = nil }
            let service = TranscriptionService(config: config)
            let started = Date()
            do {
                let outcome = try await runRetry(service: service, wav: wav, id: recID)
                let ms = Date().timeIntervalSince(started) * 1000
                let provider: ProviderKind = (outcome.provider == "cloud") ? .cloud : .local
                HistoryStore.shared.add(
                    text: outcome.text, provider: provider,
                    durationSec: duration, processingMs: ms, language: nil, pasted: false,
                    styleName: styleName, styleID: styleID
                )
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(outcome.text, forType: .string)
                HistoryStore.shared.deleteFailure(rec)
            } catch {
                if Task.isCancelled {
                    // User hit Stop: a deliberate abort, not a failure. Don't count it.
                    DebugLog.write("history-retry: CANCELLED by user")
                    rec.lastError = "Retry cancelled."
                } else {
                    // Verbose reason → debug log; the row shows a short, plain message.
                    DebugLog.write("history-retry: FAILED :: \(error.localizedDescription) :: \(String(describing: error))")
                    await minFlash(since: started)   // keep the flash visible even on an instant failure
                    rec.lastError = (error as? TranscriptionError)?.historyMessage ?? "Something went wrong. Please retry."
                    rec.attemptCount += 1
                }
                try? context.save()
            }
        }
    }

    /// User hit Stop on a running retry: cancel the in-flight attempt. The retry task's own
    /// catch marks the row "Retry cancelled." and its `defer` cleans up.
    private func cancelRetry(_ rec: FailedRecording) {
        guard retryingIDs.contains(rec.id) else { return }
        retryTasks[rec.id]?.cancel()
    }

    /// History retry runs the SAME policy object as live dictation, so the two cannot drift.
    /// The only difference is where the label is published: the HUD writes it into the pill,
    /// this writes it into the row.
    @MainActor
    private func runRetry(service: TranscriptionService, wav: Data, id: UUID) async throws -> TranscriptionService.Outcome {
        try await TranscriptionRetry.run(
            service: service,
            wav: wav,
            prompt: SettingsStore.shared.buildPrompt()
        ) { phase in
            retryLabel[id] = phase.label
        }
    }

    /// Render an error that may carry a markdown link (the busy case links to the
    /// Transcription pane). Falls back to the raw string if it does not parse, so a stored
    /// message can never surface as visible markup.
    private func errorText(_ raw: String) -> AttributedString {
        (try? AttributedString(markdown: raw)) ?? AttributedString(raw)
    }

    /// The same message with any markup flattened away, for the collapsed one-line preview
    /// where a link would have nothing to be tapped in.
    private func errorPlain(_ raw: String) -> String {
        String(errorText(raw).characters)
    }

    /// Hold the active "Retrying…" state for at least a beat so a fast failure still reads as
    /// an attempt rather than an instant flicker.
    @MainActor
    private func minFlash(since start: Date) async {
        let minSec = 0.6
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < minSec {
            try? await Task.sleep(nanoseconds: UInt64((minSec - elapsed) * 1_000_000_000))
        }
    }

    private func row(_ record: TranscriptionRecord) -> some View {
        let palette = NockerlPalette.resolve(colorScheme)
        let isExpanded = expandedID == record.id
        return VStack(alignment: .leading, spacing: NockerlSpace.space0) {
            // space3 row gap: adjacent compact icon buttons
            // (copy · delete) want >=12pt between their invisible hit frames.
            HStack(spacing: NockerlSpace.space3) {
                Button { toggle(record.id) } label: {
                    HStack(spacing: NockerlSpace.space2) {
                        // The STYLE used (snapshotted at record time), title-cased so it keeps
                        // the label even if the style is later renamed/deleted. tone .accent
                        // (cyan) for now; per-style colors land when design ships
                        // NockerlBadgeTone.custom + the 5-color styleTag set.
                        NockerlBadge(record.styleName, tone: .accent, variant: .outline)
                        Text(record.createdAt, format: .dateTime.month().day().hour().minute())
                            .nockerlType(.bodySmall)   // metadata timestamp → Outfit 300/12
                            .foregroundStyle(palette.onCardMuted)
                            .fixedSize()
                        if isExpanded {
                            Spacer(minLength: 0)
                        } else {
                            Text(oneLine(record.text))
                                .nockerlType(.bodyMedium)   // transcript preview → Outfit 300/14
                                .foregroundStyle(palette.onCard)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Compact + tinted: copied feedback returns
                // to success green via .custom; delete returns to status red.
                NockerlDesign.NockerlIconButton(
                    systemName: copiedID == record.id ? "checkmark" : "doc.on.doc",
                    label: "Copy",
                    density: .compact,
                    tint: copiedID == record.id ? .custom(palette.statusSuccess) : .neutral
                ) { copy(record) }
                    .help("Copy")
                NockerlDesign.NockerlIconButton(
                    systemName: "trash", label: "Delete",
                    density: .compact, tint: .destructive
                ) { delete(record) }
                    .help("Delete")
            }
            .padding(.horizontal, NockerlSpace.space4)
            .padding(.vertical, NockerlSpace.space2)

            if isExpanded {
                // Speaker labels ("Alex:", "Speaker 1:") get a soft cyan chip so a
                // multi-speaker transcript reads as a conversation rather than a wall of
                // text. Detected by SHAPE, not by style id, so a custom style duplicated
                // from Multiple Speakers gets it too. Ordinary transcripts contain no
                // labels and fall through to a plain Text.
                Text(speakerHighlighted(record.text, palette: palette))
                    .nockerlType(.bodyMedium)   // full transcript body → Outfit 300/14
                    .foregroundStyle(palette.onCard)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, NockerlSpace.space4)
                    .padding(.bottom, NockerlSpace.space3)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.cardHairline).frame(height: NockerlSpace.spacePx)
        }
        .contextMenu {
            Button("Copy") { copy(record) }
            Button("Delete", role: .destructive) { delete(record) }
        }
    }

    private func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }

    private func toggle(_ id: UUID) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            expandedID = (expandedID == id) ? nil : id
        }
    }

    /// Renders `text` with each speaker label wearing a soft cyan chip. Line structure is
    /// rebuilt run-by-run rather than range-mutated, which keeps `String.Index` and
    /// `AttributedString.Index` from having to be converted between each other.
    private func speakerHighlighted(_ text: String, palette: NockerlPalette) -> AttributedString {
        guard SpeakerLabel.containsLabels(text) else { return AttributedString(text) }
        var out = AttributedString()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if let parts = SpeakerLabel.split(String(line)) {
                // Breathing room via THIN SPACEs (U+2009) inside the tinted run. A text-run
                // background is the only kind `Text` + `AttributedString` can draw: there is
                // no padding or corner-radius attribute, so a true rounded pill would mean
                // laying each line out as its own HStack + Capsule, which costs continuous
                // text selection across the transcript. Not worth it for a reading aid.
                var chip = AttributedString("\u{2009}\(parts.label)\u{2009}")
                chip.backgroundColor = palette.accentPrimarySoft
                chip.foregroundColor = palette.accentPrimary
                out.append(chip)
                out.append(AttributedString(parts.rest))
            } else {
                out.append(AttributedString(String(line)))
            }
            if index < lines.count - 1 { out.append(AttributedString("\n")) }
        }
        return out
    }

    private func copy(_ record: TranscriptionRecord) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // PLAIN TEXT only, deliberately. macOS would happily also carry an RTF flavour
        // (NSAttributedString.rtf(from:)) so the cyan chips survive a paste into a rich
        // editor, but pasting Nockerl's accent colour into someone's email is a
        // surprise, not a feature. The highlight is a reading aid for this screen.
        pasteboard.setString(record.text, forType: .string)
        copiedID = record.id
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedID == record.id { copiedID = nil }
        }
    }

    private func delete(_ record: TranscriptionRecord) {
        if expandedID == record.id { expandedID = nil }
        context.delete(record)
        try? context.save()
    }
}
