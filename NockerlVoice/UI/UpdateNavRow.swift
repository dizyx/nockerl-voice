import NockerlDesign
import SwiftUI

/// The entire update interface, as one thin row under the sidebar nav.
///
/// This exists because there was no update interface at all. `UpdateModel` published a
/// phase and an `isPanelPresented` flag, `UpdateDriver` drove them faithfully, and NOTHING
/// observed either one: the only other file that touched the model read a single boolean to
/// decide whether to show a menu item. So Sparkle would find an update, hand the driver a
/// reply block to call once the user answered, the driver would set a flag, and no view
/// existed to ask the question or send the reply. Sparkle waited forever, and the menu item
/// appeared to do nothing when clicked. The engine was complete; the dashboard was missing.
///
/// A ROW RATHER THAN A WINDOW, and that is the point. This app is menu-bar-first and driven
/// by a global hotkey, so an update must never take focus or cover what someone is dictating
/// into. A row in a sidebar the user is already looking at can carry the whole flow, from
/// discovery through to relaunch, without a single modal.
///
/// It renders NOTHING while idle, so the sidebar is unchanged on the overwhelming majority
/// of launches. Every other state DOES render, including "up to date", because that state
/// only follows a question the user asked and someone who asks is owed an answer. Silence
/// there was the first version of this file, and it recreated the very bug the file exists
/// to fix.
struct UpdateNavRow: View {
    @ObservedObject private var model = UpdateModel.shared
    /// Set when the user taps an available update, which turns the row into a confirmation.
    /// Consent is explicit and per update: finding one never begins a download.
    @State private var confirming = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = NockerlPalette.resolve(colorScheme)
        Group {
            switch model.phase {
            case .idle:
                // Deliberately empty. A row that said "no updates" on every launch forever
                // would be noise reporting the state the user already expects.
                EmptyView()

            case .checking:
                progress("Checking for updates", fraction: nil, palette: palette)

            case .upToDate:
                // MUST render, and must acknowledge. This was EmptyView, which recreated
                // the exact bug this file exists to fix. `showUpdateNotFoundWithError`
                // hands the driver an acknowledgement block and presents, so the guard that
                // would otherwise release Sparkle immediately does not fire. With nothing
                // on screen, nothing ever called `acknowledge()`: pressing Check for
                // Updates while already current showed no feedback AND stranded the
                // session, so the NEXT check silently did nothing too, because Sparkle
                // ignores a check while one is in progress.
                //
                // Silence is right for automatic discovery and wrong for an explicit
                // question. Someone who asks is owed an answer.
                tappable("You are up to date", icon: "checkmark.circle",
                         tone: palette.onCanvasMuted) { model.acknowledge() }
                    .task(id: "uptodate") {
                        // Clears itself, because this is an answer rather than a
                        // notification. Acknowledging is what releases Sparkle, so the
                        // timer is doing real work, not just tidying the view.
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        model.acknowledge()
                    }

            case .available(let version):
                if confirming {
                    prompt(version: version, palette: palette)
                } else {
                    tappable("Update to \(version)", icon: "arrow.down.circle.fill",
                             tone: palette.accentPrimary) { confirming = true }
                }

            case .downloading(let fraction):
                // Sparkle does not always know the content length, so the fraction is
                // optional and the copy has to work without it.
                progress(fraction.map { "Downloading \(Int($0 * 100))%" } ?? "Downloading",
                         fraction: fraction, palette: palette)

            case .extracting(let fraction):
                progress("Preparing", fraction: fraction, palette: palette)

            case .readyToInstall:
                // A SECOND explicit consent, because this one quits the app. The first
                // agreed to fetch it, not to be interrupted at an arbitrary moment.
                tappable("Restart to update", icon: "checkmark.circle.fill",
                         tone: palette.accentPrimary) { model.respond(.install) }

            case .installing:
                progress("Installing", fraction: nil, palette: palette)

            case .failed(let message):
                // Tapping acknowledges, which is what releases Sparkle's held callback and
                // returns the row to idle. Without it a failed check would wedge the flow.
                tappable("Update failed", icon: "exclamationmark.circle.fill",
                         tone: palette.statusWarning) { model.acknowledge() }
                    .help(message)
            }
        }
        .padding(.horizontal, NockerlSpace.space2)
    }

    /// The discovery and ready states: one line, tappable, no chrome.
    private func tappable(_ label: String, icon: String, tone: Color,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: NockerlSpace.space2) {
                Image(systemName: icon)
                    .font(.system(size: NockerlFontSize.size12))
                Text(label)
                    .nockerlType(.labelSmall)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(tone)
            .padding(.horizontal, NockerlSpace.space3)
            .padding(.vertical, NockerlSpace.space2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The confirmation. Install is the primary; Later dismisses this session only.
    private func prompt(version: String, palette: NockerlPalette) -> some View {
        VStack(alignment: .leading, spacing: NockerlSpace.space2) {
            Text("Install \(version)?")
                .nockerlType(.labelSmall)
                .foregroundStyle(palette.onCanvas)
            Text("The app restarts to finish.")
                .nockerlType(.labelSmall)
                .foregroundStyle(palette.onCanvasMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: NockerlSpace.space2) {
                NockerlButton("Install", variant: .primary, size: .sm) {
                    confirming = false
                    // `install()`, not `respond(.install)`. After a background discovery
                    // Sparkle holds no reply, so responding would answer a question nobody
                    // is asking and silently do nothing.
                    model.install()
                }
                // `.dismiss`, NOT `.skip`. Skip tells Sparkle to never offer this version
                // again, which is a far bigger decision than "not now" and not what a
                // Later button means to anyone.
                NockerlButton("Later", variant: .ghost, size: .sm) {
                    confirming = false
                    model.postpone()
                }
            }
        }
        .padding(.horizontal, NockerlSpace.space3)
        .padding(.vertical, NockerlSpace.space2)
    }

    /// In-flight states. The bar is omitted rather than faked when the fraction is unknown.
    private func progress(_ label: String, fraction: Double?,
                          palette: NockerlPalette) -> some View {
        VStack(alignment: .leading, spacing: NockerlSpace.space1) {
            Text(label)
                .nockerlType(.labelSmall)
                .foregroundStyle(palette.onCanvasMuted)
            if let fraction {
                ProgressView(value: max(0, min(1, fraction)))
                    .progressViewStyle(.linear)
                    .tint(palette.accentPrimary)
            }
        }
        .padding(.horizontal, NockerlSpace.space3)
        .padding(.vertical, NockerlSpace.space2)
    }
}
