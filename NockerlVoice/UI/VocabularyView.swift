import NockerlDesign
import SwiftUI

/// Vocabulary screen: a chip board over a detail card.
///
/// TOP ~50%: a recessed "glass" container (`.nockerlWell(.container)`, same surface as the
/// Styles screen) holding one selectable chip per word (`word · misspelling-count`) plus
/// an inline "Add word" input chip. BOTTOM: a card showing the SELECTED word (title +
/// delete) and its misspelling editor (the existing chip UX). Selecting a chip drives the
/// card; the first word is auto-selected; the empty state focuses the add-word input.
///
/// With nothing selected the bottom is a short CALLOUT rather than a half-height card, so
/// the board above it keeps the space instead of a mostly-empty panel holding it. No
/// accordions.
struct VocabularyView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var selectedTermID: UUID?
    @State private var newWordDraft = ""
    @FocusState private var addWordFocused: Bool
    @State private var editingWord = false
    @State private var wordDraft = ""
    @FocusState private var editWordFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var selectedTerm: VocabularyTerm? {
        settings.terms.first { $0.id == selectedTermID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NockerlSpace.space4) {
            header
            chipBoard        // top ~50%
            detailCard       // bottom ~50%
        }
        .padding(NockerlSpace.space6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if selectedTerm == nil { selectedTermID = settings.terms.first?.id }
            if settings.terms.isEmpty { addWordFocused = true }
        }
        .onChange(of: selectedTermID) { _, _ in
            editingWord = false   // switching words cancels an in-progress title edit
            wordDraft = ""
        }
    }

    // MARK: - Header (unchanged: title + info tip + accent "+")

    private var header: some View {
        HStack(spacing: NockerlSpace.space2) {
            SectionTitle(.vocabulary)
            // The old text described the MECHANICS ("words to spell exactly, each with
            // common mis-hearings") without ever saying what the feature is for, so the
            // screen read as a mystery list. This says what it does, when to reach for it,
            // and shows the shape of an entry.
            NockerlInfoTip(text: "Names and terms a transcriber tends to get wrong. Add a word so it is always spelled your way, and list the ways it gets misheard so those are corrected too. Reach for this when a name, a product, or a piece of jargon keeps coming back wrong. For example, add Nockerl and list knuckle and knockerl as its misspellings.")
            Spacer()
        }
    }

    // MARK: - Top: chip board (recessed glass container)

    private var chipBoard: some View {
        ScrollView {
            NockerlFlowLayout(spacing: NockerlSpace.space2, lineSpacing: NockerlSpace.space2) {
                addWordChip
                ForEach(settings.terms) { term in
                    WordCountChip(
                        word: term.word,
                        count: term.misspellings.count,
                        selected: term.id == selectedTermID,
                        countLabel: term.misspellings.count == 1 ? "misspelling" : "misspellings",
                        action: { selectedTermID = term.id }
                    )
                }
            }
            .padding(NockerlSpace.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .nockerlWell(.container)
        .frame(maxHeight: .infinity)
    }

    /// Inline "Add word" input, sized to the chip height (the same recipe the misspelling
    /// add-input uses): canvasAlt-filled pill, Outfit size12 label, trailing add glyph.
    private var addWordChip: some View {
        let palette = NockerlPalette.resolve(colorScheme)
        return HStack(spacing: NockerlSpace.space1) {
            TextField("Add word", text: $newWordDraft)
                .textFieldStyle(.plain)
                .font(.nockerl(size: NockerlFontSize.size12, weight: .medium))
                .frame(width: 120)
                .focused($addWordFocused)
                .onSubmit(commitNewWord)
                .accessibilityLabel("Add word")
            Button(action: commitNewWord) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: NockerlFontSize.size12))
                    .foregroundStyle(palette.accentPrimary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Save word")
        }
        .padding(.horizontal, NockerlSpace.space3).padding(.vertical, NockerlSpace.space2)
        .background(palette.canvasAlt, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.cardHairline))
    }

    // MARK: - Bottom: selected-word detail card

    @ViewBuilder
    private var detailCard: some View {
        if let term = selectedTerm {
            NockerlCard(elevation: .level2) {
                wordDetail(term)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
        } else {
            // A CALLOUT, not an empty state in a half-height card. The empty state centred a
            // large circular glyph that was the same book already in the sidebar and the
            // screen title, so the icon appeared three times in one view and was largest
            // where it meant least. It also centred its prose, which ran nearly edge to edge
            // in a card stretched to half the window.
            //
            // The callout is a text block: leading-aligned, its own horizontal inset, one
            // small tone icon, and only as tall as the words need. The board above it takes
            // the space the card was holding empty.
            //
            // A BANNER, not a callout. Both draw the cyan disc with the "i" glyph, which
            // is the part that was wanted, but `NockerlCallout(.important)` is the
            // framework's editorial treatment and wraps the panel in three nested cyan
            // hairline frames. That is deliberate in the component and simply too much
            // here, sitting under a board that already has its own border.
            //
            // The other callout tones were not an option: the icon is derived from the
            // tone's intent, and the neutral tones (`.note`, `.quote`) map to a nil intent,
            // so they can never draw one. `.important` was the only callout tone that
            // produced the icon at all.
            //
            // The banner gives the same disc with a single border and a soft wash, and it
            // is the shape already used for the informational block on the Transcription
            // pane, so the two read as one idea.
            NockerlBanner(
                message: "Add a name, a product, or any word you want spelled your way, then list the ways it gets misheard so those are corrected too. For example, add Nockerl as the word, with knuckle and knockerl as its misspellings.",
                intent: .info,
                title: "Teach it the words it gets wrong"
            )
        }
    }

    private func wordDetail(_ term: VocabularyTerm) -> some View {
        let palette = NockerlPalette.resolve(colorScheme)
        return VStack(alignment: .leading, spacing: NockerlSpace.space3) {
            HStack(spacing: NockerlSpace.space2) {
                if editingWord {
                    // Inline title edit, same affordance as the add rows: focused field,
                    // Enter (or ✓) saves, Esc (or ✕) cancels.
                    TextField("Word", text: $wordDraft)
                        .textFieldStyle(.plain)
                        .nockerlType(.titleMedium)
                        .foregroundStyle(palette.onCard)
                        .focused($editWordFocused)
                        .onSubmit { saveWordEdit(term) }
                        .onExitCommand(perform: cancelWordEdit)
                        .accessibilityLabel("Edit word")
                    Spacer(minLength: 0)
                    NockerlIconButton(systemName: "xmark", label: "Cancel edit",
                                      density: .compact, tint: .neutral) { cancelWordEdit() }
                    NockerlIconButton(systemName: "checkmark", label: "Save word",
                                      density: .compact, tint: .custom(palette.accentPrimary)) { saveWordEdit(term) }
                } else {
                    Text(term.word)
                        .nockerlType(.titleMedium)
                        .foregroundStyle(palette.onCard)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    NockerlIconButton(systemName: "pencil", label: "Edit word",
                                      density: .compact, tint: .neutral) { startWordEdit(term) }
                        .help("Edit word")
                    NockerlIconButton(systemName: "trash", label: "Delete word",
                                      density: .compact, tint: .destructive) { deleteTerm(term) }
                        .help("Delete word")
                }
            }
            MisspellingEditor(term: binding(for: term.id))   // scrolls internally; never grows the card
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(NockerlSpace.space4)
    }

    // MARK: - Actions

    private func commitNewWord() {
        let word = newWordDraft.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        let term = VocabularyTerm(word: word)
        settings.terms.insert(term, at: 0)   // newest first (PromptBuilder order)
        newWordDraft = ""
        selectedTermID = term.id             // the new word becomes the active selection
        addWordFocused = false
    }

    private func deleteTerm(_ term: VocabularyTerm) {
        settings.terms.removeAll { $0.id == term.id }
        if selectedTermID == term.id {
            selectedTermID = settings.terms.first?.id   // fall back to the first remaining word
        }
    }

    private func startWordEdit(_ term: VocabularyTerm) {
        wordDraft = term.word
        editingWord = true
        editWordFocused = true
    }

    private func saveWordEdit(_ term: VocabularyTerm) {
        let trimmed = wordDraft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, let index = settings.terms.firstIndex(where: { $0.id == term.id }) {
            settings.terms[index].word = trimmed   // persists via the store's didSet
        }
        editingWord = false
        editWordFocused = false
    }

    private func cancelWordEdit() {
        editingWord = false
        wordDraft = ""
        editWordFocused = false
    }

    /// An id-based `Binding` into `settings.terms` (robust to insert-at-0 reordering) so the
    /// editor's misspelling mutations persist via the store's `didSet { saveTerms() }`.
    private func binding(for id: UUID) -> Binding<VocabularyTerm> {
        Binding(
            get: { settings.terms.first { $0.id == id } ?? VocabularyTerm(word: "") },
            set: { newValue in
                if let index = settings.terms.firstIndex(where: { $0.id == id }) {
                    settings.terms[index] = newValue
                }
            }
        )
    }
}

// MARK: - Misspelling editor (the resting misspelling chips + chip-scale add-input)

/// The misspelling chips + inline add-input for one word. Ported from the previous accordion
/// detail so the misspelling UX is byte-identical. The `@Binding term` writes back to
/// `settings.terms`, so every mutation persists via the store's `didSet { saveTerms() }`.
private struct MisspellingEditor: View {
    @Binding var term: VocabularyTerm
    @State private var newMisspelling = ""
    @Environment(\.colorScheme) private var colorScheme

    /// Cap misspellings so the detail card can never overflow; the Add input hides at the cap.
    static let maxMisspellings = 5

    var body: some View {
        ScrollView {
            NockerlFlowLayout(spacing: 6, lineSpacing: 6) {
                if term.misspellings.count < Self.maxMisspellings {
                    addField
                }
                ForEach(term.misspellings, id: \.self) { misspelling in
                    MisspellingChip(text: misspelling) {
                        term.misspellings.removeAll { $0 == misspelling }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    /// Inline add-a-misspelling input: height EQUALS the NockerlChip exactly (Outfit size12
    /// label + space2/space3 padding), filled canvasAlt (INPUT) vs the chip's accent wash.
    private var addField: some View {
        let palette = NockerlPalette.resolve(colorScheme)
        return HStack(spacing: NockerlSpace.space1) {
            TextField("Add misspelling", text: $newMisspelling)
                .textFieldStyle(.plain)
                .font(.nockerl(size: NockerlFontSize.size12, weight: .medium))
                .frame(width: 110)
                .onSubmit(add)
            Button(action: add) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: NockerlFontSize.size12))
                    .foregroundStyle(palette.accentPrimary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Add misspelling")
        }
        .padding(.horizontal, NockerlSpace.space3).padding(.vertical, NockerlSpace.space2)
        .background(palette.canvasAlt, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.cardHairline))
    }

    private func add() {
        let value = newMisspelling.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, term.misspellings.count < Self.maxMisspellings,
              !term.misspellings.contains(value) else { return }
        term.misspellings.insert(value, at: 0)   // newest first, right after the Add input
        newMisspelling = ""
    }
}

// MARK: - Misspelling chip (neutral / grayscale, removable)

/// A misspelling tag: deliberately NEUTRAL (gray), not the cyan of the word chips, so the
/// bottom card reads as removable content rather than the top's navigation chips. Same pill
/// silhouette as the add-input it pairs with, plus a trailing clickable ✕.
private struct MisspellingChip: View {
    let text: String
    let onRemove: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = NockerlPalette.resolve(colorScheme)
        return HStack(spacing: NockerlSpace.space1) {
            Text(text)
                .font(.nockerl(size: NockerlFontSize.size12, weight: .medium))
                .foregroundColor(palette.onCard)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 200, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: NockerlFontSize.size10, weight: .medium))
                    .foregroundColor(palette.onCardMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(text)")
        }
        .padding(.horizontal, NockerlSpace.space3)
        .padding(.vertical, NockerlSpace.space2)
        .background(palette.canvasAlt, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(palette.cardHairline))
    }
}
