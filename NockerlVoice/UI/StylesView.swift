import NockerlDesign
import SwiftUI

/// Styles pane: a compact radio-LIST of styles inside a recessed bounded container.
///
/// Each row has three separate, unambiguous interactions:
///   - the RADIO sets the default style (exactly one, always);
///   - the ROW / chevron expands to read the prompt;
///   - the PENCIL (custom styles only) puts the row into edit mode.
///
/// Edit mode is deliberately explicit and covers BOTH fields at once. One pencil opens
/// the title and the prompt together, and one commit/discard pair closes them together.
/// Nothing auto-saves and nothing auto-cancels: clicking from the title into the prompt
/// keeps the edit alive, and a draft can only leave through the checkmark or the cross.
/// The previous design committed a rename on the Enter key alone, with no visible hint
/// that Enter was required, so clicking away silently discarded the new name and left
/// the old one in place. That is the bug this structure removes.
///
/// Built-ins are read-only: no rename, no delete, no pencil, prompt shown as plain text.
/// Duplicate is how you make one yours.
///
/// The field well appears ONLY while something is editable. It is a recessed input
/// affordance, so a prompt that cannot be typed into is rendered as plain text on the
/// card instead, which is how the title already behaves.
///
/// Row metrics are deliberately compact: name is `bodyMedium` (14), no prompt
/// preview line, rows padded `space2` (not `space3`).
struct StylesSection: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var expandedID: String?

    /// Edit state lives HERE, not inside the row, and is keyed by style id.
    ///
    /// Per-row `@State` is destroyed whenever the row collapses or the list re-renders,
    /// so drafts held down there could not survive expanding a different row. Holding the
    /// edit target and both drafts above the rows means a row that collapses (because a
    /// sibling was expanded) keeps its in-progress edit, and re-expanding it returns to
    /// exactly the same unsaved state.
    ///
    /// A single `editingID` is enough because at most one row is ever in edit mode, which
    /// is also why two plain draft strings suffice rather than a dictionary.
    @State private var editingID: String?
    @State private var nameDraft = ""
    @State private var bodyDraft = ""

    @Environment(\.colorScheme) private var colorScheme

    private var builtIns: [Style] { settings.styles.filter { $0.isBuiltIn } }
    private var customs: [Style] { settings.styles.filter { !$0.isBuiltIn } }

    var body: some View {
        VStack(alignment: .leading, spacing: NockerlSpace.space4) {
            header
            listContainer
        }
        .padding(NockerlSpace.space6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header (sits on the background, above the container)

    private var header: some View {
        HStack(spacing: NockerlSpace.space2) {
            SectionTitle(.styles)
            NockerlInfoTip(text: "The instruction sent with your audio to set the tone. Your vocabulary is always appended.")
            Spacer(minLength: 0)
            NockerlIconButton(
                systemName: "plus",
                label: "New style",
                style: .accentOutline,
                density: .compact
            ) {
                // A new style opens straight into edit mode with the cursor in the title,
                // so the first thing a fresh "Untitled 1" asks for is its name.
                beginEdit(settings.addStyle())
            }
        }
    }

    // MARK: - Recessed bounded scroll container

    private var listContainer: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: NockerlSpace.space4) {
                    group(title: "Built-in", styles: builtIns, emptyHint: nil, tightTop: true)
                    group(title: "Your styles", styles: customs,
                          emptyHint: "No custom styles yet. Tap + or duplicate a built-in.")
                }
                .padding(NockerlSpace.space3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            // Bring an expanded row into view instead of letting it run off the panel.
            .onChange(of: expandedID) { _, newID in
                guard let id = newID else { return }
                // Defer past the expand re-layout, else scrollTo targets the still-collapsed
                // frame. Anchor the BOTTOM so expanding reveals the newly-opened editor.
                DispatchQueue.main.async {
                    withAnimation(.nockerlStandard(NockerlMotionDuration.base)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .nockerlWell(.container)
    }

    // MARK: - Group

    @ViewBuilder
    private func group(title: String, styles: [Style], emptyHint: String?, tightTop: Bool = false) -> some View {
        let palette = NockerlPalette.resolve(colorScheme)
        VStack(alignment: .leading, spacing: NockerlSpace.space2) {
            // `tightTop` on the FIRST group only (v1.18.0): GroupHeader's 16pt top padding is
            // the right rhythm BETWEEN groups, but for the first one there is no block above
            // it (just the well's edge), so it sat 16pt lower than Settings' first
            // FormSection (28pt vs 12pt from the well). Dropping it lines the two screens up.
            NockerlGroupHeader(title, tightTop: tightTop)

            if styles.isEmpty, let hint = emptyHint {
                Text(hint)
                    .nockerlType(.bodySmall)
                    .foregroundStyle(palette.onCanvasMuted)
                    .padding(.vertical, NockerlSpace.space2)
            } else {
                VStack(spacing: NockerlSpace.space2) {
                    ForEach(styles) { style in
                        StyleRow(
                            style: binding(for: style.id),
                            isActive: style.id == settings.activeStyleID,
                            isExpanded: expandedID == style.id,
                            isEditing: editingID == style.id,
                            nameDraft: $nameDraft,
                            bodyDraft: $bodyDraft,
                            onToggleExpand: { toggleExpand(style.id) },
                            onSetActive: { settings.setActiveStyle(style.id) },
                            onBeginEdit: { beginEdit(style) },
                            onCommitEdit: commitEdit,
                            onCancelEdit: cancelEdit,
                            onDuplicate: {
                                // A copy arrives named "<name> copy" and almost always wants
                                // renaming straight away, so it opens in edit mode with the
                                // caret in the title, the same as the new-style button and the
                                // menu's Edit. `beginEdit` is given the COPY, never the
                                // original, and it expands the row itself with the same
                                // animation this call site used to run inline.
                                beginEdit(settings.duplicateStyle(style.id))
                            },
                            onDelete: {
                                if expandedID == style.id { expandedID = nil }
                                // Drop the edit too, otherwise a deleted row leaves the
                                // pane holding drafts for a style that no longer exists.
                                if editingID == style.id { cancelEdit() }
                                settings.deleteStyle(style.id)
                            }
                        )
                        .id(style.id)
                    }
                }
            }
        }
    }

    // MARK: - Behaviour

    private func toggleExpand(_ id: String) {
        let isCurrentlyExpanded = (expandedID == id)
        // A row in edit mode cannot be collapsed: its collapse affordance has been replaced
        // by the commit/discard pair, so the user has to decide. Only the COLLAPSE direction
        // is blocked. Re-expanding a row that was closed by opening a sibling is how the
        // user gets back to an edit still in progress.
        if isCurrentlyExpanded && editingID == id { return }
        withAnimation(.nockerlStandard(NockerlMotionDuration.base)) {
            expandedID = isCurrentlyExpanded ? nil : id
        }
    }

    /// Enter edit mode for one style, seeding both drafts from the saved values. Also
    /// expands the row, since edit mode covers the prompt as well as the title.
    private func beginEdit(_ style: Style) {
        nameDraft = style.name
        bodyDraft = style.body
        editingID = style.id
        withAnimation(.nockerlStandard(NockerlMotionDuration.base)) { expandedID = style.id }
    }

    /// The ONLY path that writes a draft back to the store, and it writes BOTH fields.
    private func commitEdit() {
        guard let id = editingID,
              let index = settings.styles.firstIndex(where: { $0.id == id }) else {
            editingID = nil
            return
        }
        var updated = settings.styles[index]
        let trimmed = nameDraft.trimmingCharacters(in: .whitespaces)
        // An empty name keeps the old one rather than blanking the style.
        if !trimmed.isEmpty { updated.name = trimmed }
        updated.body = bodyDraft
        settings.styles[index] = updated
        withAnimation(.nockerlStandard(NockerlMotionDuration.fast)) { editingID = nil }
    }

    /// Discard BOTH drafts. Nothing is written; the drafts are re-seeded from the store on
    /// the next `beginEdit`, so there is no stale text to leak into another row.
    private func cancelEdit() {
        withAnimation(.nockerlStandard(NockerlMotionDuration.fast)) { editingID = nil }
    }

    private func binding(for id: String) -> Binding<Style> {
        Binding(
            get: { settings.styles.first { $0.id == id } ?? Style(id: id, name: "", body: "") },
            set: { newValue in
                if let index = settings.styles.firstIndex(where: { $0.id == id }) {
                    settings.styles[index] = newValue
                }
            }
        )
    }
}

// MARK: - One style row

private struct StyleRow: View {
    @Binding var style: Style
    let isActive: Bool
    let isExpanded: Bool
    let isEditing: Bool
    /// Drafts owned by the pane, so they outlive this row collapsing or re-rendering.
    @Binding var nameDraft: String
    @Binding var bodyDraft: String
    let onToggleExpand: () -> Void
    let onSetActive: () -> Void
    let onBeginEdit: () -> Void
    let onCommitEdit: () -> Void
    let onCancelEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// The editable fields are shown only while the row is BOTH the edit target and open.
    /// A row that was closed by expanding a sibling keeps `isEditing`, so it renders as an
    /// ordinary collapsed row and returns to the in-progress edit when reopened.
    private var showsEditUI: Bool { isEditing && isExpanded }

    var body: some View {
        let palette = NockerlPalette.resolve(colorScheme)
        // Deliberately NOT `selected:`. The selectable-card variant draws a cyan border,
        // which fought the card's own neutral hairline in light mode (two competing
        // borders) and is a treatment used nowhere else in the app. The default style is
        // already unmistakable from the filled radio plus the cyan title ink.
        return NockerlCard(elevation: .level2) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow(palette)
                if isExpanded {
                    promptArea(palette).padding(.top, NockerlSpace.space2)
                }
            }
            // space2 (was space3): the row is one line of 14pt text next to a 20pt radio,
            // so tighter padding is what keeps it a LIST rather than a stack of panels.
            .padding(NockerlSpace.space2)
        }
        .animation(.nockerlStandard(NockerlMotionDuration.fast), value: isActive)
        .animation(.nockerlStandard(NockerlMotionDuration.base), value: showsEditUI)
    }

    // MARK: Row header

    @ViewBuilder
    private func headerRow(_ palette: NockerlPalette) -> some View {
        HStack(spacing: NockerlSpace.space2) {
            // The radio is the ONLY thing that sets the default. It does not share a tap
            // target with the name.
            NockerlRadio(selected: isActive, onSelect: onSetActive, label: nil)
                .accessibilityLabel(isActive ? "\(style.name), the default style" : "Make \(style.name) the default style")

            titleArea(palette)

            Spacer(minLength: 0)

            if showsEditUI {
                // Edit mode offers exactly two exits, and no way to collapse past them.
                editControls(palette)
            } else {
                if isExpanded && !style.isBuiltIn {
                    NockerlIconButton(systemName: "pencil", label: "Edit \(style.name)", density: .compact,
                                      tint: .custom(palette.accentPrimary)) {
                        onBeginEdit()
                    }
                    .help("Edit name and prompt")
                }
                actionMenu(palette)
                expandChevron(palette)
            }
        }
        .contentShape(Rectangle())
        // Tapping the row's empty space expands it: a bigger target than the chevron alone.
        // Suppressed in edit mode, where collapsing is not on offer at all.
        .onTapGesture { if !showsEditUI { onToggleExpand() } }
    }

    @ViewBuilder
    private func titleArea(_ palette: NockerlPalette) -> some View {
        if showsEditUI {
            // Same input treatment as the API key row: plain field style in a field well.
            TextField("Style name", text: $nameDraft)
                .textFieldStyle(.plain)
                .nockerlType(.bodyMedium)
                .foregroundStyle(palette.onCard)
                .nockerlFieldWell()
                .focused($nameFocused)
                // Runs when the field appears, which is both on entering edit mode and on
                // returning to a row whose edit was still open, so the caret lands in the
                // title either way.
                //
                // Deferred by one runloop turn on purpose. A `@FocusState` set during
                // `.onAppear` can land before the field has joined the responder chain, and
                // AppKit then drops the assignment silently. That is what left the new-style
                // button opening edit mode with no caret in the title. Every entry point
                // mounts this same field, so deferring here covers all of them at once.
                .onAppear { DispatchQueue.main.async { nameFocused = true } }
                // 24 chars ("Southern California" is 19) so the name still fits the History
                // style tag. Fires on paste too, so it can't be exceeded.
                .onChange(of: nameDraft) { _, newValue in
                    if newValue.count > 24 { nameDraft = String(newValue.prefix(24)) }
                }
                // Enter is a shortcut for the checkmark, never a separate save path: it runs
                // the same commit and writes both fields. Esc is deliberately NOT wired to
                // discard, because an edit now spans two fields and a stray Esc while typing
                // the prompt would throw away work the user cannot see being lost.
                .onSubmit { onCommitEdit() }
                .frame(maxWidth: 240)
        } else {
            HStack(spacing: NockerlSpace.space1) {
                // Active is differentiated by INK, never a heavier weight (thin-forward canon).
                Text(style.name.isEmpty ? "Untitled" : style.name)
                    .nockerlType(.bodyMedium)
                    .foregroundStyle(isActive ? palette.accentPrimary : palette.onCard)
                    .lineLimit(1)
                if style.isBuiltIn {
                    Image(systemName: "lock.fill")
                        .font(.system(size: NockerlFontSize.size10))
                        .foregroundStyle(palette.onCardMuted)
                        .accessibilityLabel("Read-only")
                }
            }
        }
    }

    /// The one commit/discard pair. It governs the title and the prompt together, so the
    /// user can move between the two fields as much as they like before deciding.
    @ViewBuilder
    private func editControls(_ palette: NockerlPalette) -> some View {
        NockerlIconButton(systemName: "checkmark", label: "Save changes to \(style.name)", density: .compact,
                          tint: .custom(palette.accentPrimary)) {
            onCommitEdit()
        }
        .help("Save name and prompt")

        NockerlIconButton(systemName: "xmark", label: "Discard changes to \(style.name)", density: .compact,
                          tint: .neutral) {
            onCancelEdit()
        }
        .help("Discard changes")
    }

    @ViewBuilder
    private func actionMenu(_ palette: NockerlPalette) -> some View {
        Menu {
            // Same action as the pencil, for people who look in the menu first.
            if !style.isBuiltIn {
                Button { onBeginEdit() } label: { Label("Edit", systemImage: "pencil") }
            }
            Button { onDuplicate() } label: { Label("Duplicate", systemImage: "square.on.square") }
            if !style.isBuiltIn {
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: NockerlFontSize.size14, weight: .medium))
                .rotationEffect(.degrees(90))
                .foregroundStyle(palette.onCardMuted)
                .frame(width: NockerlSpace.space6, height: NockerlSpace.space6)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Actions for \(style.name)")
        .confirmationDialog(
            "Delete “\(style.name)”? This can’t be undone.",
            isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func expandChevron(_ palette: NockerlPalette) -> some View {
        Button(action: onToggleExpand) {
            Image(systemName: "chevron.down")
                .font(.system(size: NockerlFontSize.size12, weight: .medium))
                .foregroundStyle(palette.onCardMuted)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .frame(width: NockerlSpace.space6, height: NockerlSpace.space6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse \(style.name)" : "Expand \(style.name) to read its prompt")
    }

    // MARK: Expanded prompt

    @ViewBuilder
    private func promptArea(_ palette: NockerlPalette) -> some View {
        VStack(alignment: .leading, spacing: NockerlSpace.space1) {
            // An EYEBROW, so uppercase and on the dedicated `.eyebrow` role. Eyebrows are
            // the sanctioned second uppercase in this type system (the framework's own
            // NockerlGroupHeader renders "BUILT-IN" and "YOUR STYLES" through the same
            // role, via the design laws' eyebrow exception). The eyebrow role also carries
            // neutral 0em tracking rather than the button's tightening, which would
            // over-condense an overline this small.
            //
            // `onCardMuted` rather than GroupHeader's `onCanvasMuted`, because this one
            // sits on a card.
            Text("Prompt".uppercased())
                .nockerlType(.eyebrow)
                .foregroundStyle(palette.onCardMuted)

            // Built-ins can never be the edit target, so the guard is belt and braces: it
            // keeps a built-in out of the editor even if the edit state were ever wrong.
            if !style.isBuiltIn && showsEditUI {
                TextEditor(text: $bodyDraft)
                    .nockerlType(.bodyMedium)
                    .foregroundStyle(palette.onCard)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("Style prompt")
                    // FIXED height in both states so switching to edit can't resize the row
                    // (and, further up, can't grow the window).
                    .frame(height: 130)
                    .nockerlWell(.field)
            } else {
                readOnlyPrompt(palette)
            }
        }
    }

    /// The prompt as plain readable text on the card, used by built-ins and by custom
    /// styles that are not currently being edited.
    ///
    /// Deliberately NO well. The field well is a recessed INPUT affordance, so leaving it
    /// on text that cannot be typed into reads as "still editable" and sits oddly against
    /// the card. The title already behaves this way, reverting to plain text on commit,
    /// and this brings the prompt in line with it.
    ///
    /// The padding is the fiddly part. `.nockerlWell(.field)` applies its own internal
    /// inset before drawing its background, so dropping the well would otherwise pull the
    /// text left and shrink the block. These two values are that inset reproduced exactly,
    /// which keeps the text in the same place and the outer height identical in both
    /// states. If the well's padding ever changes in the framework, change these with it.
    @ViewBuilder
    private func readOnlyPrompt(_ palette: NockerlPalette) -> some View {
        ScrollView {
            Text(style.body)
                .nockerlType(.bodyMedium)
                .foregroundStyle(palette.onCard)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .scrollIndicators(.never)
        // Same fixed height as the editor: a long prompt still scrolls inside it.
        .frame(height: 130)
        .padding(.horizontal, NockerlSpace.space3)
        .padding(.vertical, NockerlSpace.space2)
    }
}
