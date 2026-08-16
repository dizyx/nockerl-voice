import NockerlDesign
import SwiftUI

/// A cyan chip in the `NockerlChip` language showing a word and a trailing count, separated by
/// a hairline divider: `roadmap │ 12`.
///
/// Shared by the Vocabulary chip board (selectable: tapping picks the word) and the Dashboard
/// "Most frequent words" card (static). Not in NockerlDesign yet: `NockerlChip` is
/// label-plus-optional-✕ only, with no count slot: a candidate to promote as
/// `NockerlCountChip` if the pattern keeps earning its place.
struct WordCountChip: View {
    let word: String
    let count: Int
    /// Solid accent fill + contrast ink (the NockerlChip selected treatment).
    var selected: Bool = false
    /// Read out after the word, e.g. "3 misspellings" / "12 uses".
    var countLabel: String = "uses"
    /// Non-nil makes the chip a button; nil renders it inert (static display).
    var action: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let action {
            Button(action: action) { chip }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityText)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        } else {
            chip
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityText)
        }
    }

    private var accessibilityText: String {
        "\(word), \(count) \(countLabel)"
    }

    private var chip: some View {
        let palette = NockerlPalette.resolve(colorScheme)
        let fill: Color = selected ? palette.accentPrimary : palette.accentPrimarySoft
        let ink: Color = selected ? palette.onAccent : palette.accentPrimary
        return HStack(spacing: NockerlSpace.space2) {
            Text(word)
                .font(.nockerl(size: NockerlFontSize.size12, weight: .medium))
                .foregroundColor(ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 200, alignment: .leading)
            Rectangle()
                .fill(ink.opacity(0.3))
                .frame(width: 1, height: NockerlFontSize.size12)
            Text("\(count)")
                .font(.nockerl(size: NockerlFontSize.size12, weight: .medium))
                .foregroundColor(ink.opacity(0.75))
        }
        .padding(.horizontal, NockerlSpace.space3)
        .padding(.vertical, NockerlSpace.space2)
        .background(fill)
        .clipShape(RoundedRectangle(cornerRadius: NockerlRadius.pill, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: NockerlRadius.pill, style: .continuous))
    }
}
