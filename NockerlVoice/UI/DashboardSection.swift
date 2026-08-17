import Charts
import NockerlDesign
import SwiftData
import SwiftUI

/// Dashboard / overview pane: at-a-glance metrics + a transcriptions-over-time chart,
/// over the animated facet background.
struct DashboardSection: View {
    @Query private var records: [TranscriptionRecord]
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.colorScheme) private var colorScheme

    /// Whether either transcription route is set up. Both count: a local endpoint is as
    /// valid a configuration as a hosted key, and saying only "add an API key" would send
    /// someone running a local model to buy something they do not need.
    private var hasEngine: Bool { settings.openrouterConfigured || settings.customConfigured }

    private var totalWords: Int {
        records.reduce(0) { $0 + $1.text.split { $0.isWhitespace }.count }
    }
    private var durations: [Double] { records.map(\.durationSec).filter { $0 > 0.1 } }
    private var average: Double { durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count) }

    /// Per-day transcription counts for the last 30 days.
    private var dailyCounts: [DayCount] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: records) { calendar.startOfDay(for: $0.createdAt) }
        let today = calendar.startOfDay(for: Date())
        return (0..<30).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            return DayCount(date: day, count: grouped[day]?.count ?? 0)
        }
    }

    private let columns = [
        GridItem(.flexible(), spacing: NockerlSpace.space3),
        GridItem(.flexible(), spacing: NockerlSpace.space3)
    ]

    var body: some View {
        // Before the first transcription the stat grid is FOUR ZEROES, which reads as a
        // broken dashboard rather than a new one, so it is not rendered at all until there
        // is something to count. What replaces it depends on what is actually missing.
        //
        // This deliberately repeats what the welcome window says. That is the point: the
        // failure being designed against is someone dismissing the welcome and then being
        // stranded, and the dashboard is where they will look next, so it has to answer on
        // its own rather than assuming a window they may never have read.
        if records.isEmpty {
            VStack(alignment: .leading, spacing: NockerlSpace.space3) {
                SectionTitle(.dashboard)
                // maxHeight infinity is what fixes the reported alignment defect. The old
                // empty state sat in a leading-aligned VStack directly under the grid, so
                // it hugged the cards with a large void beneath it. Given the remaining
                // height, its own centred stack lands in the middle of the space instead.
                gettingStarted
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(NockerlSpace.space6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            stats
        }
    }

    /// What to do next, in the user's terms, for whichever state they are actually in.
    private var gettingStarted: some View {
        let palette = NockerlPalette.resolve(colorScheme)
        return VStack(spacing: NockerlSpace.space4) {
            Spacer(minLength: 0)
            if hasEngine {
                // Configured but nothing dictated: the only thing left to learn is how to
                // start, so teach the hotkey and nothing else.
                // The plain `command` symbol. `RightCommandIcon` was a two-keycap drawing
                // that never read at small sizes and was deleted; the body copy below says
                // "Right", which is where the side belongs anyway.
                Image(systemName: "command")
                    .font(.system(size: NockerlFontSize.size24))
                    .foregroundStyle(palette.accentPrimary)
                guidanceText(
                    title: "You are ready to dictate",
                    body: "Double-tap the Right Command key to start recording, then tap it once to stop. Your text is pasted straight into whatever app you are using, and your stats will appear here after the first one.",
                    palette: palette
                )
            } else {
                // Nothing configured: no point teaching the hotkey, because pressing it
                // would do nothing. Name BOTH routes, since either is sufficient.
                Image(systemName: "waveform")
                    .font(.system(size: NockerlFontSize.size24))
                    .foregroundStyle(palette.accentPrimary)
                guidanceText(
                    title: "Connect a transcription engine",
                    body: "Nockerl Voice cannot transcribe anything until one is connected. Add an OpenRouter API key to use a hosted model, or set a custom endpoint if you run a model on your own machine. Either one on its own is enough.",
                    palette: palette
                )
                NockerlButton("Open Transcription settings", variant: .tertiary, size: .sm) {
                    // Switch panes through the shared router. Deliberately NOT openWindow
                    // and NOT NSApp.activate: this window is already frontmost, and using
                    // those here is what buried the welcome window once before.
                    DashboardRouter.shared.section = .transcription
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: NockerlSize.containerLg)
        .frame(maxWidth: .infinity)
    }

    private func guidanceText(title: String, body: String, palette: NockerlPalette) -> some View {
        VStack(spacing: NockerlSpace.space2) {
            Text(title)
                .nockerlType(.titleSmall)
                .foregroundStyle(palette.onCanvas)
            Text(body)
                .nockerlType(.bodySmall)
                .foregroundStyle(palette.onCanvasMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The dashboard proper, once there is something to show.
    private var stats: some View {
        ScrollView {
            // space3: the SAME gap the stat grid uses internally, so the space above/below
            // the Most Frequent Words card matches the space between two stat tiles. (It was
            // space4, which made the section gaps visibly wider than the tile gaps.)
            VStack(alignment: .leading, spacing: NockerlSpace.space3) {
                SectionTitle(.dashboard)

                // NockerlStatCard, the metrics-tile canon, replaces
                // the local StatCard/ProcessingCard compositions.
                LazyVGrid(columns: columns, spacing: NockerlSpace.space3) {
                    // All tiles take the compact density (32pt plate /
                    // space3 / space2) so the six-tile grid + chart fit the 880×600
                    // dashboard without scrolling.
                    // Opt-in tint (pin NockerlStatCard.swift L120 `tint:
                    // NockerlStatTint? = nil`; soft icon-plate wash). Only the two
                    // NON-WARM sanctioned hues are used: `.accent` (cyan, L67→
                    // accentPrimary) and `.success` (green, L70→statusSuccess); the
                    // warm `.warning`/`.danger` stay status-reserved (none here).
                    // Mapping: counts → cyan; durations → green; providers by
                    // identity (Local = green on-device/healthy, Cloud = cyan cloud).
                    // `gradient: true` (pin NockerlStatCard.swift
                    // L122 `gradient: Bool = false` → forwards to NockerlCard L147): a
                    // SUBTLE theme-following 160° diagonal cardSurface2→cardSurface1 sheen
                    // (~1-step surface delta, NOT the loud featured cyan). Default false =
                    // byte-identical flat fill; opt-in is purely additive.
                    // Counts are locale-formatted (1,234 not 1234): large totals were
                    // unreadable as bare digits.
                    NockerlStatCard(label: "Transcriptions", value: records.count.formatted(), density: .compact, tint: .accent, iconMode: .inset) {
                        Image(systemName: "waveform")
                    }
                    NockerlStatCard(label: "Words transcribed", value: totalWords.formatted(), density: .compact, tint: .accent, iconMode: .inset) {
                        Image(systemName: "textformat")
                    }
                    NockerlStatCard(label: "Total time", value: duration(durations.reduce(0, +)), density: .compact, tint: .accent, iconMode: .inset) {
                        Image(systemName: "clock")
                    }
                    NockerlStatCard(label: "Longest", value: duration(durations.max() ?? 0), density: .compact, tint: .accent, iconMode: .inset) {
                        Image(systemName: "arrow.up.right")
                    }
                    // The Local / Cloud average-processing-time tiles were removed. They
                    // reported infrastructure latency rather than anything about the user's
                    // dictation. The freed cell is where the Most Frequent Words card lands.
                }

                // No empty branch here any more: `body` routes to `gettingStarted` before
                // this is ever built, so by this point there is at least one record.
                frequentWordsCard
                chartCard
            }
            .padding(NockerlSpace.space6)
            .frame(maxWidth: NockerlGrid.containerMd, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // No elastic bounce when the content already fits, which on this fixed 880x600
        // window is almost always. The ScrollView is the ROOT of this section, and a root
        // ScrollView on macOS rubber-bands on a trackpad even with nothing to scroll to, so
        // the page felt loose and unfinished. Vocabulary, Styles and History never did that
        // because their roots are fixed VStacks with ScrollViews only around the one region
        // that genuinely scrolls.
        //
        // `.basedOnSize` rather than removing the ScrollView. Removing it would clip
        // anything that ever did overflow, and these pages can: a long provider list, a
        // narrower window, larger accessibility text. This keeps real scrolling and takes
        // away only the bounce that had nothing to scroll.
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
    }

    /// The words this user actually says most, as cyan `word │ count` chips. Full width and
    /// roughly double a stat tile's height (the room freed by dropping the Local / Cloud and
    /// Average-length tiles), so ten chips can wrap without crowding.
    private var frequentWordsCard: some View {
        let palette = NockerlPalette.resolve(colorScheme)
        // 8 chips, not 10: two comfortable rows at typical widths. Ten pushed to a third row
        // and made the Dashboard scroll.
        let words = WordFrequency.topWords(in: records.map(\.text), limit: 8)
        return NockerlCard(elevation: .level2, gradient: true) {
            VStack(alignment: .leading, spacing: NockerlSpace.space2) {
                // Same eyebrow recipe as the stat tiles + the chart header.
                Text("Most frequent words")
                    .font(.nockerl(size: NockerlFontSize.size12, weight: .medium))
                    .textCase(.uppercase)
                    .foregroundStyle(palette.onCardMuted)
                Group {
                    if words.isEmpty {
                        Text("Dictate a little more and your most-used words will show up here.")
                            .nockerlType(.bodySmall)
                            .foregroundStyle(palette.onCardMuted)
                    } else {
                        NockerlFlowLayout(spacing: NockerlSpace.space2, lineSpacing: NockerlSpace.space2) {
                            ForEach(words) { entry in
                                WordCountChip(word: entry.word, count: entry.count, countLabel: "uses")
                            }
                        }
                    }
                }
                // Reserve the two chip rows this card is sized for, so its height stops
                // depending on how much the user has dictated. After a first transcription
                // there are only two or three words, the card collapsed to a single row,
                // the chart rode up to meet it, and the dashboard ended in a band of empty
                // space. It now holds the same shape from the first transcription as it
                // does once the list is full, and still grows past two rows if the chips
                // wrap further.
                //
                // Derived from the chip's own metrics rather than picked by eye: a chip is
                // a size12 label with space2 padding above and below, which comes to
                // space8 tall, and the rows are separated by the same space2 this layout
                // already passes as its lineSpacing.
                .frame(
                    maxWidth: .infinity,
                    minHeight: NockerlSpace.space8 * 2 + NockerlSpace.space2,
                    alignment: .topLeading
                )
            }
            .padding(NockerlSpace.space3)   // tighter than the chart card: this is a chip strip
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var chartCard: some View {
        let palette = NockerlPalette.resolve(colorScheme)
        // The deep-gradient stop is now the WIRED semantic slot:
        // `palette.accentPrimaryDark` resolves to dark cyan.600 / light cyan.900:
        // the SAME NockerlDarkColors/NockerlLightColors.accentPrimaryDark the interim
        // scheme ternary read (rendered value unchanged), so the light gradient still
        // reads two ramp steps (accentPrimary cyan.700 → cyan.900). Retires the
        // hand-rolled ternary; the palette-slot gap is closed.

        // The chart card takes the same subtle diagonal
        // gradient as the tiles (pin NockerlCard.swift L73 `gradient: Bool = false`).
        // Default false = byte-identical flat fill.
        return NockerlCard(elevation: .level2, gradient: true) {
            VStack(alignment: .leading, spacing: NockerlSpace.space2) {
                // EXACTLY the stat-card label recipe (NockerlStatCard.swift:155-157):
                // Outfit size12/.medium + uppercase + onCardMuted, so the chart header reads
                // as a peer of the tiles above it. "last 30 days" dropped: the x-axis says so.
                Text("Transcriptions")
                    .font(.nockerl(size: NockerlFontSize.size12, weight: .medium))
                    .textCase(.uppercase)
                    .foregroundStyle(palette.onCardMuted)

                Chart(dailyCounts) { item in
                    BarMark(
                        x: .value("Day", item.date, unit: .day),
                        y: .value("Transcriptions", item.count)
                    )
                    .foregroundStyle(
                        LinearGradient(colors: [palette.accentPrimary, palette.accentPrimaryDark],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .cornerRadius(NockerlRadius.track)
                }
                // 108 → 156. The window is a fixed 880×600 (DashboardView), and at 108 the
                // page ended roughly 60pt short of the bottom, so the chart was small AND
                // the screen looked unfinished. The extra 48 spends most of that gap and
                // leaves about 12pt of slack.
                //
                // The old fit math here budgeted for a Most Frequent Words card that could
                // collapse to a single chip row. It no longer can: that card reserves two
                // rows so its height stops moving with how much the user has dictated,
                // which is what makes a fixed chart height safe to tune against.
                //
                // The content is inside a ScrollView, so overshooting costs a scrollbar
                // rather than clipped content. If it does scroll at 880×600, step back down
                // the ladder 156 → 144 → 132. RUNTIME-UNVERIFIED: measured off a screenshot,
                // not from a running layout.
                .frame(height: 156)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 6)) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .foregroundStyle(palette.onCardMuted)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisGridLine().foregroundStyle(palette.cardHairline)
                        AxisValueLabel().foregroundStyle(palette.onCardMuted)
                    }
                }
            }
            .padding(NockerlSpace.space4)
        }
    }

    private func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        return "\(total / 60)m \(total % 60)s"
    }

}

private struct DayCount: Identifiable {
    let date: Date
    let count: Int
    var id: Date { date }
}
