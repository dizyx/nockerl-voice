import NockerlDesign
import SwiftUI

/// A large section title used at the top of each detail pane.
/// A page title, with the same glyph the sidebar uses for that destination, so the
/// header reads as the continuation of the nav row you just clicked.
struct SectionTitle: View {
    let title: String
    /// SF Symbol name. Nil renders the bare title (no reserved space).
    var icon: String?
    @Environment(\.colorScheme) private var colorScheme

    init(title: String, icon: String? = nil) {
        self.title = title
        self.icon = icon
    }

    /// PREFERRED. Takes both the title and the glyph from the router enum, so a page
    /// header can never drift from its sidebar entry: rename or re-icon a section in
    /// one place and both follow.
    init(_ section: AppSection) {
        self.title = section.title
        self.icon = section.icon
    }

    var body: some View {
        let palette = NockerlPalette.resolve(colorScheme)
        return HStack(spacing: NockerlSpace.space2) {
            if let icon {
                // Same 20pt glyph the sidebar uses, in the TITLE's ink (not accent) so the
                // header reads as one unit: the icon is part of the title, not a status
                // marker. SF Symbol glyphs stay on `.font(.system)`; `.nockerlType` is for
                // text. Weight `.light` sits with the extralight 24pt title.
                Image(systemName: icon)
                    .font(.system(size: NockerlFontSize.size20, weight: .light))
                    .foregroundStyle(palette.onCanvas)
                    .accessibilityHidden(true)   // the title already names the page
            }
            Text(title)
                // Canon page-title role, headlineMedium (Outfit, 24/extralight):
                // thin-forward. One place, every page title.
                .nockerlType(.headlineMedium)
                .foregroundStyle(palette.onCanvas)
        }
    }
}
