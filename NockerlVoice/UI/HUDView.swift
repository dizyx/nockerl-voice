import NockerlDesign
import SwiftUI

// MARK: - Views

// ONE persistent `NockerlRecordingHUD` renders recording / transcribing / error /
// result. The component owns the constant-height + width-only morph AND the
// fromBottom entrance/exit. The old `.id(phase)` + `.transition(.opacity)`
// cross-fade was DELETED: it destroyed & recreated a separate per-phase view, which
// made the pill "go away and come back", jump height, and skip the width morph.
// `.result(pasted:)` is a framework phase of the same shape, so
// transcribing → Pasted now width-shrinks in place. Only `hint` (the launch prompt)
// stays app-side (no framework phase), carrying the same fromBottom slide.
struct HUDView: View {
    @EnvironmentObject var state: HUDState
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            // Presence is host-driven (RecordingHUD.present/hide toggle `visible` inside
            // `withAnimation`) so the pill's fromBottom .transition plays. The panel is fully
            // click-through (v1.13.0 keyboard-only drawer): no tap-away layer; Esc closes.
            if state.visible {
                pill
            }
        }
        // Bottom-anchor the pill so the style-selector drawer expands UPWARD into the
        // (now-tall) panel instead of off the bottom of the screen; the bottom inset
        // keeps the pill near its original resting height. (Tune the inset visually.)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 60)
    }

    @ViewBuilder
    private var pill: some View {
        if state.phase.usesFrameworkHUD {
            // Persistent instance: STABLE identity across recording/transcribing/error;
            // only the `phase` prop changes, so the component morphs in place (P3
            // anatomy: cyan border · logo left · gray divider · red record dot as the
            // only warm element · theme-ink timer · wave). showsCancel/onCancel default
            // off (click-through HUD). `entrance: .fromBottom` = pop-up-in + slide-out.
            NockerlRecordingHUD(
                phase: state.phase.frameworkPhase,
                elapsedLabel: timeString,
                levels: state.levels,
                errorMessage: state.phase.errorText,
                transcribingLabel: state.transcribingLabel,   // "Transcribing…" or "Retrying N of 5"
                resultCopiedLabel: "Copied to clipboard",  // preserve our exact copy (canon default is "Copied")
                entrance: .fromBottom,
                styleSelector: styleSelectorConfig,
                // The product mark in the component's own leading slot. No size argument:
                // NockerlProductMark defaults to NockerlRecordingHUD.markHeight, which is
                // the slot the house mark occupied, so it lands on the same optical line
                // without arithmetic here. The component keeps its anatomy (divider, gaps,
                // constant pill height); only the mark differs.
                mark: NockerlProductMark(.voice)
            )
        } else {
            secondaryPill
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// The during-recording style-selector config: a resting pill showing the active style,
    /// expandable (↑) to switch. nil unless we're recording and have styles, so the base HUD
    /// is byte-identical otherwise. Passing `highlightedID` puts the drawer in v1.13.0 DRIVEN
    /// mode: chevron hidden (resting pill = bare label), no focus ring, internal keyboard
    /// stood down: Voice's CGEventTap owns ↑/↓/Return/Esc and writes the highlight here.
    private var styleSelectorConfig: NockerlHudStyleSelector? {
        guard case .recording = state.phase else { return nil }
        let hudStyles = settings.styles.map { NockerlHudStyle(id: $0.id, label: $0.name) }
        guard !hudStyles.isEmpty else { return nil }
        return NockerlHudStyleSelector(
            styles: hudStyles,
            selectedID: settings.activeStyleID,
            isOpen: Binding(get: { state.selectorOpen }, set: { state.selectorOpen = $0 }),
            showsResting: true,
            onSelect: { settings.setActiveStyle($0.id) },
            highlightedID: Binding(get: { state.highlightedID }, set: { state.highlightedID = $0 })
        )
    }

    // The non-recording pill: the component chrome mirrored so the cross-fade to/
    // from the framework recording pill reads as content-only. Leads with the same
    // size-18 mark; no divider (the component pill has none).
    private var secondaryPill: some View {
        let palette = NockerlPalette.resolve(colorScheme)
        return HStack(spacing: NockerlSpace.space2) {
            // The framework product mark at the same size 18 as before.
            //
            // The label is passed EXPLICITLY. NockerlProductMark defaults to nil, which is
            // decorative, and that is right for the sites where a wordmark sits beside the
            // mark. Here there is no wordmark: the neighbouring text is the live status, so
            // this mark carried a name before the swap and keeps it, rather than going
            // silent as a side effect of adopting the framework default.
            NockerlProductMark(.voice, size: 18, accessibilityLabel: "Nockerl")
            secondaryContent
        }
        // Height parity with the framework NockerlRecordingHUD: a CONSTANT space6
        // content band + space2 vertical / space4 horizontal padding, so the launch-hint
        // and cancelled pills are the SAME height as the recording / transcribing pill.
        .frame(height: NockerlSpace.space6)
        .padding(.vertical, NockerlSpace.space2)
        .padding(.horizontal, NockerlSpace.space4)
        .background(palette.chromeSurface)
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(secondaryBorder(palette), lineWidth: NockerlFloatingBorder.width)
        )
        .shadow(
            color: palette.shadowTint.opacity(0.65),
            radius: NockerlElevation.level3,
            x: 0,
            y: NockerlElevation.level3 / 2
        )
        .fixedSize(horizontal: true, vertical: false)   // hug width; height is the fixed band above
    }

    private func secondaryBorder(_ palette: NockerlPalette) -> Color {
        // Error + cancelled ride the STATUS family (`statusError`, law §10: warm = status).
        switch state.phase {
        case .error, .cancelled: return palette.statusError
        default: return palette.accentPrimary
        }
    }

    @ViewBuilder
    private var secondaryContent: some View {
        let palette = NockerlPalette.resolve(colorScheme)
        switch state.phase {
        case let .hint(message):
            HStack(spacing: NockerlSpace.space2) {
                Image(systemName: "command")
                    .font(.system(size: NockerlFontSize.size12, weight: .semibold))
                    .foregroundStyle(palette.accentPrimary)
                Text(message)
                    .font(.system(size: NockerlFontSize.size12, weight: .medium))
                    .foregroundStyle(palette.onCard)
            }
        case .cancelled:
            HStack(spacing: NockerlSpace.space2) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: NockerlFontSize.size12, weight: .semibold))
                    .foregroundStyle(palette.statusError)
                Text("Cancelled")
                    .font(.system(size: NockerlFontSize.size12, weight: .medium))
                    .foregroundStyle(palette.onCard)
            }
        default:
            // recording / transcribing / error / result render via the framework NockerlRecordingHUD.
            EmptyView()
        }
    }

    private var timeString: String {
        let total = Int(state.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
