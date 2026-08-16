import NockerlDesign
import SwiftUI

/// Which control on a first-run surface should hold keyboard focus.
///
/// It lives here rather than in the welcome window because half the vocabulary belongs to
/// `PermissionRow`: the row owns its own action button, so it is the only thing that can
/// tag it as a focus target. A surface that opts in supplies the binding; one that does
/// not, like the permission window, simply passes nothing and behaves as before.
enum FirstRunFocus: Hashable {
    /// A permission row's action button, keyed by the row title. A title rather than an
    /// index so the value survives rows appearing and disappearing as grants land.
    case permission(String)
    /// The surface's primary action, for example Get Started.
    case primaryAction
}

/// One permission's status and its way in: a status mark, a name, a description, an
/// optional caveat line, and a Grant button while it is still missing.
///
/// This lives on its own because BOTH first-run surfaces need it. It began inside
/// `OnboardingView` and the welcome window needed the same thing, at which point the choice
/// was to copy it or to lift it. Copied, the two would have drifted the first time a status
/// colour or a caveat changed, and the first-run surfaces are exactly where a drifted
/// second copy would go unnoticed longest.
///
/// A GRANTED check is the brand cyan, not the success green. This is a deliberate departure
/// from the usual rule that a permission's state is status and takes a status token. On a
/// first-run screen these ticks are most of what the reader sees, and a wall of system green
/// reads as generic macOS chrome rather than as this app. The failure states stay on their
/// status tokens, where the colour is carrying meaning that cyan could not: red for missing
/// or denied, amber for a caveat.
///
/// The status glyph stays on `.font(.system)` because an SF Symbol is a symbol, never Outfit.
struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    var denied: Bool = false
    /// A caveat shown only while the grant is still missing, for example that a grant needs
    /// a relaunch before it takes effect.
    var note: String?
    let action: () -> Void
    /// Optional focus plumbing. Supplied, this row's action button becomes a focus target
    /// keyed by `title`; omitted, the row is exactly what it was. Optional because only the
    /// welcome window directs initial focus, and the permission window should not have to
    /// care that the feature exists.
    var focus: FocusState<FirstRunFocus?>.Binding?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = NockerlPalette.resolve(colorScheme)
        HStack(alignment: .top, spacing: 12) {
            // NOT GRANTED IS NOT GRANTED. This used to show a neutral grey circle unless
            // macOS had recorded an explicit denial, which meant a first run, where nothing
            // has been decided yet, showed an ambiguous grey dot beside everything. That
            // distinction is real to TCC and meaningless to the reader: both states are
            // "not set up", and only one of them needs acting on, so both now read as the
            // same red X. `denied` still earns its place below, where the difference does
            // matter: it changes the advice and the button, because a denied prompt cannot
            // be shown again and only System Settings will do.
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? palette.accentPrimary : palette.statusError)
                .font(.system(size: NockerlFontSize.size16))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .nockerlType(.titleSmall)
                    .foregroundStyle(palette.onCanvas)
                Text(detail)
                    .nockerlType(.labelSmall)
                    .foregroundStyle(palette.onCanvasMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if denied {
                    // The dead end this exists to close: a denied prompt cannot be
                    // re-presented by the app, so the only way back is System Settings.
                    // Saying so, and giving the button that opens it, is the whole fix.
                    Text("Denied. Open System Settings to turn it on, then Re-check.")
                        .nockerlType(.labelSmall)
                        .foregroundStyle(palette.statusError)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let note, !granted {
                    Text(note)
                        .nockerlType(.labelSmall)
                        .foregroundStyle(palette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if !granted {
                actionButton
            }
        }
    }

    /// Once a prompt has been denied macOS will not show it again, so the button stops
    /// claiming it can grant anything and says where it actually goes.
    private var actionLabel: String { denied ? "Open Settings" : "Grant" }

    /// .tertiary (outlined cyan): a per-row action. Several can be on screen at once, and
    /// .primary is one per surface, so it is not legal here.
    ///
    /// The button is spelled out twice rather than built once and conditionally modified,
    /// because `.focused` changes the view's type and a `let` bound before a branch inside
    /// a ViewBuilder is the kind of thing that compiles in one Swift version and not the
    /// next. Two plain branches cost a line and cannot surprise anyone.
    @ViewBuilder
    private var actionButton: some View {
        if let focus {
            NockerlButton(actionLabel, variant: .tertiary, size: .sm, action: action)
                .focused(focus, equals: .permission(title))
        } else {
            NockerlButton(actionLabel, variant: .tertiary, size: .sm, action: action)
        }
    }
}
